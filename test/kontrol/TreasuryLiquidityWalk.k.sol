// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";

contract TreasuryLiquidityWalkUSDC is ERC20 {
    constructor() ERC20("Kontrol USDC", "kUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFromAnyAddress(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Records the order of successful strategy call frames. A reverting
///      strategy's recorder mutation rolls back with that external call, as it
///      must under EVM atomicity; later continuation is observed directly.
contract TreasuryLiquidityWalkOrder {
    uint256 public nextOrder = 1;

    function record() external returns (uint256 order) {
        order = nextOrder;
        nextOrder = order + 1;
    }
}

/// @dev Fixed-behavior adversarial queue member. `Short` and `Overdeliver` use
///      `deliveryDelta`: Short delivers min(requested, delta), Overdeliver sends
///      requested + delta. `Degrade` sends the request to Treasury and leaks the
///      delta, modeling an intra-redemption totalAssets decrease.
contract TreasuryLiquidityWalkStrategy is IStrategy {
    using SafeERC20 for IERC20;

    enum Behavior {
        Exact,
        Zero,
        Revert,
        Short,
        Overdeliver,
        Degrade
    }

    error WithdrawReverted();
    error TotalAssetsReverted();

    IERC20 public immutable usdc;
    TreasuryLiquidityWalkOrder public immutable orderRecorder;
    Behavior public behavior;
    uint256 public deliveryDelta;
    bool public totalAssetsReverts;
    uint256 public withdrawCalls;
    uint256 public lastRequested;
    uint256 public lastOrder;

    constructor(IERC20 usdc_, TreasuryLiquidityWalkOrder recorder_) {
        usdc = usdc_;
        orderRecorder = recorder_;
    }

    function configure(Behavior behavior_, uint256 deliveryDelta_) external {
        behavior = behavior_;
        deliveryDelta = deliveryDelta_;
    }

    function setTotalAssetsReverts(bool value) external {
        totalAssetsReverts = value;
    }

    function underlying() external view returns (address) {
        return address(usdc);
    }

    function deploy(uint256) external {}

    function withdraw(uint256 amount) external {
        withdrawCalls += 1;
        lastRequested = amount;
        lastOrder = orderRecorder.record();

        Behavior selected = behavior;
        if (selected == Behavior.Revert) revert WithdrawReverted();
        if (selected == Behavior.Zero) return;

        uint256 delivered = amount;
        if (selected == Behavior.Short) {
            delivered = deliveryDelta < amount ? deliveryDelta : amount;
        } else if (selected == Behavior.Overdeliver) {
            delivered = amount + deliveryDelta;
        }
        usdc.safeTransfer(msg.sender, delivered);

        if (selected == Behavior.Degrade && deliveryDelta != 0) {
            usdc.safeTransfer(address(0xD), deliveryDelta);
        }
    }

    function totalAssets() external view returns (uint256) {
        if (totalAssetsReverts) revert TotalAssetsReverted();
        return usdc.balanceOf(address(this));
    }
}

contract TreasuryLiquidityWalkCaller {
    function approveAndMint(IERC20 usdc, Treasury treasury, uint256 usdcAmount) external {
        usdc.approve(address(treasury), usdcAmount);
        treasury.mintUSD8(usdcAmount);
    }

    function redeem(Treasury treasury, uint256 usd8Amount, uint256 minUsdcOut) external {
        treasury.redeemUSD8(usd8Amount, minUsdcOut);
    }

    function tryRedeem(Treasury treasury, uint256 usd8Amount, uint256 minUsdcOut)
        external
        returns (bool success, bytes memory returndata)
    {
        return address(treasury).call(abi.encodeCall(Treasury.redeemUSD8, (usd8Amount, minUsdcOut)));
    }
}

/// @notice Bounded liquidity-walk properties over production Registry, USD8,
///         and Treasury implementations behind real ERC1967 proxies.
/// @dev The strategy queue is explicitly fixed at N=3. Reserve amounts and
///      payouts are bounded to uint64 USDC units; scaling by 1e12 and all sums
///      in this harness therefore fit uint256. USDC is standard six-decimal and
///      fee-free. User USD8 is seeded only through the real Treasury mint path,
///      then the resulting reserves are allocated through depositToStrategy.
contract TreasuryLiquidityWalkKontrolTest is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant QUEUE_BOUND = 3;

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryLiquidityWalkUSDC internal usdc;
    TreasuryLiquidityWalkCaller internal user;
    TreasuryLiquidityWalkOrder internal orderRecorder;
    TreasuryLiquidityWalkStrategy internal strategy0;
    TreasuryLiquidityWalkStrategy internal strategy1;
    TreasuryLiquidityWalkStrategy internal strategy2;

    function setUp() public {
        usdc = new TreasuryLiquidityWalkUSDC();
        user = new TreasuryLiquidityWalkCaller();
        orderRecorder = new TreasuryLiquidityWalkOrder();

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

        strategy0 = new TreasuryLiquidityWalkStrategy(usdc, orderRecorder);
        strategy1 = new TreasuryLiquidityWalkStrategy(usdc, orderRecorder);
        strategy2 = new TreasuryLiquidityWalkStrategy(usdc, orderRecorder);
        treasury.addStrategy(strategy0, type(uint256).max);
        treasury.addStrategy(strategy1, type(uint256).max);
        treasury.addStrategy(strategy2, type(uint256).max);
        assert(treasury.strategiesLength() == QUEUE_BOUND);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _seedAndAllocate(uint64 total, uint64 allocation0, uint64 allocation1, uint64 allocation2) internal {
        vm.assume(total > 0);
        vm.assume(uint256(allocation0) + allocation1 + allocation2 <= total);
        usdc.mint(address(user), total);
        user.approveAndMint(usdc, treasury, total);
        if (allocation0 != 0) treasury.depositToStrategy(strategy0, allocation0);
        if (allocation1 != 0) treasury.depositToStrategy(strategy1, allocation1);
        if (allocation2 != 0) treasury.depositToStrategy(strategy2, allocation2);
    }

    function _redeemPayout(uint64 payout) internal {
        user.redeem(treasury, uint256(payout) * SCALE, payout);
    }

    function _mockValuationSequence(bytes[] memory returnData, uint64 expectedCalls) internal {
        bytes memory callData = abi.encodeCall(IStrategy.totalAssets, ());
        vm.mockCalls(address(strategy0), callData, returnData);
        vm.expectCall(address(strategy0), callData, expectedCalls);
    }

    function _assertRedeemRolledBack(uint256 supplyBefore, uint256 userUsd8Before, uint256 strategyBefore)
        internal
        view
    {
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(user)) == userUsd8Before);
        assert(usdc.balanceOf(address(user)) == 0);
        assert(usdc.balanceOf(address(strategy0)) == strategyBefore);
        assert(strategy0.withdrawCalls() == 0);
    }

    function _seedDistressedThreeStrategyState() internal {
        _seedAndAllocate(30 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT));
        usdc.burnFromAnyAddress(address(strategy2), 10 * UNIT);
        assert(treasury.getReserveBalance() * 3 == usd8.totalSupply() / SCALE * 2);
    }

    function test_idleFirstMakesNoStrategyWithdraw(uint64 payout) public {
        vm.assume(payout > 0 && payout <= 10 * UNIT);
        _seedAndAllocate(30 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT), 0);
        uint256 walletBefore = usdc.balanceOf(address(user));

        _redeemPayout(payout);

        assert(usdc.balanceOf(address(user)) == walletBefore + payout);
        assert(strategy0.withdrawCalls() == 0);
        assert(strategy1.withdrawCalls() == 0);
        assert(strategy2.withdrawCalls() == 0);
    }

    function test_zeroAssetEntryIsSkippedBeforeLaterContinuation(uint64 payout) public {
        vm.assume(payout > 0 && payout <= 10 * UNIT);
        _seedAndAllocate(20 * uint64(UNIT), 0, 10 * uint64(UNIT), 10 * uint64(UNIT));

        _redeemPayout(payout);

        assert(strategy0.withdrawCalls() == 0);
        assert(strategy1.withdrawCalls() == 1);
        assert(strategy1.lastRequested() == payout);
        assert(strategy1.lastOrder() == 1);
        assert(strategy2.withdrawCalls() == 0);
    }

    function test_firstEntryExactSatisfactionStopsQueue(uint64 payout) public {
        vm.assume(payout > 0 && payout <= 10 * UNIT);
        _seedAndAllocate(30 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT));

        _redeemPayout(payout);

        assert(strategy0.withdrawCalls() == 1);
        assert(strategy0.lastRequested() == payout);
        assert(strategy0.lastOrder() == 1);
        assert(strategy1.withdrawCalls() == 0);
        assert(strategy2.withdrawCalls() == 0);
    }

    function test_middleEntryExactSatisfactionStopsQueue(uint64 payout) public {
        vm.assume(payout > 10 * UNIT && payout <= 20 * UNIT);
        _seedAndAllocate(30 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT));

        _redeemPayout(payout);

        assert(strategy0.lastRequested() == 10 * UNIT);
        assert(strategy0.lastOrder() == 1);
        assert(strategy1.lastRequested() == payout - 10 * UNIT);
        assert(strategy1.lastOrder() == 2);
        assert(strategy2.withdrawCalls() == 0);
    }

    function test_lastEntryExactSatisfactionUsesStrictQueueOrder(uint64 payout) public {
        vm.assume(payout > 20 * UNIT && payout <= 30 * UNIT);
        _seedAndAllocate(30 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT));

        _redeemPayout(payout);

        assert(strategy0.lastRequested() == 10 * UNIT && strategy0.lastOrder() == 1);
        assert(strategy1.lastRequested() == 10 * UNIT && strategy1.lastOrder() == 2);
        assert(strategy2.lastRequested() == payout - 20 * UNIT && strategy2.lastOrder() == 3);
    }

    function test_revertingWithdrawIsSkippedAndLaterEntryContinues(uint64 payout) public {
        vm.assume(payout > 0 && payout <= 10 * UNIT);
        _seedAndAllocate(20 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT), 0);
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Revert, 0);

        _redeemPayout(payout);

        // The reverting frame's own counters roll back; successful continuation
        // proves the walk caught it instead of aborting or stopping.
        assert(strategy0.withdrawCalls() == 0);
        assert(strategy1.withdrawCalls() == 1);
        assert(strategy1.lastRequested() == payout);
        assert(strategy1.lastOrder() == 1);
        assert(strategy2.withdrawCalls() == 0);
    }

    function test_shortDeliveryRecomputesRemainingDeficitForNext(uint64 payout, uint64 shortDelivery) public {
        vm.assume(payout > 1 && payout <= 10 * UNIT);
        vm.assume(shortDelivery > 0 && shortDelivery < payout);
        _seedAndAllocate(20 * uint64(UNIT), 10 * uint64(UNIT), 10 * uint64(UNIT), 0);
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Short, shortDelivery);

        _redeemPayout(payout);

        assert(strategy0.lastRequested() == payout);
        assert(strategy0.lastOrder() == 1);
        assert(strategy1.lastRequested() == payout - shortDelivery);
        assert(strategy1.lastOrder() == 2);
        assert(usdc.balanceOf(address(user)) == payout);
    }

    function test_exhaustedQueueRollsBackPriorPullAndUsd8Burn() public {
        _seedAndAllocate(15 * uint64(UNIT), 5 * uint64(UNIT), 5 * uint64(UNIT), 5 * uint64(UNIT));
        strategy1.configure(TreasuryLiquidityWalkStrategy.Behavior.Zero, 0);
        strategy2.configure(TreasuryLiquidityWalkStrategy.Behavior.Revert, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userUsd8Before = usd8.balanceOf(address(user));
        uint256 treasuryIdleBefore = usdc.balanceOf(address(treasury));
        uint256 strategy0Before = usdc.balanceOf(address(strategy0));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 15 * UNIT * SCALE, 15 * UNIT);

        assert(!success);
        assert(
            keccak256(returndata)
                == keccak256(abi.encodeWithSelector(Treasury.InsufficientLiquidity.selector, 15 * UNIT, 5 * UNIT))
        );
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(user)) == userUsd8Before);
        assert(usdc.balanceOf(address(user)) == 0);
        assert(usdc.balanceOf(address(treasury)) == treasuryIdleBefore);
        assert(usdc.balanceOf(address(strategy0)) == strategy0Before);
        assert(strategy0.withdrawCalls() == 0);
        assert(strategy1.withdrawCalls() == 0);
        assert(orderRecorder.nextOrder() == 1);
    }

    function test_overdeliveryCannotPayMoreThanPrecomputedPayout(uint64 payout, uint64 extra) public {
        vm.assume(payout > 0 && payout <= 10 * UNIT);
        vm.assume(extra > 0 && uint256(payout) + extra <= 20 * UNIT);
        _seedAndAllocate(20 * uint64(UNIT), 20 * uint64(UNIT), 0, 0);
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Overdeliver, extra);
        uint256 walletBefore = usdc.balanceOf(address(user));

        _redeemPayout(payout);

        assert(usdc.balanceOf(address(user)) == walletBefore + payout);
        assert(usdc.balanceOf(address(treasury)) == extra);
        assert(strategy0.lastRequested() == payout);
        assert(strategy1.withdrawCalls() == 0);
    }

    function test_zeroPayoutBurnMakesNoStrategyWithdraw(uint128 redeemAmount) public {
        vm.assume(redeemAmount > 0 && redeemAmount < SCALE);
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 walletUsd8Before = usd8.balanceOf(address(user));

        user.redeem(treasury, redeemAmount, 0);

        assert(strategy0.withdrawCalls() == 0);
        assert(strategy1.withdrawCalls() == 0);
        assert(strategy2.withdrawCalls() == 0);
        assert(usdc.balanceOf(address(user)) == 0);
        assert(usd8.totalSupply() == supplyBefore - redeemAmount);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before - redeemAmount);
    }

    function test_totalAssetsRevertFailClosesBeforeBurnOrWithdraw() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        strategy0.setTotalAssetsReverts(true);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 walletUsd8Before = usd8.balanceOf(address(user));
        uint256 strategyBalanceBefore = usdc.balanceOf(address(strategy0));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 1 * UNIT * SCALE, 0);

        assert(!success);
        assert(_selector(returndata) == TreasuryLiquidityWalkStrategy.TotalAssetsReverted.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before);
        assert(usdc.balanceOf(address(strategy0)) == strategyBalanceBefore);
        assert(strategy0.withdrawCalls() == 0);
        assert(strategy1.withdrawCalls() == 0);
        assert(strategy2.withdrawCalls() == 0);
    }

    function test_reservePostcheckAcceptsExactlyHundredBaseUnitDegradation() public {
        _seedAndAllocate(20 * uint64(UNIT), 20 * uint64(UNIT), 0, 0);
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Degrade, treasury.RESERVE_CHECK_TOLERANCE());

        _redeemPayout(10 * uint64(UNIT));

        assert(usdc.balanceOf(address(user)) == 10 * UNIT);
        assert(usd8.totalSupply() == 10 * UNIT * SCALE);
        assert(usdc.balanceOf(address(strategy0)) == 10 * UNIT - treasury.RESERVE_CHECK_TOLERANCE());
        assert(strategy0.withdrawCalls() == 1);
    }

    function test_reservePostcheckRejectsHundredAndOneAndRollsBack() public {
        _seedAndAllocate(20 * uint64(UNIT), 20 * uint64(UNIT), 0, 0);
        uint256 degradation = treasury.RESERVE_CHECK_TOLERANCE() + 1;
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Degrade, degradation);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 walletUsd8Before = usd8.balanceOf(address(user));
        uint256 strategyBalanceBefore = usdc.balanceOf(address(strategy0));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 10 * UNIT * SCALE, 0);

        assert(!success);
        assert(_selector(returndata) == Treasury.ReserveSupplyStatusWorsened.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before);
        assert(usdc.balanceOf(address(user)) == 0);
        assert(usdc.balanceOf(address(strategy0)) == strategyBalanceBefore);
        assert(usdc.balanceOf(address(0xD)) == 0);
        assert(strategy0.withdrawCalls() == 0);
        assert(orderRecorder.nextOrder() == 1);
    }

    function test_callIndexedPrecheckValuationDecodeRevertIsAtomic() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userBefore = usd8.balanceOf(address(user));
        uint256 strategyBefore = usdc.balanceOf(address(strategy0));
        bytes[] memory sequence = new bytes[](1);
        sequence[0] = bytes("");
        _mockValuationSequence(sequence, 1);

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 5 * UNIT * SCALE, 0);

        assert(!success && returndata.length == 0);
        _assertRedeemRolledBack(supplyBefore, userBefore, strategyBefore);
    }

    function test_callIndexedPayoutValuationDecodeRevertIsAtomic() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userBefore = usd8.balanceOf(address(user));
        uint256 strategyBefore = usdc.balanceOf(address(strategy0));
        bytes[] memory sequence = new bytes[](2);
        sequence[0] = abi.encode(10 * UNIT);
        sequence[1] = bytes("");
        _mockValuationSequence(sequence, 2);

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 5 * UNIT * SCALE, 0);

        assert(!success && returndata.length == 0);
        _assertRedeemRolledBack(supplyBefore, userBefore, strategyBefore);
    }

    function test_callIndexedWalkValuationDecodeRevertRollsBackBurn() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userBefore = usd8.balanceOf(address(user));
        uint256 strategyBefore = usdc.balanceOf(address(strategy0));
        bytes[] memory sequence = new bytes[](3);
        sequence[0] = abi.encode(10 * UNIT);
        sequence[1] = abi.encode(10 * UNIT);
        sequence[2] = bytes("");
        _mockValuationSequence(sequence, 3);

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 5 * UNIT * SCALE, 0);

        assert(!success && returndata.length == 0);
        _assertRedeemRolledBack(supplyBefore, userBefore, strategyBefore);
    }

    function test_callIndexedWalkUnderreportChangesToPullThenExhaustionIsAtomic() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userBefore = usd8.balanceOf(address(user));
        uint256 strategyBefore = usdc.balanceOf(address(strategy0));
        bytes[] memory sequence = new bytes[](3);
        sequence[0] = abi.encode(10 * UNIT);
        sequence[1] = abi.encode(10 * UNIT);
        sequence[2] = abi.encode(4 * UNIT);
        _mockValuationSequence(sequence, 3);

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 10 * UNIT * SCALE, 0);

        assert(!success);
        assert(
            keccak256(returndata)
                == keccak256(abi.encodeWithSelector(Treasury.InsufficientLiquidity.selector, 10 * UNIT, 4 * UNIT))
        );
        _assertRedeemRolledBack(supplyBefore, userBefore, strategyBefore);
        assert(orderRecorder.nextOrder() == 1);
    }

    function test_callIndexedPayoutDriftChangesExactPayoutAndCompletesFourMeasuredStages() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        bytes[] memory sequence = new bytes[](4);
        sequence[0] = abi.encode(10 * UNIT); // modifier precheck
        sequence[1] = abi.encode(5 * UNIT); // payout calculation
        sequence[2] = abi.encode(5 * UNIT); // liquidity walk cap
        sequence[3] = abi.encode(5 * UNIT); // modifier postcheck
        _mockValuationSequence(sequence, 4);

        user.redeem(treasury, 10 * UNIT * SCALE, 5 * UNIT);

        assert(usdc.balanceOf(address(user)) == 5 * UNIT);
        assert(usdc.balanceOf(address(strategy0)) == 5 * UNIT);
        assert(usd8.totalSupply() == 0);
        assert(strategy0.lastRequested() == 5 * UNIT);
    }

    function test_callIndexedPostcheckValuationDecodeRevertRollsBackPayoutAndPull() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userBefore = usd8.balanceOf(address(user));
        uint256 strategyBefore = usdc.balanceOf(address(strategy0));
        bytes[] memory sequence = new bytes[](4);
        sequence[0] = abi.encode(10 * UNIT);
        sequence[1] = abi.encode(10 * UNIT);
        sequence[2] = abi.encode(10 * UNIT);
        sequence[3] = bytes("");
        _mockValuationSequence(sequence, 4);

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 5 * UNIT * SCALE, 5 * UNIT);

        assert(!success && returndata.length == 0);
        _assertRedeemRolledBack(supplyBefore, userBefore, strategyBefore);
        assert(orderRecorder.nextOrder() == 1);
    }

    function test_callIndexedPostcheckDownwardDriftRevertsWholeSuccessfulWalk() public {
        _seedAndAllocate(10 * uint64(UNIT), 10 * uint64(UNIT), 0, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userBefore = usd8.balanceOf(address(user));
        uint256 strategyBefore = usdc.balanceOf(address(strategy0));
        bytes[] memory sequence = new bytes[](4);
        sequence[0] = abi.encode(10 * UNIT);
        sequence[1] = abi.encode(10 * UNIT);
        sequence[2] = abi.encode(10 * UNIT);
        sequence[3] = abi.encode(0);
        _mockValuationSequence(sequence, 4);

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 5 * UNIT * SCALE, 5 * UNIT);

        assert(!success && _selector(returndata) == Treasury.ReserveSupplyStatusWorsened.selector);
        _assertRedeemRolledBack(supplyBefore, userBefore, strategyBefore);
        assert(orderRecorder.nextOrder() == 1);
    }

    function test_distressedRedeemPullsExactPayoutFromFirstStrategy() public {
        _seedDistressedThreeStrategyState();

        user.redeem(treasury, 15 * UNIT * SCALE, 10 * UNIT);

        assert(usdc.balanceOf(address(user)) == 10 * UNIT);
        assert(usd8.totalSupply() == 15 * UNIT * SCALE);
        assert(strategy0.lastRequested() == 10 * UNIT);
        assert(strategy1.withdrawCalls() == 0);
    }

    function test_distressedRedeemComposesShortDeliveryWithLaterPull() public {
        _seedDistressedThreeStrategyState();
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Short, 4 * UNIT);

        user.redeem(treasury, 15 * UNIT * SCALE, 10 * UNIT);

        assert(usdc.balanceOf(address(user)) == 10 * UNIT);
        assert(strategy0.lastRequested() == 10 * UNIT);
        assert(strategy1.lastRequested() == 6 * UNIT);
        assert(strategy0.lastOrder() == 1 && strategy1.lastOrder() == 2);
    }

    function test_distressedRedeemSkipsRevertingPullAndContinues() public {
        _seedDistressedThreeStrategyState();
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Revert, 0);

        user.redeem(treasury, 15 * UNIT * SCALE, 10 * UNIT);

        assert(usdc.balanceOf(address(user)) == 10 * UNIT);
        assert(strategy0.withdrawCalls() == 0);
        assert(strategy1.lastRequested() == 10 * UNIT);
        assert(strategy1.lastOrder() == 1);
    }

    function test_distressedExhaustionRollsBackShortPullAndBurn() public {
        _seedDistressedThreeStrategyState();
        strategy0.configure(TreasuryLiquidityWalkStrategy.Behavior.Short, 4 * UNIT);
        strategy1.configure(TreasuryLiquidityWalkStrategy.Behavior.Zero, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userBefore = usd8.balanceOf(address(user));
        uint256 strategyBefore = usdc.balanceOf(address(strategy0));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 15 * UNIT * SCALE, 0);

        assert(!success);
        assert(
            keccak256(returndata)
                == keccak256(abi.encodeWithSelector(Treasury.InsufficientLiquidity.selector, 10 * UNIT, 4 * UNIT))
        );
        _assertRedeemRolledBack(supplyBefore, userBefore, strategyBefore);
        assert(strategy1.withdrawCalls() == 0);
        assert(orderRecorder.nextOrder() == 1);
    }
}
