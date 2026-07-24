// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @dev Standard six-decimal ERC-20. The unrestricted mint is test-only setup;
///      transfers themselves deliberately retain ordinary OZ ERC-20 behavior.
contract TreasuryStrategyFlowsUSDC is ERC20 {
    constructor() ERC20("Kontrol USDC", "kUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Curated-strategy model. Each behavior is selected explicitly by the
///      property; Honest uses the real token balance for totalAssets and exact
///      withdrawals. ShortWithdraw models a strategy outside the IStrategy
///      exact-or-revert assumption, which Treasury nevertheless accounts by the
///      observed idle-balance delta.
contract TreasuryStrategyFlowsStrategy is IStrategy {
    enum Behavior {
        Honest,
        RevertDeploy,
        RevertWithdraw,
        ShortWithdraw,
        RevertTotalAssets,
        MaxTotalAssets,
        CallbackDeploy,
        CallbackWithdraw
    }

    IERC20 public immutable asset;
    Treasury public treasury;
    Behavior public behavior;
    uint256 public deployCalls;
    uint256 public withdrawCalls;
    uint256 public lastDeployAmount;
    uint256 public lastWithdrawAmount;
    uint256 public callbackAttempts;
    uint256 public callbackSuccesses;
    mapping(uint256 index => bytes4 selector) public callbackSelector;

    error DeployRejected();
    error WithdrawRejected();
    error ValuationRejected();

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function configureTreasury(Treasury treasury_) external {
        treasury = treasury_;
        asset.approve(address(treasury_), type(uint256).max);
    }

    function setBehavior(Behavior behavior_) external {
        behavior = behavior_;
    }

    function underlying() external view returns (address) {
        return address(asset);
    }

    function deploy(uint256 amount) external {
        if (behavior == Behavior.RevertDeploy) revert DeployRejected();
        deployCalls++;
        lastDeployAmount = amount;
        require(asset.balanceOf(address(this)) >= amount, "assets not pushed");
        if (behavior == Behavior.CallbackDeploy) _attemptFundPathReentry();
    }

    function withdraw(uint256 amount) external {
        if (behavior == Behavior.RevertWithdraw) revert WithdrawRejected();
        withdrawCalls++;
        lastWithdrawAmount = amount;
        if (behavior == Behavior.CallbackWithdraw) _attemptFundPathReentry();
        uint256 sent = behavior == Behavior.ShortWithdraw ? amount - 1 : amount;
        require(asset.transfer(msg.sender, sent), "transfer failed");
    }

    function totalAssets() external view returns (uint256) {
        if (behavior == Behavior.RevertTotalAssets) revert ValuationRejected();
        if (behavior == Behavior.MaxTotalAssets) return type(uint256).max;
        return asset.balanceOf(address(this));
    }

    function _attemptFundPathReentry() internal {
        _attempt(abi.encodeCall(Treasury.mintUSD8, (uint256(1))));
        _attempt(abi.encodeCall(Treasury.redeemUSD8, (uint256(1), uint256(0))));
        _attempt(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(this)), uint256(1))));
        _attempt(abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(this)), uint256(1))));
        _attempt(abi.encodeCall(Treasury.harvestAndDistribute, ()));
    }

    function _attempt(bytes memory data) internal {
        uint256 index = callbackAttempts;
        callbackAttempts = index + 1;
        (bool success, bytes memory returndata) = address(treasury).call(data);
        if (success) callbackSuccesses++;
        if (returndata.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(returndata, 0x20))
            }
            callbackSelector[index] = selector;
        }
    }
}

