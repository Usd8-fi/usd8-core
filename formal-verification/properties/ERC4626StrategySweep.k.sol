// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {
    ERC4626StrategyHarnessToken,
    ERC4626StrategyKontrolBase,
    ERC4626StrategyLogReceiver,
    ERC4626StrategyRejectETH
} from "./ERC4626StrategyHarness.k.sol";

/// @notice Inherited sweep closure for the final ERC4626Strategy bytecode.
/// @dev `_sweepable` is not overridden, so TokenSwept is structurally unreachable.
contract ERC4626StrategySweepKontrolTest is ERC4626StrategyKontrolBase {
    address internal constant RECIPIENT = address(0xB0B);

    event ETHSwept(address indexed to, uint256 amount);

    function _callAs(address caller, bytes memory payload) internal returns (bool success, bytes memory data) {
        vm.prank(caller);
        return address(strategy).call(payload);
    }

    function test_ethSweepOutsiderAclPrecedesRecipientAndBalanceChecks() public {
        (bool success, bytes memory data) =
            _callAs(OUTSIDER, abi.encodeCall(SharedBase.sweepETH, (payable(address(0)))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, OUTSIDER));
    }

    function test_adminAndTimelockSweepExactFullEthBalance() public {
        vm.deal(address(strategy), 3);
        uint256 beforeRecipient = RECIPIENT.balance;
        vm.prank(ADMIN);
        strategy.sweepETH(payable(RECIPIENT));
        assert(address(strategy).balance == 0);
        assert(RECIPIENT.balance == beforeRecipient + 3);

        vm.deal(address(strategy), 5);
        strategy.sweepETH(payable(RECIPIENT));
        assert(address(strategy).balance == 0);
        assert(RECIPIENT.balance == beforeRecipient + 8);
    }

    function test_adminSweepsExactSymbolicEthAmount(uint256 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(strategy), amount);
        uint256 recipientBefore = RECIPIENT.balance;
        vm.prank(ADMIN);
        strategy.sweepETH(payable(RECIPIENT));
        assert(address(strategy).balance == 0);
        assert(RECIPIENT.balance == recipientBefore + amount);
    }

    function test_adminSweepsToSymbolicSilentRecipient(address payable recipient) public {
        // Restrict the "silent recipient" domain to ordinary no-code accounts.
        // Cancun precompiles have code.length == 0 but may reject arbitrary calls.
        vm.assume(uint160(address(recipient)) > 0x0a && recipient != payable(address(strategy)));
        vm.assume(recipient.code.length == 0);
        vm.deal(address(strategy), 13);
        uint256 recipientBefore = recipient.balance;
        vm.prank(ADMIN);
        strategy.sweepETH(recipient);
        assert(address(strategy).balance == 0);
        assert(recipient.balance == recipientBefore + 13);
    }

    function test_ethSweepRecipientChecksPrecedeEmptyBalance() public {
        ERC4626StrategyHarnessToken stray = new ERC4626StrategyHarnessToken();
        vm.deal(address(strategy), 7);
        stray.mint(address(strategy), 13);
        usdc.mint(address(strategy), 17);
        (bool zeroSuccess, bytes memory zeroData) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(0)))));
        (bool selfSuccess, bytes memory selfData) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(strategy)))));
        assert(!zeroSuccess && !selfSuccess);
        _assertExactBytes(zeroData, abi.encodeWithSelector(SharedBase.ZeroAddress.selector));
        _assertExactBytes(
            selfData, abi.encodeWithSelector(SharedBase.InvalidSweepRecipient.selector, address(strategy))
        );
        assert(address(strategy).balance == 7);
        assert(stray.balanceOf(address(strategy)) == 13);
        assert(usdc.balanceOf(address(strategy)) == 17);
    }

    function test_emptyEthUsesExactErrorAndPreservesFundedTokenState() public {
        ERC4626StrategyHarnessToken stray = new ERC4626StrategyHarnessToken();
        stray.mint(address(strategy), 13);
        usdc.mint(address(strategy), 17);
        (bool success, bytes memory data) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepETH, (payable(RECIPIENT))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(0)));
        assert(stray.balanceOf(address(strategy)) == 13);
        assert(usdc.balanceOf(address(strategy)) == 17);
    }

    function test_rejectingEthReceiverUsesExactErrorAndRollsBackFundedState() public {
        ERC4626StrategyHarnessToken stray = new ERC4626StrategyHarnessToken();
        ERC4626StrategyRejectETH receiver = new ERC4626StrategyRejectETH();
        vm.deal(address(strategy), 7);
        stray.mint(address(strategy), 13);
        usdc.mint(address(strategy), 17);
        (bool success, bytes memory data) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(receiver)))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SharedBase.EthTransferFailed.selector));
        assert(address(strategy).balance == 7);
        assert(address(receiver).balance == 0);
        assert(stray.balanceOf(address(strategy)) == 13);
        assert(usdc.balanceOf(address(strategy)) == 17);
    }

    function test_ethSweepExactEventIsFirstLogForSilentReceiver() public {
        vm.deal(address(strategy), 9);
        vm.expectEmit(true, false, false, true, address(strategy));
        emit ETHSwept(RECIPIENT, 9);
        strategy.sweepETH(payable(RECIPIENT));
    }

    function test_logReceiverCallbackSucceedsAndRunsBeforeStrategyEventState() public {
        ERC4626StrategyLogReceiver receiver = new ERC4626StrategyLogReceiver();
        vm.deal(address(strategy), 11);
        strategy.sweepETH(payable(address(receiver)));
        assert(address(receiver).balance == 11);
        assert(address(strategy).balance == 0);
    }

    function test_tokenSweepOutsiderAclPrecedesRecipientAndTokenChecks() public {
        (bool success, bytes memory data) =
            _callAs(OUTSIDER, abi.encodeCall(SharedBase.sweepToken, (IERC20(address(0)), address(0))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, OUTSIDER));
    }

    function test_tokenSweepRecipientChecksPrecedeStructuralNothingToSweep() public {
        ERC4626StrategyHarnessToken stray = new ERC4626StrategyHarnessToken();
        vm.deal(address(strategy), 7);
        stray.mint(address(strategy), 13);
        usdc.mint(address(strategy), 17);
        (bool zeroSuccess, bytes memory zeroData) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(usdc)), address(0))));
        (bool selfSuccess, bytes memory selfData) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(usdc)), address(strategy))));
        assert(!zeroSuccess && !selfSuccess);
        _assertExactBytes(zeroData, abi.encodeWithSelector(SharedBase.ZeroAddress.selector));
        _assertExactBytes(
            selfData, abi.encodeWithSelector(SharedBase.InvalidSweepRecipient.selector, address(strategy))
        );
        assert(address(strategy).balance == 7);
        assert(stray.balanceOf(address(strategy)) == 13);
        assert(usdc.balanceOf(address(strategy)) == 17);
    }

    function test_everySymbolicTokenIsStructurallyUnsweepableWithExactPayload(address token) public {
        ERC4626StrategyHarnessToken stray = new ERC4626StrategyHarnessToken();
        stray.mint(address(strategy), 13);
        usdc.mint(address(strategy), 17);
        (bool success, bytes memory data) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(token), RECIPIENT)));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SharedBase.NothingToSweep.selector, token));
        assert(stray.balanceOf(address(strategy)) == 13);
        assert(usdc.balanceOf(address(strategy)) == 17);
        assert(stray.balanceOf(RECIPIENT) == 0);
        assert(usdc.balanceOf(RECIPIENT) == 0);
    }

    function test_pauseDoesNotGateEitherSweepSelector() public {
        registry.setPaused(address(strategy), true);
        vm.deal(address(strategy), 1);
        strategy.sweepETH(payable(RECIPIENT));
        ERC4626StrategyHarnessToken stray = new ERC4626StrategyHarnessToken();
        stray.mint(address(strategy), 1);
        (bool success, bytes memory data) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(stray)), RECIPIENT)));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(stray)));
        assert(stray.balanceOf(address(strategy)) == 1);
    }
}
