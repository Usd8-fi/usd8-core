// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {USD8} from "../../src/USD8.sol";

contract USD8SweepStandardToken is ERC20 {
    constructor() ERC20("Sweep Standard Token", "SST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract USD8SweepAdversarialTokenBase is IERC20 {
    mapping(address account => uint256) internal _balances;
    mapping(address owner => mapping(address spender => uint256)) internal _allowances;
    uint256 internal _supply;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _supply += amount;
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return _supply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("unused");
    }
}

contract USD8SweepRevertingToken is USD8SweepAdversarialTokenBase {
    error TransferRejected();

    function transfer(address, uint256) external pure returns (bool) {
        revert TransferRejected();
    }
}

contract USD8SweepFalseReturnToken is USD8SweepAdversarialTokenBase {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Legacy ERC20 shape: successful transfer returns no data.
contract USD8SweepNoReturnToken {
    mapping(address account => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external {
        uint256 fromBalance = balanceOf[msg.sender];
        require(fromBalance >= amount, "insufficient");
        unchecked {
            balanceOf[msg.sender] = fromBalance - amount;
            balanceOf[to] += amount;
        }
    }
}

/// @dev Transfer mutates and returns one byte; SafeERC20 must reject the malformed
///      ABI return and the outer revert must roll the mutation back.
contract USD8SweepMalformedReturnToken {
    mapping(address account => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fromBalance = balanceOf[msg.sender];
        require(fromBalance >= amount, "insufficient");
        unchecked {
            balanceOf[msg.sender] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

contract USD8SweepRejectingReceiver {
    receive() external payable {
        revert("reject ETH");
    }
}

/// @notice Foundry/Kontrol properties for the SharedBase sweep surface inherited by USD8.
/// @dev The production Registry and USD8 implementations run behind real ERC1967
///      proxies. Token amounts and ETH balances are uint128 and nonzero where a
///      successful external transfer is required. Foreign standard-token behavior
///      is represented by a named vanilla OpenZeppelin ERC20; adversarial behavior
///      is covered separately by named reverting and false-return candidates.
contract USD8SweepKontrolTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant RECIPIENT = address(0xBEEF);

    Registry internal registry;
    USD8 internal usd8;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(this));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function test_unauthorizedCallerCannotSweepTokenAtomically(address caller, address recipient, uint128 amount)
        public
    {
        vm.assume(caller != address(this));
        vm.assume(caller != ADMIN);
        vm.assume(amount > 0);

        USD8SweepStandardToken token = new USD8SweepStandardToken();
        token.mint(address(usd8), amount);
        uint256 sourceBefore = token.balanceOf(address(usd8));
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(caller);
        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), recipient)));

        assert(!success);
        assert(_selector(returndata) == Registry.UnauthorizedAdmin.selector);
        assert(token.balanceOf(address(usd8)) == sourceBefore);
        assert(token.balanceOf(recipient) == recipientBefore);
    }

    function test_unauthorizedCallerCannotSweepETHAtomically(address caller, address payable recipient, uint128 amount)
        public
    {
        vm.assume(caller != address(this));
        vm.assume(caller != ADMIN);
        vm.assume(amount > 0);
        vm.deal(address(usd8), amount);
        uint256 recipientBefore = recipient.balance;

        vm.prank(caller);
        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(SharedBase.sweepETH, (recipient)));

        assert(!success);
        assert(_selector(returndata) == Registry.UnauthorizedAdmin.selector);
        assert(address(usd8).balance == amount);
        assert(recipient.balance == recipientBefore);
    }

    function test_adminSweepsFullForeignStandardTokenBalance(uint128 amount) public {
        vm.assume(amount > 0);
        USD8SweepStandardToken token = new USD8SweepStandardToken();
        token.mint(address(usd8), amount);

        vm.prank(ADMIN);
        usd8.sweepToken(IERC20(address(token)), RECIPIENT);

        assert(token.balanceOf(address(usd8)) == 0);
        assert(token.balanceOf(RECIPIENT) == amount);
    }

    function test_timelockSweepsFullETHBalance(uint128 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(usd8), amount);
        uint256 recipientBefore = RECIPIENT.balance;

        usd8.sweepETH(payable(RECIPIENT));

        assert(address(usd8).balance == 0);
        assert(RECIPIENT.balance == recipientBefore + amount);
    }

    function test_tokenSweepRejectsZeroRecipientAtomically(uint128 amount) public {
        vm.assume(amount > 0);
        USD8SweepStandardToken token = new USD8SweepStandardToken();
        token.mint(address(usd8), amount);

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), address(0))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.ZeroAddress.selector);
        assert(token.balanceOf(address(usd8)) == amount);
        assert(token.balanceOf(address(0)) == 0);
    }

    function test_ethSweepRejectsZeroRecipientAtomically(uint128 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(usd8), amount);

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(0)))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.ZeroAddress.selector);
        assert(address(usd8).balance == amount);
    }

    function test_tokenSweepRejectsEmptyBalance() public {
        USD8SweepStandardToken token = new USD8SweepStandardToken();

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), RECIPIENT)));

        assert(!success);
        assert(_selector(returndata) == SharedBase.NothingToSweep.selector);
        assert(token.balanceOf(address(usd8)) == 0);
        assert(token.balanceOf(RECIPIENT) == 0);
    }

    function test_selfRecipientsRejectTokenAndEthAtomically(uint128 tokenAmount, uint128 ethAmount) public {
        vm.assume(tokenAmount > 0 && ethAmount > 0);
        USD8SweepStandardToken token = new USD8SweepStandardToken();
        token.mint(address(usd8), tokenAmount);
        vm.deal(address(usd8), ethAmount);

        (bool tokenSuccess, bytes memory tokenData) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), address(usd8))));
        (bool ethSuccess, bytes memory ethData) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(usd8)))));

        assert(!tokenSuccess && !ethSuccess);
        assert(_selector(tokenData) == SharedBase.InvalidSweepRecipient.selector);
        assert(_selector(ethData) == SharedBase.InvalidSweepRecipient.selector);
        assert(token.balanceOf(address(usd8)) == tokenAmount);
        assert(address(usd8).balance == ethAmount);
    }

    function test_ethSweepRejectsEmptyBalance() public {
        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepETH, (payable(RECIPIENT))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.NothingToSweep.selector);
        assert(address(usd8).balance == 0);
    }

    function test_selfTokenSweepMovesFullBalanceWithoutChangingTotalSupply(uint128 amount) public {
        vm.assume(amount > 0);
        usd8.mint(address(usd8), amount);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 recipientBefore = usd8.balanceOf(RECIPIENT);

        usd8.sweepToken(IERC20(address(usd8)), RECIPIENT);

        assert(usd8.balanceOf(address(usd8)) == 0);
        assert(usd8.balanceOf(RECIPIENT) == recipientBefore + amount);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_revertingTokenRollsBackSweepAtomically(uint128 amount) public {
        vm.assume(amount > 0);
        USD8SweepRevertingToken token = new USD8SweepRevertingToken();
        token.mint(address(usd8), amount);

        (bool success,) = address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), RECIPIENT)));

        assert(!success);
        assert(token.balanceOf(address(usd8)) == amount);
        assert(token.balanceOf(RECIPIENT) == 0);
        assert(token.totalSupply() == amount);
    }

    function test_falseReturnTokenRollsBackSweepAtomically(uint128 amount) public {
        vm.assume(amount > 0);
        USD8SweepFalseReturnToken token = new USD8SweepFalseReturnToken();
        token.mint(address(usd8), amount);

        (bool success,) = address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), RECIPIENT)));

        assert(!success);
        assert(token.balanceOf(address(usd8)) == amount);
        assert(token.balanceOf(RECIPIENT) == 0);
        assert(token.totalSupply() == amount);
    }

    function test_rejectingReceiverRollsBackFullETHSweep(uint128 amount) public {
        vm.assume(amount > 0);
        USD8SweepRejectingReceiver receiver = new USD8SweepRejectingReceiver();
        vm.deal(address(usd8), amount);

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(receiver)))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.EthTransferFailed.selector);
        assert(address(usd8).balance == amount);
        assert(address(receiver).balance == 0);
    }

    function test_noReturnTokenSweepMovesFullBalance(uint128 amount) public {
        vm.assume(amount > 0);
        USD8SweepNoReturnToken token = new USD8SweepNoReturnToken();
        token.mint(address(usd8), amount);

        usd8.sweepToken(IERC20(address(token)), RECIPIENT);

        assert(token.balanceOf(address(usd8)) == 0);
        assert(token.balanceOf(RECIPIENT) == amount);
        assert(token.totalSupply() == amount);
    }

    function test_malformedReturnTokenRollsBackSweepAtomically(uint128 amount) public {
        vm.assume(amount > 0);
        USD8SweepMalformedReturnToken token = new USD8SweepMalformedReturnToken();
        token.mint(address(usd8), amount);

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), RECIPIENT)));

        assert(!success);
        assert(_selector(returndata) == SafeERC20.SafeERC20FailedOperation.selector);
        assert(token.balanceOf(address(usd8)) == amount);
        assert(token.balanceOf(RECIPIENT) == 0);
        assert(token.totalSupply() == amount);
    }

    function test_zeroTokenAddressSweepIsRejected() public {
        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(0)), RECIPIENT)));

        assert(!success);
        // Solidity's typed balanceOf call rejects the no-code target before
        // producing returndata under the pinned compiler.
        assert(returndata.length == 0);
        assert(address(usd8).balance == 0);
    }
}
