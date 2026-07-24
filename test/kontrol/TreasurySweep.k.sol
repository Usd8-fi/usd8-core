// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";

contract TreasurySweepUSDC is ERC20 {
    constructor() ERC20("Kontrol USDC", "kUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TreasurySweepStandardToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract TreasurySweepAdversarialTokenBase is IERC20 {
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

contract TreasurySweepRevertingToken is TreasurySweepAdversarialTokenBase {
    error TransferRejected();

    function transfer(address, uint256) external pure returns (bool) {
        revert TransferRejected();
    }
}

contract TreasurySweepFalseReturnToken is TreasurySweepAdversarialTokenBase {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract TreasurySweepForceETH {
    constructor() payable {}

    function force(address payable target) external {
        selfdestruct(target);
    }
}

contract TreasurySweepRejectingReceiver {
    receive() external payable {
        revert("reject ETH");
    }
}

/// @dev The callback is deliberately granted the admin role by the test. Its
///      nested sweep reaches the empty-balance check because CALL value is
///      debited from Treasury before receive() executes. It catches that failure
///      so the outer all-balance sweep can finish.
contract TreasurySweepCallbackReceiver {
    Treasury internal immutable _treasury;
    bool public attempted;
    bool public nestedSuccess;
    bytes4 public nestedSelector;

    constructor(Treasury treasury_) {
        _treasury = treasury_;
    }

    receive() external payable {
        attempted = true;
        bytes memory returndata;
        (nestedSuccess, returndata) =
            address(_treasury).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(this)))));
        if (returndata.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(returndata, 0x20))
            }
            nestedSelector = selector;
        }
    }
}

