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
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

contract TreasuryStrategySetToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Honest push-deposit/exact-withdraw strategy. A strategy constructed with
///      a different asset is deliberately misconfigured relative to Treasury,
///      but remains honest relative to that asset.
contract TreasuryStrategySetMock is IStrategy {
    IERC20 public immutable asset;
    uint256 public deployCalls;
    uint256 public withdrawCalls;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function underlying() external view returns (address) {
        return address(asset);
    }

    function deploy(uint256 amount) external {
        require(asset.balanceOf(address(this)) >= amount, "assets not pushed");
        deployCalls++;
    }

    function withdraw(uint256 amount) external {
        withdrawCalls++;
        require(asset.transfer(msg.sender, amount), "transfer failed");
    }

    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

/// @notice Bounded strategy-set properties over production Registry, USD8, and
///         Treasury implementations behind real ERC1967 proxies.
/// @dev The production list is intentionally uncapped. These properties prove
///      list mechanics only for N <= 3, matching a small governance-curated set;
///      they do not establish a production gas bound. The timelock is trusted to
///      validate strategy code, reserve denomination, liquidity, and accounting.
contract TreasuryStrategySetKontrolTest is Test {
    uint256 internal constant MAX_PROVED_STRATEGIES = 3;

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryStrategySetToken internal usdc;

    function setUp() public {
        usdc = new TreasuryStrategySetToken("Kontrol USDC", "kUSDC");
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

    function _newStrategy() internal returns (TreasuryStrategySetMock) {
        return new TreasuryStrategySetMock(usdc);
    }

    function _add(IStrategy strategy, uint256 index) internal {
        treasury.addStrategy(strategy, index);
        assert(treasury.strategiesLength() <= MAX_PROVED_STRATEGIES);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _assertOrder(address first, address second, address third, uint256 length) internal view {
        assert(treasury.strategiesLength() == length);
        if (length > 0) assert(address(treasury.strategies(0)) == first);
        if (length > 1) assert(address(treasury.strategies(1)) == second);
        if (length > 2) assert(address(treasury.strategies(2)) == third);
    }

    function test_zeroStrategyIsRejectedAtomically() public {
        uint256 reserveBefore = treasury.getReserveBalance();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.addStrategy, (IStrategy(address(0)), uint256(0))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.ZeroAddress.selector);
        assert(treasury.strategiesLength() == 0);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    function test_duplicateMembershipIsImpossibleAndFirstPositionIsAtomic(uint256 duplicateIndex) public {
        TreasuryStrategySetMock strategy = _newStrategy();
        _add(strategy, 0);
        uint256 reserveBefore = treasury.getReserveBalance();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.addStrategy, (IStrategy(address(strategy)), duplicateIndex)));

        assert(!success);
        assert(_selector(returndata) == Treasury.StrategyAlreadyApproved.selector);
        _assertOrder(address(strategy), address(0), address(0), 1);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    function test_insertionAtFirstPreservesPriorRelativeOrder() public {
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock b = _newStrategy();
        TreasuryStrategySetMock c = _newStrategy();
        _add(a, 0);
        _add(b, 1);

        _add(c, 0);

        _assertOrder(address(c), address(a), address(b), 3);
    }

    function test_insertionAtMiddlePreservesPriorRelativeOrder() public {
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock b = _newStrategy();
        TreasuryStrategySetMock c = _newStrategy();
        _add(a, 0);
        _add(b, 1);

        _add(c, 1);

        _assertOrder(address(a), address(c), address(b), 3);
    }

    function test_insertionAtLastOrClampedIndexAppendsAndPreservesOrder(uint64 indexSeed) public {
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock b = _newStrategy();
        TreasuryStrategySetMock c = _newStrategy();
        _add(a, 0);
        _add(b, 1);
        uint256 index = indexSeed == 0 ? 2 : uint256(indexSeed) + 2;

        _add(c, index);

        _assertOrder(address(a), address(b), address(c), 3);
    }

    function test_removalAtFirstMiddleOrLastPreservesRemainingRelativeOrder(uint8 removedIndex) public {
        vm.assume(removedIndex < 3);
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock b = _newStrategy();
        TreasuryStrategySetMock c = _newStrategy();
        _add(a, 0);
        _add(b, 1);
        _add(c, 2);

        IStrategy removed = removedIndex == 0
            ? IStrategy(address(a))
            : removedIndex == 1 ? IStrategy(address(b)) : IStrategy(address(c));
        treasury.removeStrategy(removed);

        if (removedIndex == 0) _assertOrder(address(b), address(c), address(0), 2);
        if (removedIndex == 1) _assertOrder(address(a), address(c), address(0), 2);
        if (removedIndex == 2) _assertOrder(address(a), address(b), address(0), 2);
    }

    function test_missingRemovalRevertsWithoutChangingListOrReserve(
        uint64 idle,
        uint64 firstAssets,
        uint64 secondAssets
    ) public {
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock b = _newStrategy();
        TreasuryStrategySetMock missing = _newStrategy();
        _add(a, 0);
        _add(b, 1);
        usdc.mint(address(treasury), idle);
        usdc.mint(address(a), firstAssets);
        usdc.mint(address(b), secondAssets);
        uint256 reserveBefore = treasury.getReserveBalance();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.removeStrategy, (IStrategy(address(missing)))));

        assert(!success);
        assert(_selector(returndata) == Treasury.StrategyNotApproved.selector);
        _assertOrder(address(a), address(b), address(0), 2);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usdc.balanceOf(address(treasury)) == idle);
        assert(usdc.balanceOf(address(a)) == firstAssets);
        assert(usdc.balanceOf(address(b)) == secondAssets);
    }

    function test_fundedForceRemovalDropsReportedReserveAndPreservesRemainingOrder(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock funded = _newStrategy();
        TreasuryStrategySetMock c = _newStrategy();
        _add(a, 0);
        _add(funded, 1);
        _add(c, 2);
        usdc.mint(address(treasury), amount);
        treasury.depositToStrategy(funded, amount);
        uint256 reserveBefore = treasury.getReserveBalance();

        treasury.removeStrategy(funded);

        _assertOrder(address(a), address(c), address(0), 2);
        assert(usdc.balanceOf(address(funded)) == amount);
        assert(treasury.getReserveBalance() + amount == reserveBefore);
    }

    function test_drainThenRemoveIsReserveNeutralAndPreservesRemainingOrder(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock funded = _newStrategy();
        TreasuryStrategySetMock c = _newStrategy();
        _add(a, 0);
        _add(funded, 1);
        _add(c, 2);
        usdc.mint(address(treasury), amount);
        treasury.depositToStrategy(funded, amount);
        uint256 reserveBefore = treasury.getReserveBalance();

        treasury.withdrawFromStrategy(funded, amount);
        treasury.removeStrategy(funded);

        _assertOrder(address(a), address(c), address(0), 2);
        assert(usdc.balanceOf(address(funded)) == 0);
        assert(usdc.balanceOf(address(treasury)) == amount);
        assert(treasury.getReserveBalance() == reserveBefore);
    }

    /// @dev Explicit trusted-governance boundary: addStrategy currently does not
    ///      compare underlying() with USDC. A wrong-underlying strategy is accepted,
    ///      and its foreign-token balance is then counted as USDC-denominated reserve.
    function test_wrongUnderlyingAcceptanceIsTrustedGovernanceBoundary(uint64 foreignAssets) public {
        TreasuryStrategySetToken foreign = new TreasuryStrategySetToken("Wrong Asset", "WRONG");
        TreasuryStrategySetMock misconfigured = new TreasuryStrategySetMock(foreign);
        foreign.mint(address(misconfigured), foreignAssets);

        _add(misconfigured, 0);

        assert(address(misconfigured.underlying()) == address(foreign));
        _assertOrder(address(misconfigured), address(0), address(0), 1);
        assert(usdc.balanceOf(address(misconfigured)) == 0);
        assert(treasury.getReserveBalance() == foreignAssets);
    }

    function test_membershipImmediatelyEnablesFundFlowsAndRemovalImmediatelyDisablesThem(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryStrategySetMock strategy = _newStrategy();
        _add(strategy, 0);
        usdc.mint(address(treasury), amount);

        treasury.depositToStrategy(strategy, amount);
        treasury.withdrawFromStrategy(strategy, amount);
        assert(strategy.deployCalls() == 1);
        assert(strategy.withdrawCalls() == 1);

        treasury.removeStrategy(strategy);
        // Keep both rejected operations otherwise executable, so approval checks
        // rather than insufficient balances are what disable them.
        usdc.mint(address(strategy), amount);
        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 strategyBefore = usdc.balanceOf(address(strategy));
        uint256 deployCallsBefore = strategy.deployCalls();
        uint256 withdrawCallsBefore = strategy.withdrawCalls();

        (bool depositSuccess, bytes memory depositData) = address(treasury)
            .call(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(strategy)), uint256(amount))));
        (bool withdrawSuccess, bytes memory withdrawData) = address(treasury)
            .call(abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(strategy)), uint256(amount))));

        assert(!depositSuccess && !withdrawSuccess);
        assert(_selector(depositData) == Treasury.StrategyNotApproved.selector);
        assert(_selector(withdrawData) == Treasury.StrategyNotApproved.selector);
        assert(treasury.strategiesLength() == 0);
        assert(usdc.balanceOf(address(treasury)) == idleBefore);
        assert(usdc.balanceOf(address(strategy)) == strategyBefore);
        assert(strategy.deployCalls() == deployCallsBefore);
        assert(strategy.withdrawCalls() == withdrawCallsBefore);
    }

    function test_gettersReturnExactPointersOrderLengthAndReserve(uint64 idle, uint64 firstAssets, uint64 secondAssets)
        public
    {
        vm.assume(uint256(idle) + firstAssets + secondAssets <= type(uint64).max);
        TreasuryStrategySetMock a = _newStrategy();
        TreasuryStrategySetMock b = _newStrategy();
        TreasuryStrategySetMock c = _newStrategy();
        _add(a, 0);
        _add(c, 1);
        _add(b, 1);
        usdc.mint(address(treasury), idle);
        usdc.mint(address(a), firstAssets);
        usdc.mint(address(b), secondAssets);

        assert(address(treasury.registry()) == address(registry));
        assert(address(treasury.USDC()) == address(usdc));
        assert(address(treasury.usd8()) == address(usd8));
        _assertOrder(address(a), address(b), address(c), 3);
        assert(treasury.getReserveBalance() == uint256(idle) + firstAssets + secondAssets);
    }

    function test_strategyGeneratedGetterOutOfBoundsRevertsWithEmptyData() public {
        TreasuryStrategySetMock strategy = _newStrategy();
        _add(strategy, 0);

        (bool success, bytes memory returndata) =
            address(treasury).staticcall(abi.encodeWithSignature("strategies(uint256)", uint256(1)));

        assert(!success);
        assert(returndata.length == 0);
        assert(treasury.strategiesLength() == 1);
        assert(address(treasury.strategies(0)) == address(strategy));
    }
}
