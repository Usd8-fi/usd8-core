// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";
import {IProfitDistributionReceiver} from "../../src/interfaces/IProfitDistributionReceiver.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

contract TreasuryHarvestHooksUSDC is ERC20 {
    constructor() ERC20("Kontrol USDC", "kUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Hook receiver with ordinary USD8 transferFrom behavior. It also implements
///      a zero-valued strategy only so callback properties can make every nested
///      fund path satisfy its non-guard prerequisites.
contract TreasuryHarvestHookReceiver is IProfitDistributionReceiver, IStrategy {
    enum Behavior {
        EXACT_PULL,
        NONE,
        PARTIAL,
        REVERT,
        CALLBACK_GUARDED,
        CONFIG_MUTATION
    }

    IERC20 public immutable token;
    IERC20 public immutable reserve;
    Treasury public treasury;
    Behavior public behavior;
    bool public propagateCallbackFailure;
    uint256 public receiveCalls;
    uint256 public totalPulled;
    uint256 public callbackAttempts;
    uint256 public callbackSuccesses;
    address public mutationCandidate;
    bool public mutationSuccess;
    bytes4 public mutationSelector;
    mapping(uint256 index => bytes4 selector) public callbackSelector;

    error HookRejected();
    error CallbackGuards(bytes4 mint_, bytes4 redeem_, bytes4 deposit_, bytes4 withdraw_, bytes4 harvest_);

    constructor(IERC20 token_, IERC20 reserve_) {
        token = token_;
        reserve = reserve_;
    }

    function configure(Treasury treasury_, Behavior behavior_, bool propagate_) external {
        treasury = treasury_;
        behavior = behavior_;
        propagateCallbackFailure = propagate_;
        reserve.approve(address(treasury_), type(uint256).max);
    }

    function setMutationCandidate(address candidate) external {
        mutationCandidate = candidate;
    }

    function receiveProfitDistribution(uint256 amount) external {
        receiveCalls++;
        if (behavior == Behavior.REVERT) revert HookRejected();
        if (behavior == Behavior.NONE) return;
        if (behavior == Behavior.PARTIAL) {
            uint256 pulled = amount - 1;
            if (pulled != 0) require(token.transferFrom(msg.sender, address(this), pulled), "partial pull failed");
            totalPulled += pulled;
            return;
        }
        if (behavior == Behavior.CALLBACK_GUARDED) _attemptAllFundPaths();
        if (behavior == Behavior.CONFIG_MUTATION) _attemptReceiverMutation();
        require(token.transferFrom(msg.sender, address(this), amount), "exact pull failed");
        totalPulled += amount;
    }

    function _attemptReceiverMutation() internal {
        bytes memory returndata;
        (mutationSuccess, returndata) = address(treasury)
            .call(
                abi.encodeCall(
                    Treasury.setProfitReceiver,
                    (mutationCandidate, uint256(1), Treasury.RevenueDistributionMode.DirectTransfer)
                )
            );
        mutationSelector = _selector(returndata);
    }

    function _attemptAllFundPaths() internal {
        bytes4[5] memory selectors;
        selectors[0] = _attempt(abi.encodeCall(Treasury.mintUSD8, (uint256(1))));
        selectors[1] = _attempt(abi.encodeCall(Treasury.redeemUSD8, (uint256(1), uint256(0))));
        selectors[2] = _attempt(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(this)), uint256(1))));
        selectors[3] = _attempt(abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(this)), uint256(1))));
        selectors[4] = _attempt(abi.encodeCall(Treasury.harvestAndDistribute, ()));
        if (propagateCallbackFailure) {
            revert CallbackGuards(selectors[0], selectors[1], selectors[2], selectors[3], selectors[4]);
        }
    }

    function _attempt(bytes memory data) internal returns (bytes4 result) {
        uint256 index = callbackAttempts;
        callbackAttempts = index + 1;
        (bool success, bytes memory returndata) = address(treasury).call(data);
        if (success) callbackSuccesses++;
        result = _selector(returndata);
        callbackSelector[index] = result;
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function underlying() external view returns (address) {
        return address(reserve);
    }

    function deploy(uint256) external {}

    function withdraw(uint256 amount) external {
        require(reserve.transfer(msg.sender, amount), "reserve transfer failed");
    }

    function totalAssets() external view returns (uint256) {
        return reserve.balanceOf(address(this));
    }
}

