// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {
    ERC4626StrategyAdversarialVault,
    ERC4626StrategyHarnessToken,
    ERC4626StrategyKontrolBase,
    ERC4626StrategyLogReceiver,
    ERC4626StrategySwapRouter
} from "../properties/ERC4626StrategyHarness.k.sol";

/// @notice Foundry-only transaction-wide order regressions for later application logs.
/// @dev Deliberately uses camel `testFoundry...` names so pinned Kontrol's `test_` inventory excludes them.
contract ERC4626StrategyFoundryEventOrderTest is ERC4626StrategyKontrolBase {
    bytes32 internal constant REGISTRY_CHANGED = keccak256("RegistryChanged(address,address)");
    bytes32 internal constant APPROVAL = keccak256("Approval(address,address,uint256)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant DEPOSIT = keccak256("Deposit(address,address,uint256,uint256)");
    bytes32 internal constant WITHDRAW = keccak256("Withdraw(address,address,address,uint256,uint256)");
    bytes32 internal constant DEPLOYED = keccak256("Deployed(uint256)");
    bytes32 internal constant WITHDRAWN = keccak256("Withdrawn(uint256)");
    bytes32 internal constant ROUTER_CALLED = keccak256("RouterCalled(uint256,uint256)");
    bytes32 internal constant TOKEN_SWAPPED = keccak256("TokenSwapped(address,address,address,uint256,uint256)");
    bytes32 internal constant RECEIVED = keccak256("Received(uint256)");
    bytes32 internal constant ETH_SWEPT = keccak256("ETHSwept(address,uint256)");

    function _topicAddress(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _assertLog(Vm.Log memory log, address emitter, bytes32 signature) internal pure {
        assert(log.emitter == emitter);
        assert(log.topics.length > 0 && log.topics[0] == signature);
    }

    function _assertTransfer(Vm.Log memory log, address emitter, address from, address to, uint256 amount)
        internal
        pure
    {
        _assertLog(log, emitter, TRANSFER);
        assert(log.topics.length == 3);
        assert(log.topics[1] == _topicAddress(from));
        assert(log.topics[2] == _topicAddress(to));
        assert(keccak256(log.data) == keccak256(abi.encode(amount)));
    }

    function _assertApproval(Vm.Log memory log, address emitter, address owner, address spender, uint256 amount)
        internal
        pure
    {
        _assertLog(log, emitter, APPROVAL);
        assert(log.topics.length == 3);
        assert(log.topics[1] == _topicAddress(owner));
        assert(log.topics[2] == _topicAddress(spender));
        assert(keccak256(log.data) == keccak256(abi.encode(amount)));
    }

    function _assertDeposit(
        Vm.Log memory log,
        address emitter,
        address sender,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal pure {
        _assertLog(log, emitter, DEPOSIT);
        assert(log.topics.length == 3);
        assert(log.topics[1] == _topicAddress(sender));
        assert(log.topics[2] == _topicAddress(owner));
        assert(keccak256(log.data) == keccak256(abi.encode(assets, shares)));
    }

    function _assertWithdraw(
        Vm.Log memory log,
        address emitter,
        address sender,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal pure {
        _assertLog(log, emitter, WITHDRAW);
        assert(log.topics.length == 4);
        assert(log.topics[1] == _topicAddress(sender));
        assert(log.topics[2] == _topicAddress(receiver));
        assert(log.topics[3] == _topicAddress(owner));
        assert(keccak256(log.data) == keccak256(abi.encode(assets, shares)));
    }

    function _assertUnindexed(Vm.Log memory log, address emitter, bytes32 signature, bytes memory data) internal pure {
        _assertLog(log, emitter, signature);
        assert(log.topics.length == 1);
        assert(keccak256(log.data) == keccak256(data));
    }

    function testFoundry_constructorRegistryChangedPrecedesVaultApproval() public {
        vm.recordLogs();
        ERC4626Strategy fresh = new ERC4626Strategy(address(treasury), registry, vault);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length == 2);
        _assertLog(logs[0], address(fresh), REGISTRY_CHANGED);
        assert(logs[0].topics.length == 3);
        assert(logs[0].topics[1] == bytes32(0));
        assert(logs[0].topics[2] == _topicAddress(address(registry)));
        assert(logs[0].data.length == 0);
        _assertApproval(logs[1], address(usdc), address(fresh), address(vault), type(uint256).max);
    }

    function testFoundry_deployStandardPrefixThenExactStrategyEvent() public {
        _fundStrategy(10);
        vm.recordLogs();
        _deploy(10);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length == 4);
        _assertTransfer(logs[0], address(usdc), address(strategy), address(vault), 10);
        _assertTransfer(logs[1], address(vault), address(0), address(strategy), 10);
        _assertDeposit(logs[2], address(vault), address(strategy), address(strategy), 10, 10);
        _assertUnindexed(logs[3], address(strategy), DEPLOYED, abi.encode(uint256(10)));
    }

    function testFoundry_withdrawStandardPrefixThenExactStrategyEvent() public {
        _fundStrategy(10);
        _deploy(10);
        vm.recordLogs();
        _withdraw(4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length == 4);
        _assertTransfer(logs[0], address(vault), address(strategy), address(0), 4);
        _assertTransfer(logs[1], address(usdc), address(vault), address(treasury), 4);
        _assertWithdraw(
            logs[2], address(vault), address(strategy), address(treasury), address(strategy), uint256(4), uint256(4)
        );
        _assertUnindexed(logs[3], address(strategy), WITHDRAWN, abi.encode(uint256(4)));
    }

    function testFoundry_withdrawOverdeliveryEmitsMeasuredAmountAfterVaultLogs() public {
        ERC4626StrategyAdversarialVault overVault = new ERC4626StrategyAdversarialVault(usdc);
        ERC4626Strategy overStrategy = new ERC4626Strategy(address(treasury), registry, overVault);
        usdc.mint(address(overStrategy), 100);
        treasury.deployInto(overStrategy, 100);
        overVault.setWithdrawMode(ERC4626StrategyAdversarialVault.WithdrawMode.Over, 1);

        vm.recordLogs();
        treasury.withdrawFrom(overStrategy, 40);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length == 4);
        _assertTransfer(logs[0], address(overVault), address(overStrategy), address(0), 40);
        _assertTransfer(logs[1], address(usdc), address(overVault), address(treasury), 41);
        _assertWithdraw(
            logs[2],
            address(overVault),
            address(overStrategy),
            address(treasury),
            address(overStrategy),
            uint256(41),
            uint256(40)
        );
        _assertUnindexed(logs[3], address(overStrategy), WITHDRAWN, abi.encode(uint256(41)));
        assert(usdc.balanceOf(address(treasury)) == 41);
    }

    function testFoundry_swapApprovalRouterResetTransferThenExactMeasuredEvent() public {
        ERC4626StrategyHarnessToken reward = new ERC4626StrategyHarnessToken();
        ERC4626StrategySwapRouter router = new ERC4626StrategySwapRouter();
        registry.setSwapRoute(address(router), address(router), true);
        reward.mint(address(strategy), 5);
        bytes memory route =
            abi.encodeCall(router.swap, (IERC20(address(reward)), uint256(5), usdc, uint256(7), address(strategy)));
        vm.recordLogs();
        uint256 amountOut = strategy.swap(reward, usdc, 5, address(router), address(router), route, 7);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(amountOut == 7 && logs.length == 7);
        _assertApproval(logs[0], address(reward), address(strategy), address(router), 5);
        _assertTransfer(logs[1], address(reward), address(strategy), address(router), 5);
        _assertTransfer(logs[2], address(usdc), address(0), address(strategy), 7);
        _assertUnindexed(logs[3], address(router), ROUTER_CALLED, abi.encode(uint256(5), uint256(7)));
        _assertApproval(logs[4], address(reward), address(strategy), address(router), 0);
        _assertTransfer(logs[5], address(usdc), address(strategy), address(treasury), 7);
        _assertLog(logs[6], address(strategy), TOKEN_SWAPPED);
        assert(logs[6].topics.length == 4);
        assert(logs[6].topics[1] == _topicAddress(address(reward)));
        assert(logs[6].topics[2] == _topicAddress(address(usdc)));
        assert(logs[6].topics[3] == _topicAddress(address(router)));
        assert(keccak256(logs[6].data) == keccak256(abi.encode(uint256(5), uint256(7))));
    }

    function testFoundry_receiverCallbackLogPrecedesExactEthSweptEvent() public {
        ERC4626StrategyLogReceiver receiver = new ERC4626StrategyLogReceiver();
        vm.deal(address(strategy), 3);
        vm.recordLogs();
        strategy.sweepETH(payable(address(receiver)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length == 2);
        _assertUnindexed(logs[0], address(receiver), RECEIVED, abi.encode(uint256(3)));
        _assertLog(logs[1], address(strategy), ETH_SWEPT);
        assert(logs[1].topics.length == 2);
        assert(logs[1].topics[1] == _topicAddress(address(receiver)));
        assert(keccak256(logs[1].data) == keccak256(abi.encode(uint256(3))));
    }

    function testFoundry_failedSymbolicTokenSweepEmitsNoLogs(address token) public {
        vm.recordLogs();
        (bool success, bytes memory data) =
            address(strategy).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(token), address(0xB0B))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SharedBase.NothingToSweep.selector, token));
        assert(vm.getRecordedLogs().length == 0);
    }
}