/// @notice Focused sweep properties over production Registry, USD8, and Treasury
///         implementations behind real ERC1967 proxies.
/// @dev Successful transfer amounts are nonzero uint128 values. Vanilla OZ ERC20,
///      reverting ERC20, and false-return ERC20 behavior are modeled separately.
///      The callback property covers the tractable ETH reentry shape; arbitrary
///      foreign-token callbacks remain inside the admin/timelock trusted-token
///      boundary because sweepToken intentionally has no reentrancy guard.
contract TreasurySweepKontrolTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant RECIPIENT = address(0xBEEF);

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasurySweepUSDC internal usdc;

    function setUp() public {
        usdc = new TreasurySweepUSDC();
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasury = Treasury(
            payable(address(
                    new ERC1967Proxy(
                        address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(usdc))))
                    )
                ))
        );
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _seedTreasuryUsd8(uint64 usdcAmount) internal returns (uint256 usd8Amount) {
        vm.assume(usdcAmount > 0);
        usdc.mint(address(this), usdcAmount);
        usdc.approve(address(treasury), usdcAmount);
        treasury.mintUSD8(usdcAmount);
        usd8Amount = uint256(usdcAmount) * treasury.USDC_TO_USD8_SCALE();
        usd8.transfer(address(treasury), usd8Amount);
    }

    function _forceETH(uint128 amount) internal {
        vm.assume(amount > 0);
        vm.deal(address(this), amount);
        TreasurySweepForceETH sender = new TreasurySweepForceETH{value: amount}();
        sender.force(payable(address(treasury)));
    }

    function test_usdcIsNeverSweepable(uint128 amount) public {
        vm.assume(amount > 0);
        usdc.mint(address(treasury), amount);

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(usdc)), RECIPIENT)));

        assert(!success);
        assert(_selector(returndata) == SharedBase.NothingToSweep.selector);
        assert(usdc.balanceOf(address(treasury)) == amount);
        assert(usdc.balanceOf(RECIPIENT) == 0);
    }

    function test_liveRegistryUsd8IncludingTreasuryRevenueIsNeverSweepable(uint64 revenueUsdc) public {
        uint256 revenue = _seedTreasuryUsd8(revenueUsdc);

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(usd8)), RECIPIENT)));

        assert(!success);
        assert(_selector(returndata) == SharedBase.NothingToSweep.selector);
        assert(usd8.balanceOf(address(treasury)) == revenue);
        assert(usd8.balanceOf(RECIPIENT) == 0);
    }

    function test_registryUsd8RotationImmediatelyChangesProtectedToken(uint64 oldUsdc, uint64 newUsdc) public {
        uint256 oldAmount = _seedTreasuryUsd8(oldUsdc);
        USD8 replacement =
            USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(replacement));

        vm.assume(newUsdc > 0);
        usdc.mint(address(this), newUsdc);
        usdc.approve(address(treasury), newUsdc);
        treasury.mintUSD8(newUsdc);
        uint256 newAmount = uint256(newUsdc) * treasury.USDC_TO_USD8_SCALE();
        replacement.transfer(address(treasury), newAmount);

        (bool protectedSuccess, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(replacement)), RECIPIENT)));
        assert(!protectedSuccess);
        assert(_selector(returndata) == SharedBase.NothingToSweep.selector);
        assert(replacement.balanceOf(address(treasury)) == newAmount);

        treasury.sweepToken(IERC20(address(usd8)), RECIPIENT);
        assert(usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.balanceOf(RECIPIENT) == oldAmount);
    }

    function test_adminSweepsFullForeignStandardTokenBalance(uint128 amount) public {
        vm.assume(amount > 0);
        TreasurySweepStandardToken token = new TreasurySweepStandardToken("Foreign", "FRN");
        token.mint(address(treasury), amount);

        vm.prank(ADMIN);
        treasury.sweepToken(IERC20(address(token)), RECIPIENT);

        assert(token.balanceOf(address(treasury)) == 0);
        assert(token.balanceOf(RECIPIENT) == amount);
    }

    function test_symbolicUnauthorizedTokenSweepIsAtomic(address caller, address recipient, uint128 amount) public {
        vm.assume(caller != address(this) && caller != ADMIN);
        vm.assume(recipient != address(treasury));
        vm.assume(amount > 0);
        TreasurySweepStandardToken token = new TreasurySweepStandardToken("Foreign", "FRN");
        token.mint(address(treasury), amount);
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(caller);
        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), recipient)));

        assert(!success);
        assert(_selector(returndata) == Registry.UnauthorizedAdmin.selector);
        assert(token.balanceOf(address(treasury)) == amount);
        assert(token.balanceOf(recipient) == recipientBefore);
    }

    function test_symbolicUnauthorizedEthSweepIsAtomic(address caller, address payable recipient, uint128 amount)
        public
    {
        vm.assume(caller != address(this) && caller != ADMIN);
        vm.assume(recipient != address(treasury));
        vm.assume(amount > 0);
        vm.deal(address(treasury), amount);
        uint256 recipientBefore = recipient.balance;

        vm.prank(caller);
        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepETH, (recipient)));

        assert(!success);
        assert(_selector(returndata) == Registry.UnauthorizedAdmin.selector);
        assert(address(treasury).balance == amount);
        assert(recipient.balance == recipientBefore);
    }

    function test_timelockSweepsFullForcedEthBalance(uint128 amount) public {
        _forceETH(amount);
        uint256 recipientBefore = RECIPIENT.balance;

        treasury.sweepETH(payable(RECIPIENT));

        assert(address(treasury).balance == 0);
        assert(RECIPIENT.balance == recipientBefore + amount);
    }

    function test_zeroRecipientsRejectTokenAndEthAtomically(uint128 tokenAmount, uint128 ethAmount) public {
        vm.assume(tokenAmount > 0 && ethAmount > 0);
        TreasurySweepStandardToken token = new TreasurySweepStandardToken("Foreign", "FRN");
        token.mint(address(treasury), tokenAmount);
        vm.deal(address(treasury), ethAmount);

        (bool tokenSuccess, bytes memory tokenData) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), address(0))));
        (bool ethSuccess, bytes memory ethData) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(0)))));

        assert(!tokenSuccess && !ethSuccess);
        assert(_selector(tokenData) == SharedBase.ZeroAddress.selector);
        assert(_selector(ethData) == SharedBase.ZeroAddress.selector);
        assert(token.balanceOf(address(treasury)) == tokenAmount);
        assert(address(treasury).balance == ethAmount);
    }

    function test_selfRecipientsRejectTokenAndEthAtomically(uint128 tokenAmount, uint128 ethAmount) public {
        vm.assume(tokenAmount > 0 && ethAmount > 0);
        TreasurySweepStandardToken token = new TreasurySweepStandardToken("Foreign", "FRN");
        token.mint(address(treasury), tokenAmount);
        vm.deal(address(treasury), ethAmount);

        (bool tokenSuccess, bytes memory tokenData) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), address(treasury))));
        (bool ethSuccess, bytes memory ethData) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(treasury)))));

        assert(!tokenSuccess && !ethSuccess);
        assert(_selector(tokenData) == SharedBase.InvalidSweepRecipient.selector);
        assert(_selector(ethData) == SharedBase.InvalidSweepRecipient.selector);
        assert(token.balanceOf(address(treasury)) == tokenAmount);
        assert(address(treasury).balance == ethAmount);
    }

    function test_emptyTokenAndEthSweepsFail() public {
        TreasurySweepStandardToken token = new TreasurySweepStandardToken("Foreign", "FRN");

        (bool tokenSuccess, bytes memory tokenData) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), RECIPIENT)));
        (bool ethSuccess, bytes memory ethData) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepETH, (payable(RECIPIENT))));

        assert(!tokenSuccess && !ethSuccess);
        assert(_selector(tokenData) == SharedBase.NothingToSweep.selector);
        assert(_selector(ethData) == SharedBase.NothingToSweep.selector);
        assert(token.balanceOf(address(treasury)) == 0);
        assert(address(treasury).balance == 0);
    }

    function test_revertingAndFalseReturnForeignTokensRollBackAtomically(uint128 amount) public {
        vm.assume(amount > 0);
        TreasurySweepRevertingToken revertingToken = new TreasurySweepRevertingToken();
        TreasurySweepFalseReturnToken falseToken = new TreasurySweepFalseReturnToken();
        revertingToken.mint(address(treasury), amount);
        falseToken.mint(address(treasury), amount);

        (bool revertingSuccess,) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(revertingToken)), RECIPIENT)));
        (bool falseSuccess,) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(falseToken)), RECIPIENT)));

        assert(!revertingSuccess && !falseSuccess);
        assert(revertingToken.balanceOf(address(treasury)) == amount);
        assert(falseToken.balanceOf(address(treasury)) == amount);
        assert(revertingToken.balanceOf(RECIPIENT) == 0);
        assert(falseToken.balanceOf(RECIPIENT) == 0);
        assert(revertingToken.totalSupply() == amount);
        assert(falseToken.totalSupply() == amount);
    }

    function test_rejectingEthReceiverRollsBackFullSweep(uint128 amount) public {
        vm.assume(amount > 0);
        TreasurySweepRejectingReceiver receiver = new TreasurySweepRejectingReceiver();
        vm.deal(address(treasury), amount);

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(receiver)))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.EthTransferFailed.selector);
        assert(address(treasury).balance == amount);
        assert(address(receiver).balance == 0);
    }

    function test_authorizedEthCallbackCannotDoubleSweep(uint128 amount) public {
        vm.assume(amount > 0);
        TreasurySweepCallbackReceiver receiver = new TreasurySweepCallbackReceiver(treasury);
        registry.setAdmin(address(receiver), true);
        vm.deal(address(treasury), amount);

        treasury.sweepETH(payable(address(receiver)));

        assert(receiver.attempted());
        assert(!receiver.nestedSuccess());
        assert(receiver.nestedSelector() == SharedBase.NothingToSweep.selector);
        assert(address(treasury).balance == 0);
        assert(address(receiver).balance == amount);
    }
}