/// @notice Bounded harvest-delivery properties over real Registry, USD8, and
///         Treasury implementations behind ERC1967 proxies.
/// @dev Every distribution has N_RECEIVER <= 3. Reserve inputs are uint64, so
///      scaling by 1e12 and adding harvested supply remain within uint256. USD8
///      is the real production token: hook delivery uses its actual approve and
///      transferFrom allowance consumption behavior.
contract TreasuryHarvestHooksKontrolTest is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant N_RECEIVER = 3;
    address internal constant DIRECT_A = address(0xA11CE);
    address internal constant DIRECT_B = address(0xB0B);

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryHarvestHooksUSDC internal usdc;

    function setUp() public {
        usdc = new TreasuryHarvestHooksUSDC();
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

    function _receiver(TreasuryHarvestHookReceiver.Behavior behavior)
        internal
        returns (TreasuryHarvestHookReceiver receiver)
    {
        receiver = new TreasuryHarvestHookReceiver(usd8, usdc);
        receiver.configure(treasury, behavior, false);
    }

    function _seedBackingAndSurplus(uint64 backing, uint64 surplus)
        internal
        returns (uint256 supplyBefore, uint256 expectedHarvest)
    {
        vm.assume(backing > 0);
        usdc.mint(address(this), backing);
        usdc.approve(address(treasury), backing);
        treasury.mintUSD8(backing);
        usdc.mint(address(treasury), surplus);
        supplyBefore = usd8.totalSupply();
        uint256 reserveInUsd8 = (uint256(backing) + surplus) * SCALE;
        uint256 retain = supplyBefore + supplyBefore / treasury.HARVEST_BUFFER_DIVISOR();
        vm.assume(reserveInUsd8 > retain);
        expectedHarvest = reserveInUsd8 - retain;
    }

    function _seedRevenuePool(uint256 amount) internal {
        uint256 usdcAmount = (amount + SCALE - 1) / SCALE;
        usdc.mint(address(this), usdcAmount);
        usdc.approve(address(treasury), usdcAmount);
        treasury.mintUSD8(usdcAmount);
        usd8.transfer(address(treasury), amount);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _assertFiveTransientGuards(TreasuryHarvestHookReceiver receiver) internal view {
        bytes4 expected = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
        assert(receiver.callbackAttempts() == 5);
        assert(receiver.callbackSuccesses() == 0);
        for (uint256 i = 0; i < 5; i++) {
            assert(receiver.callbackSelector(i) == expected);
        }
    }

    function test_exactHookPullClearsAllowanceAndReturnsExactDeltas(uint64 backing, uint64 surplus) public {
        (uint256 supplyBefore, uint256 expectedHarvest) = _seedBackingAndSurplus(backing, surplus);
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.EXACT_PULL);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == expectedHarvest && distributed == expectedHarvest);
        assert(receiver.receiveCalls() == 1 && receiver.totalPulled() == distributed);
        assert(usd8.balanceOf(address(receiver)) == distributed);
        assert(usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.totalSupply() == supplyBefore + harvested);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    function test_noPullMismatchRevertsAndRollsBackHarvest(uint64 backing, uint64 surplus) public {
        (uint256 supplyBefore, uint256 share) = _seedBackingAndSurplus(backing, surplus);
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.NONE);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success);
        assert(
            keccak256(returndata)
                == keccak256(abi.encodeWithSelector(Treasury.RevenueDeliveryMismatch.selector, share, 0))
        );
        assert(usd8.totalSupply() == supplyBefore && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.balanceOf(address(receiver)) == 0 && receiver.receiveCalls() == 0);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    function test_partialPullMismatchRevertsAndRollsBackTransfer(uint64 backing, uint64 surplus) public {
        (uint256 supplyBefore, uint256 share) = _seedBackingAndSurplus(backing, surplus);
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.PARTIAL);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success);
        assert(
            keccak256(returndata)
                == keccak256(abi.encodeWithSelector(Treasury.RevenueDeliveryMismatch.selector, share, share - 1))
        );
        assert(usd8.totalSupply() == supplyBefore && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.balanceOf(address(receiver)) == 0 && receiver.receiveCalls() == 0 && receiver.totalPulled() == 0);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    function test_receiverRevertRollsBackHarvestMintAndApproval(uint64 backing, uint64 surplus) public {
        (uint256 supplyBefore,) = _seedBackingAndSurplus(backing, surplus);
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.REVERT);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success && _selector(returndata) == TreasuryHarvestHookReceiver.HookRejected.selector);
        assert(usd8.totalSupply() == supplyBefore && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.balanceOf(address(receiver)) == 0 && receiver.receiveCalls() == 0);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    function test_laterReceiverRevertRollsBackEarlierDirectHookAndHarvest(uint64 backing, uint64 surplus) public {
        (uint256 supplyBefore,) = _seedBackingAndSurplus(backing, surplus);
        TreasuryHarvestHookReceiver exact = _receiver(TreasuryHarvestHookReceiver.Behavior.EXACT_PULL);
        TreasuryHarvestHookReceiver reverting = _receiver(TreasuryHarvestHookReceiver.Behavior.REVERT);
        treasury.setProfitReceiver(DIRECT_A, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(address(exact), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        treasury.setProfitReceiver(address(reverting), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        assert(treasury.profitReceiversLength() == N_RECEIVER);

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success && _selector(returndata) == TreasuryHarvestHookReceiver.HookRejected.selector);
        assert(usd8.totalSupply() == supplyBefore && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.balanceOf(DIRECT_A) == 0 && usd8.balanceOf(address(exact)) == 0);
        assert(exact.receiveCalls() == 0 && exact.totalPulled() == 0 && reverting.receiveCalls() == 0);
        assert(usd8.allowance(address(treasury), address(exact)) == 0);
        assert(usd8.allowance(address(treasury), address(reverting)) == 0);
    }

    function test_mixedDirectAndHooksConserveExactDistributionAndAssignDustToLast() public {
        (uint256 supplyBefore, uint256 expectedHarvest) = _seedBackingAndSurplus(100e6, 20e6);
        TreasuryHarvestHookReceiver firstHook = _receiver(TreasuryHarvestHookReceiver.Behavior.EXACT_PULL);
        TreasuryHarvestHookReceiver lastHook = _receiver(TreasuryHarvestHookReceiver.Behavior.EXACT_PULL);
        treasury.setProfitReceiver(DIRECT_A, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(address(firstHook), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        treasury.setProfitReceiver(address(lastHook), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();
        uint256 baseShare = distributed / 3;

        assert(harvested == expectedHarvest && distributed == expectedHarvest);
        assert(usd8.balanceOf(DIRECT_A) == baseShare);
        assert(usd8.balanceOf(address(firstHook)) == baseShare);
        assert(usd8.balanceOf(address(lastHook)) == distributed - baseShare * 2);
        assert(usd8.balanceOf(address(lastHook)) == baseShare + 1);
        assert(
            usd8.balanceOf(DIRECT_A) + usd8.balanceOf(address(firstHook)) + usd8.balanceOf(address(lastHook))
                == distributed
        );
        assert(usd8.balanceOf(address(treasury)) == 0 && usd8.totalSupply() == supplyBefore + harvested);
        assert(usd8.allowance(address(treasury), address(firstHook)) == 0);
        assert(usd8.allowance(address(treasury), address(lastHook)) == 0);
    }

    function test_caughtCallbackHitsAllFiveTransientGuardsAndOuterDeliverySucceeds(uint64 backing, uint64 surplus)
        public
    {
        (uint256 supplyBefore, uint256 expectedHarvest) = _seedBackingAndSurplus(backing, surplus);
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.CALLBACK_GUARDED);
        registry.setAdmin(address(receiver), true);
        treasury.addStrategy(receiver, type(uint256).max);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        _assertFiveTransientGuards(receiver);
        assert(harvested == expectedHarvest && distributed == expectedHarvest);
        assert(receiver.receiveCalls() == 1 && receiver.totalPulled() == distributed);
        assert(usd8.balanceOf(address(receiver)) == distributed && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.totalSupply() == supplyBefore + harvested);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    function test_propagatedCallbackGuardsAtomicallyRevertOuterDelivery(uint64 backing, uint64 surplus) public {
        (uint256 supplyBefore,) = _seedBackingAndSurplus(backing, surplus);
        TreasuryHarvestHookReceiver receiver = new TreasuryHarvestHookReceiver(usd8, usdc);
        receiver.configure(treasury, TreasuryHarvestHookReceiver.Behavior.CALLBACK_GUARDED, true);
        registry.setAdmin(address(receiver), true);
        treasury.addStrategy(receiver, type(uint256).max);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        bytes4 guard = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success);
        assert(
            keccak256(returndata)
                == keccak256(
                    abi.encodeWithSelector(
                        TreasuryHarvestHookReceiver.CallbackGuards.selector, guard, guard, guard, guard, guard
                    )
                )
        );
        assert(usd8.totalSupply() == supplyBefore && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.balanceOf(address(receiver)) == 0 && receiver.receiveCalls() == 0);
        assert(receiver.callbackAttempts() == 0 && receiver.callbackSuccesses() == 0);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    function test_nonAdminHookCannotMutateReceiverConfigWhileOuterExactPullSucceeds() public {
        (uint256 supplyBefore, uint256 expectedHarvest) = _seedBackingAndSurplus(100e6, 2e6);
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.CONFIG_MUTATION);
        receiver.setMutationCandidate(DIRECT_A);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(!receiver.mutationSuccess());
        assert(receiver.mutationSelector() == Registry.UnauthorizedAdmin.selector);
        assert(treasury.profitReceiversLength() == 1);
        (address configured, uint256 weight, Treasury.RevenueDistributionMode mode) = treasury.profitReceivers(0);
        assert(configured == address(receiver) && weight == 1);
        assert(mode == Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        assert(harvested == expectedHarvest && distributed == expectedHarvest);
        assert(receiver.totalPulled() == distributed);
        assert(usd8.balanceOf(address(receiver)) == distributed);
        assert(usd8.totalSupply() == supplyBefore + harvested);
        assert(usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    /// @dev Explicit trusted-admin boundary: receiver curation is intentionally not
    ///      reentrancy-guarded. An authorized hook can append configuration during
    ///      pass 2, but the snapshotted loop length means it is first eligible next call.
    function test_trustedAdminHookAppendPersistsButDoesNotJoinCurrentSnapshottedDistribution() public {
        (, uint256 expectedHarvest) = _seedBackingAndSurplus(100e6, 2e6);
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.CONFIG_MUTATION);
        receiver.setMutationCandidate(DIRECT_B);
        registry.setAdmin(address(receiver), true);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(receiver.mutationSuccess());
        assert(receiver.mutationSelector() == bytes4(0));
        assert(harvested == expectedHarvest && distributed == expectedHarvest);
        assert(receiver.totalPulled() == distributed);
        assert(usd8.balanceOf(address(receiver)) == distributed);
        assert(usd8.balanceOf(DIRECT_B) == 0);
        assert(treasury.profitReceiversLength() == 2);
        (address appended, uint256 weight, Treasury.RevenueDistributionMode mode) = treasury.profitReceivers(1);
        assert(appended == DIRECT_B && weight == 1);
        assert(mode == Treasury.RevenueDistributionMode.DirectTransfer);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }

    function test_zeroWeightHookIsNotCalledAndPositiveDirectGetsEverything(uint64 pool) public {
        vm.assume(pool > 0);
        _seedRevenuePool(pool);
        uint256 supplyBefore = usd8.totalSupply();
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.REVERT);
        treasury.setProfitReceiver(address(receiver), 0, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        treasury.setProfitReceiver(DIRECT_A, 1, Treasury.RevenueDistributionMode.DirectTransfer);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == 0 && distributed == pool);
        assert(receiver.receiveCalls() == 0 && usd8.balanceOf(address(receiver)) == 0);
        assert(usd8.balanceOf(DIRECT_A) == pool && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }

    function test_roundedZeroHookShareIsNotCalledAndLastReceiverGetsOneWei() public {
        _seedRevenuePool(1);
        uint256 supplyBefore = usd8.totalSupply();
        TreasuryHarvestHookReceiver receiver = _receiver(TreasuryHarvestHookReceiver.Behavior.REVERT);
        treasury.setProfitReceiver(address(receiver), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        treasury.setProfitReceiver(DIRECT_B, 2, Treasury.RevenueDistributionMode.DirectTransfer);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == 0 && distributed == 1);
        assert(Math.mulDiv(distributed, 1, 3) == 0);
        assert(receiver.receiveCalls() == 0 && usd8.balanceOf(address(receiver)) == 0);
        assert(usd8.balanceOf(DIRECT_B) == 1 && usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.allowance(address(treasury), address(receiver)) == 0);
    }
}