/// @notice Strategy-flow properties over production Registry, USD8, and Treasury
///         implementations behind real ERC1967 proxies.
/// @dev Reserve inputs are uint64 and strategy count is explicitly bounded to
///      N <= 3. Arithmetic sums therefore fit uint256 except in the dedicated
///      overflow property. The reserve token is assumed to be standard USDC and
///      approved strategies are assumed exact-or-revert unless a property names
///      an adversarial behavior. Callback strategies are deliberately made admins
///      so the transient guard, rather than ACL, rejects nested fund-path calls.
contract TreasuryStrategyFlowsKontrolTest is Test {
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryStrategyFlowsUSDC internal usdc;

    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    function setUp() public {
        usdc = new TreasuryStrategyFlowsUSDC();
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(usdc))))
                )
            )
        );
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
    }

    function _newApprovedStrategy() internal returns (TreasuryStrategyFlowsStrategy strategy) {
        strategy = new TreasuryStrategyFlowsStrategy(usdc);
        strategy.configureTreasury(treasury);
        treasury.addStrategy(strategy, type(uint256).max);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _assertCallbackBlocked(TreasuryStrategyFlowsStrategy strategy) internal view {
        assert(strategy.callbackAttempts() == 5);
        assert(strategy.callbackSuccesses() == 0);
        bytes4 expected = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
        for (uint256 i = 0; i < 5; i++) {
            assert(strategy.callbackSelector(i) == expected);
        }
    }

    function test_honestDepositMovesExactIdleToStrategyAndPreservesReserve(uint64 idle, uint64 amount) public {
        vm.assume(amount > 0 && amount <= idle);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        usdc.mint(address(treasury), idle);
        uint256 reserveBefore = treasury.getReserveBalance();

        treasury.depositToStrategy(strategy, amount);

        assert(usdc.balanceOf(address(treasury)) == uint256(idle) - amount);
        assert(usdc.balanceOf(address(strategy)) == amount);
        assert(strategy.deployCalls() == 1);
        assert(strategy.lastDeployAmount() == amount);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    function test_deployRevertRollsBackPushAndCounters(uint64 idle, uint64 amount) public {
        vm.assume(amount > 0 && amount <= idle);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.RevertDeploy);
        usdc.mint(address(treasury), idle);

        (bool success, bytes memory returndata) = address(treasury)
            .call(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(strategy)), uint256(amount))));

        assert(!success);
        assert(_selector(returndata) == TreasuryStrategyFlowsStrategy.DeployRejected.selector);
        assert(usdc.balanceOf(address(treasury)) == idle);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(strategy.deployCalls() == 0);
        assert(treasury.getReserveBalance() == idle);
    }

    function test_zeroApprovedDepositAndWithdrawRevertAtomically(uint64 idle) public {
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        usdc.mint(address(treasury), idle);

        (bool depositSuccess, bytes memory depositData) = address(treasury)
            .call(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(strategy)), uint256(0))));
        (bool withdrawSuccess, bytes memory withdrawData) = address(treasury)
            .call(abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(strategy)), uint256(0))));

        assert(!depositSuccess && _selector(depositData) == Treasury.ZeroAmount.selector);
        assert(!withdrawSuccess && _selector(withdrawData) == Treasury.ZeroAmount.selector);
        assert(usdc.balanceOf(address(treasury)) == idle);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(strategy.deployCalls() == 0 && strategy.withdrawCalls() == 0);
    }

    function test_unapprovedDepositAndWithdrawRevertBeforeExternalMutation(uint64 idle, uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryStrategyFlowsStrategy strategy = new TreasuryStrategyFlowsStrategy(usdc);
        strategy.configureTreasury(treasury);
        usdc.mint(address(treasury), idle);

        (bool depositSuccess, bytes memory depositData) = address(treasury)
            .call(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(strategy)), uint256(amount))));
        (bool withdrawSuccess, bytes memory withdrawData) = address(treasury)
            .call(abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(strategy)), uint256(amount))));

        assert(!depositSuccess && _selector(depositData) == Treasury.StrategyNotApproved.selector);
        assert(!withdrawSuccess && _selector(withdrawData) == Treasury.StrategyNotApproved.selector);
        assert(usdc.balanceOf(address(treasury)) == idle);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(strategy.deployCalls() == 0 && strategy.withdrawCalls() == 0);
    }

    function test_insufficientIdleDepositRollsBackWithoutCallingStrategy(uint64 idle, uint64 extra) public {
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        usdc.mint(address(treasury), idle);
        uint256 requested = uint256(idle) + uint256(extra) + 1;

        (bool success,) = address(treasury)
            .call(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(strategy)), requested)));

        assert(!success);
        assert(usdc.balanceOf(address(treasury)) == idle);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(strategy.deployCalls() == 0);
        assert(treasury.getReserveBalance() == idle);
    }

    function test_honestManualWithdrawalUsesExactActualDeltaAndPreservesReserve(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        usdc.mint(address(treasury), amount);
        treasury.depositToStrategy(strategy, amount);
        uint256 reserveBefore = treasury.getReserveBalance();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit WithdrawnFromStrategy(strategy, amount);
        treasury.withdrawFromStrategy(strategy, amount);

        assert(usdc.balanceOf(address(treasury)) == amount);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(strategy.withdrawCalls() == 1 && strategy.lastWithdrawAmount() == amount);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    function test_withdrawRevertIsAtomic(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        usdc.mint(address(treasury), amount);
        treasury.depositToStrategy(strategy, amount);
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.RevertWithdraw);

        (bool success, bytes memory returndata) = address(treasury)
            .call(abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(strategy)), uint256(amount))));

        assert(!success);
        assert(_selector(returndata) == TreasuryStrategyFlowsStrategy.WithdrawRejected.selector);
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(usdc.balanceOf(address(strategy)) == amount);
        assert(strategy.withdrawCalls() == 0);
        assert(treasury.getReserveBalance() == amount);
    }

    function test_shortWithdrawalIsAcceptedEmittedAndAccountedByActualDelta(uint64 amount) public {
        vm.assume(amount > 1);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        usdc.mint(address(treasury), amount);
        treasury.depositToStrategy(strategy, amount);
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.ShortWithdraw);
        uint256 actual = uint256(amount) - 1;

        vm.expectEmit(true, false, false, true, address(treasury));
        emit WithdrawnFromStrategy(strategy, actual);
        treasury.withdrawFromStrategy(strategy, amount);

        assert(usdc.balanceOf(address(treasury)) == actual);
        assert(usdc.balanceOf(address(strategy)) == 1);
        assert(strategy.lastWithdrawAmount() == amount);
        assert(treasury.getReserveBalance() == amount);
    }

    function test_reserveSumsIdleAndUpToThreeStrategies(uint8 count, uint64 idle, uint64 a, uint64 b, uint64 c) public {
        vm.assume(count <= 3);
        uint64[3] memory assets = [a, b, c];
        usdc.mint(address(treasury), idle);
        uint256 expected = idle;
        for (uint256 i = 0; i < count; i++) {
            TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
            usdc.mint(address(strategy), assets[i]);
            expected += assets[i];
        }

        assert(treasury.strategiesLength() == count);
        assert(treasury.getReserveBalance() == expected);
    }

    function test_revertingTotalAssetsFailClosesReserveView(uint64 idle) public {
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        usdc.mint(address(treasury), idle);
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.RevertTotalAssets);

        (bool success, bytes memory returndata) =
            address(treasury).staticcall(abi.encodeCall(Treasury.getReserveBalance, ()));

        assert(!success);
        assert(_selector(returndata) == TreasuryStrategyFlowsStrategy.ValuationRejected.selector);
        assert(usdc.balanceOf(address(treasury)) == idle);
    }

    function test_revertingTotalAssetsFailClosesMintAndHarvestAtomically(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.RevertTotalAssets);
        usdc.mint(address(this), amount);
        usdc.approve(address(treasury), amount);
        uint256 walletBefore = usdc.balanceOf(address(this));

        (bool mintSuccess, bytes memory mintData) =
            address(treasury).call(abi.encodeCall(Treasury.mintUSD8, (uint256(amount))));
        (bool harvestSuccess, bytes memory harvestData) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!mintSuccess && _selector(mintData) == TreasuryStrategyFlowsStrategy.ValuationRejected.selector);
        assert(!harvestSuccess && _selector(harvestData) == TreasuryStrategyFlowsStrategy.ValuationRejected.selector);
        assert(usdc.balanceOf(address(this)) == walletBefore);
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(usdc.allowance(address(this), address(treasury)) == amount);
        assert(usd8.totalSupply() == 0 && usd8.balanceOf(address(this)) == 0);
    }

    function test_reserveSumOverflowReverts() public {
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.MaxTotalAssets);
        usdc.mint(address(treasury), 1);

        (bool success, bytes memory returndata) =
            address(treasury).staticcall(abi.encodeCall(Treasury.getReserveBalance, ()));

        assert(!success);
        assert(_selector(returndata) == PANIC_SELECTOR);
        assert(usdc.balanceOf(address(treasury)) == 1);
    }

    function test_deployCallbackCannotReenterNonReentrantFundPaths(uint64 amount) public {
        vm.assume(amount > 0 && amount < type(uint64).max);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        registry.setAdmin(address(strategy), true);
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.CallbackDeploy);
        usdc.mint(address(treasury), uint256(amount) + 1);
        uint256 reserveBefore = treasury.getReserveBalance();

        treasury.depositToStrategy(strategy, amount);

        _assertCallbackBlocked(strategy);
        assert(strategy.deployCalls() == 1);
        assert(usdc.balanceOf(address(strategy)) == amount);
        assert(usdc.balanceOf(address(treasury)) == 1);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == 0);
    }

    function test_withdrawCallbackCannotReenterNonReentrantFundPaths(uint64 amount) public {
        vm.assume(amount > 0 && amount < type(uint64).max);
        TreasuryStrategyFlowsStrategy strategy = _newApprovedStrategy();
        registry.setAdmin(address(strategy), true);
        usdc.mint(address(treasury), uint256(amount) + 1);
        treasury.depositToStrategy(strategy, amount);
        strategy.setBehavior(TreasuryStrategyFlowsStrategy.Behavior.CallbackWithdraw);
        uint256 reserveBefore = treasury.getReserveBalance();

        treasury.withdrawFromStrategy(strategy, amount);

        _assertCallbackBlocked(strategy);
        assert(strategy.withdrawCalls() == 1);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == uint256(amount) + 1);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == 0);
    }
}
