// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @dev Standard six-decimal reserve. Unrestricted minting is test-only setup.
contract TreasuryHarvestDirectUSDC is ERC20 {
    constructor() ERC20("Kontrol USDC", "kUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Honest balance-valued strategy used only to prove harvest is valuation-only.
contract TreasuryHarvestDirectStrategy is IStrategy {
    IERC20 public immutable asset;
    uint256 public deployCalls;
    uint256 public withdrawCalls;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function underlying() external view returns (address) {
        return address(asset);
    }

    function deploy(uint256) external {
        deployCalls++;
    }

    function withdraw(uint256 amount) external {
        withdrawCalls++;
        asset.transfer(msg.sender, amount);
    }

    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

/// @notice Arithmetic and direct-transfer harvest properties over production
///         Registry, USD8, and Treasury implementations behind real proxies.
/// @dev Reserve-side successful-path inputs are uint32/uint64 and receiver count
///      and strategy count are bounded by N <= 3. Thus reserve sums, scaling,
///      retained-buffer arithmetic, weight sums, and explicit balance deltas fit
///      uint256 except in the three properties dedicated to checked overflow.
///      All receiver modes are DirectTransfer to local nonzero addresses.
contract TreasuryHarvestDirectKontrolTest is Test {
    uint256 internal constant SCALE = 1e12;
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    address internal constant RECEIVER_0 = address(0x1001);
    address internal constant RECEIVER_1 = address(0x1002);
    address internal constant RECEIVER_2 = address(0x1003);

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryHarvestDirectUSDC internal usdc;

    function setUp() public {
        usdc = new TreasuryHarvestDirectUSDC();
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

    function _mintSupply(uint256 reserveAmount) internal {
        usdc.mint(address(this), reserveAmount);
        usdc.approve(address(treasury), reserveAmount);
        treasury.mintUSD8(reserveAmount);
    }

    function _seedPool(uint256 amount) internal {
        usd8.transfer(address(treasury), amount);
    }

    function _setDirect(address receiver, uint256 weight) internal {
        treasury.setProfitReceiver(receiver, weight, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function test_emptyReserveSupplyAndPoolReturnsZero() public {
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 supplyBefore = usd8.totalSupply();

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == 0);
        assert(distributed == 0);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }

    function test_zeroSupplyPositiveReserveHarvestMintsAndDistributesEntireReserve(uint64 reserveAmount) public {
        vm.assume(reserveAmount > 0);
        usdc.mint(address(treasury), reserveAmount);
        _setDirect(RECEIVER_0, 1);
        uint256 expected = uint256(reserveAmount) * SCALE;

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == expected);
        assert(distributed == expected);
        assert(usd8.totalSupply() == expected);
        assert(usd8.balanceOf(RECEIVER_0) == expected);
        assert(usd8.balanceOf(address(treasury)) == 0);
        assert(treasury.getReserveBalance() == reserveAmount);
    }

    function test_belowRetainedBufferMintsNothingButDistributesPreexistingPool(
        uint32 surplusReserve,
        uint32 slack,
        uint128 pool
    ) public {
        vm.assume(surplusReserve > 0 && slack > 0);
        uint256 backing = uint256(surplusReserve) * 1000 + slack;
        _mintSupply(backing);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(pool > 0 && pool <= supplyBefore);
        _seedPool(pool);
        usdc.mint(address(treasury), surplusReserve);
        _setDirect(RECEIVER_0, 1);
        uint256 reserveBefore = treasury.getReserveBalance();
        assert(reserveBefore * SCALE < supplyBefore + supplyBefore / 1000);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == 0);
        assert(distributed == pool);
        assert(usd8.balanceOf(RECEIVER_0) == pool);
        assert(usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.totalSupply() == supplyBefore);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    function test_atRetainedBufferMintsNothingButDistributesPreexistingPool(uint32 bufferReserve, uint128 pool) public {
        vm.assume(bufferReserve > 0);
        uint256 backing = uint256(bufferReserve) * 1000;
        _mintSupply(backing);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(pool > 0 && pool <= supplyBefore);
        _seedPool(pool);
        usdc.mint(address(treasury), bufferReserve);
        _setDirect(RECEIVER_0, 1);
        uint256 reserveBefore = treasury.getReserveBalance();
        assert(reserveBefore * SCALE == supplyBefore + supplyBefore / 1000);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == 0);
        assert(distributed == pool);
        assert(usd8.balanceOf(RECEIVER_0) == pool);
        assert(usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.totalSupply() == supplyBefore);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    function test_aboveBufferExactHarvestFormulaFinalSupplyReturnsAndDeltas(
        uint32 backing,
        uint32 surplusReserve,
        uint128 pool
    ) public {
        vm.assume(backing > 0 && uint256(surplusReserve) * 1000 > backing);
        _mintSupply(backing);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(pool <= supplyBefore);
        _seedPool(pool);
        usdc.mint(address(treasury), surplusReserve);
        _setDirect(RECEIVER_0, 1);
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 recipientBefore = usd8.balanceOf(RECEIVER_0);
        uint256 expectedHarvest = reserveBefore * SCALE - supplyBefore - supplyBefore / 1000;
        uint256 poolBefore = usd8.balanceOf(address(treasury));

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == expectedHarvest);
        assert(distributed == poolBefore + expectedHarvest);
        assert(usd8.totalSupply() - supplyBefore == harvested);
        assert(usd8.balanceOf(RECEIVER_0) - recipientBefore == distributed);
        assert(usd8.totalSupply() == supplyBefore + expectedHarvest);
        assert(reserveBefore * SCALE == usd8.totalSupply() + supplyBefore / 1000);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }

    function test_harvestLeavesIdleReserveAndUpToThreeStrategiesUnchanged(
        uint8 count,
        uint32 backing,
        uint32 idleYield,
        uint32 strategyYield0,
        uint32 strategyYield1,
        uint32 strategyYield2
    ) public {
        vm.assume(count <= 3 && backing > 0 && idleYield > 0);
        _mintSupply(backing);
        uint32[3] memory yields = [strategyYield0, strategyYield1, strategyYield2];
        TreasuryHarvestDirectStrategy[3] memory strategies_;
        uint256[3] memory balancesBefore;
        for (uint256 i = 0; i < count; i++) {
            strategies_[i] = new TreasuryHarvestDirectStrategy(usdc);
            treasury.addStrategy(strategies_[i], type(uint256).max);
            usdc.mint(address(strategies_[i]), yields[i]);
            balancesBefore[i] = usdc.balanceOf(address(strategies_[i]));
        }
        usdc.mint(address(treasury), uint256(idleYield) + backing / 1000 + 1);
        _setDirect(RECEIVER_0, 1);
        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 reserveBefore = treasury.getReserveBalance();

        (uint256 harvested,) = treasury.harvestAndDistribute();

        assert(harvested > 0);
        assert(usdc.balanceOf(address(treasury)) == idleBefore);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(treasury.strategiesLength() == count);
        for (uint256 i = 0; i < count; i++) {
            assert(usdc.balanceOf(address(strategies_[i])) == balancesBefore[i]);
            assert(strategies_[i].deployCalls() == 0);
            assert(strategies_[i].withdrawCalls() == 0);
        }
    }

    function test_noPositiveWeightRevertsHarvestAndPoolAtomically(uint32 backing, uint32 surplusReserve, uint128 pool)
        public
    {
        vm.assume(backing > 0 && uint256(surplusReserve) * 1000 > backing);
        _mintSupply(backing);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(pool > 0 && pool <= supplyBefore);
        _seedPool(pool);
        usdc.mint(address(treasury), surplusReserve);
        _setDirect(RECEIVER_0, 0);
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 treasuryPoolBefore = usd8.balanceOf(address(treasury));

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success);
        assert(_selector(returndata) == Treasury.NoEligibleProfitReceivers.selector);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(treasury)) == treasuryPoolBefore);
        assert(usd8.balanceOf(RECEIVER_0) == 0);
    }

    function test_allDirectWeightedFloorSplitAndResidualDustToLastPositive(
        uint32 backing,
        uint128 pool,
        uint64 weight0,
        uint64 weight1,
        uint64 weight2
    ) public {
        vm.assume(backing > 0);
        _mintSupply(backing);
        vm.assume(pool > 0 && pool <= usd8.totalSupply());
        vm.assume(weight0 > 0 && weight1 > 0 && weight2 > 0);
        _seedPool(pool);
        _setDirect(RECEIVER_0, weight0);
        _setDirect(RECEIVER_1, weight1);
        _setDirect(RECEIVER_2, weight2);
        uint256 totalWeight = uint256(weight0) + weight1 + weight2;
        uint256 expected0 = Math.mulDiv(pool, weight0, totalWeight);
        uint256 expected1 = Math.mulDiv(pool, weight1, totalWeight);
        uint256 expected2 = uint256(pool) - expected0 - expected1;

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == 0 && distributed == pool);
        assert(usd8.balanceOf(RECEIVER_0) == expected0);
        assert(usd8.balanceOf(RECEIVER_1) == expected1);
        assert(usd8.balanceOf(RECEIVER_2) == expected2);
        assert(expected0 + expected1 + expected2 == distributed);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }

    function test_zeroWeightAndRoundedZeroSharesAreSkipped() public {
        _mintSupply(1);
        _seedPool(1);
        _setDirect(RECEIVER_0, 0);
        _setDirect(RECEIVER_1, 1);
        _setDirect(RECEIVER_2, 2);

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == 0 && distributed == 1);
        assert(usd8.balanceOf(RECEIVER_0) == 0);
        assert(usd8.balanceOf(RECEIVER_1) == 0);
        assert(usd8.balanceOf(RECEIVER_2) == 1);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }

    function test_preexistingPoolPlusNewHarvestIsExactlyConserved(uint32 backing, uint32 surplusReserve, uint128 pool)
        public
    {
        vm.assume(backing > 0 && uint256(surplusReserve) * 1000 > backing);
        _mintSupply(backing);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(pool > 0 && pool <= supplyBefore);
        _seedPool(pool);
        usdc.mint(address(treasury), surplusReserve);
        _setDirect(RECEIVER_0, 2);
        _setDirect(RECEIVER_1, 3);
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 expectedHarvest = reserveBefore * SCALE - supplyBefore - supplyBefore / 1000;

        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(harvested == expectedHarvest);
        assert(distributed == uint256(pool) + harvested);
        assert(usd8.balanceOf(RECEIVER_0) + usd8.balanceOf(RECEIVER_1) == distributed);
        assert(usd8.balanceOf(address(treasury)) == 0);
        assert(usd8.totalSupply() == supplyBefore + harvested);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    function test_totalWeightOverflowRevertsEntireHarvestAtomically(uint32 backing, uint32 surplusReserve, uint128 pool)
        public
    {
        vm.assume(backing > 0 && uint256(surplusReserve) * 1000 > backing);
        _mintSupply(backing);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(pool > 0 && pool <= supplyBefore);
        _seedPool(pool);
        usdc.mint(address(treasury), surplusReserve);
        _setDirect(RECEIVER_0, type(uint256).max);
        _setDirect(RECEIVER_1, 1);
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 treasuryPoolBefore = usd8.balanceOf(address(treasury));

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success && _selector(returndata) == PANIC_SELECTOR);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(treasury)) == treasuryPoolBefore);
        assert(usd8.balanceOf(RECEIVER_0) == 0 && usd8.balanceOf(RECEIVER_1) == 0);
    }

    function test_reserveScalingOverflowRevertsAtomically() public {
        uint256 oversizedReserve = type(uint256).max / SCALE + 1;
        usdc.mint(address(treasury), oversizedReserve);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success && _selector(returndata) == PANIC_SELECTOR);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }

    function test_retainedSupplyOverflowRevertsAtomically() public {
        uint256 oversizedSupply = type(uint256).max - 1;
        registry.setTreasury(address(this));
        usd8.mint(address(this), oversizedSupply);
        registry.setTreasury(address(treasury));
        uint256 holderBefore = usd8.balanceOf(address(this));

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));

        assert(!success && _selector(returndata) == PANIC_SELECTOR);
        assert(treasury.getReserveBalance() == 0);
        assert(usd8.totalSupply() == oversizedSupply);
        assert(usd8.balanceOf(address(this)) == holderBefore);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }
}
