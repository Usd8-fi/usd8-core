// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../../src/Registry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RegistryInvariantFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract RegistryInvariantPool {
    IERC20 public immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }
}

contract RegistryInvariantModule {
    uint256 public activeIncidentId;
    Registry public immutable registry;

    constructor(Registry registry_) {
        registry = registry_;
    }

    function setActive(uint256 incidentId) external {
        activeIncidentId = incidentId;
    }

    function isInsuredToken(IERC20) external pure returns (bool) {
        return false;
    }

    function record(address account, uint256 amount) external {
        registry.recordScoreSpent(account, amount);
    }
}

contract RegistryTopologyHandler is Test {
    Registry public immutable registry;
    RegistryInvariantModule public immutable module;

    address public currentTimelock;
    address public immutable admin;
    address public immutable managedAdmin;

    MockERC20[3] internal tokens;
    RegistryInvariantPool[3] internal pools;
    RegistryInvariantFeed[3] internal feeds;
    address[5] internal pauseTargets;

    bool[3] public ghostPoolPresent;
    bool[3] public ghostFeedPresent;
    uint256 public ghostPoolCount;
    uint256[3] public ghostRatePointCount;
    bool[3] public ghostScoredEver;
    bool[5] public ghostPaused;
    bool public ghostManagedAdmin;
    bool public ghostBetaMode = true;
    bool public ghostModuleInstalled = true;
    bool public ghostSwapRoute;

    uint256 public ghostMaxPayoutBps = 5_000;
    uint64 public ghostMaxOracleStaleness = 36 hours;
    bytes32 public ghostPcrHash;
    address public ghostBooster;
    address public ghostUsd8;
    address public ghostTreasury;
    address public ghostSavingsVault;
    address public ghostPriceOracle;
    uint256 public ghostScoreSpent;
    uint256[2] public ghostScoreByAccount;

    uint256 public successfulPoolMutations;
    uint256 public successfulRateAppends;
    uint256 public successfulFreezeTransitions;
    uint256 public successfulModuleTransitions;
    uint256 public successfulScoreRecords;
    uint256 public successfulBetaEnd;
    uint256 public successfulFrozenAtomicityChecks;

    constructor(
        Registry registry_,
        RegistryInvariantModule module_,
        address timelock_,
        address admin_,
        address managedAdmin_,
        MockERC20[3] memory tokens_,
        RegistryInvariantPool[3] memory pools_,
        RegistryInvariantFeed[3] memory feeds_
    ) {
        registry = registry_;
        module = module_;
        currentTimelock = timelock_;
        admin = admin_;
        managedAdmin = managedAdmin_;
        tokens = tokens_;
        pools = pools_;
        feeds = feeds_;
        pauseTargets =
            [address(registry_), address(module_), address(pools_[0]), address(pools_[1]), address(pools_[2])];
    }

    function togglePool(uint256 seed) external {
        if (registry.payoutIncidentActive()) return;
        uint256 i = bound(seed, 0, 2);
        vm.startPrank(currentTimelock);
        if (ghostPoolPresent[i]) {
            registry.removePool(address(pools[i]));
            ghostPoolPresent[i] = false;
            ghostFeedPresent[i] = false;
            ghostPoolCount--;
        } else {
            registry.addPool(address(pools[i]), address(feeds[i]));
            ghostPoolPresent[i] = true;
            ghostFeedPresent[i] = true;
            ghostPoolCount++;
        }
        vm.stopPrank();
        successfulPoolMutations++;
    }

    function appendScoredRate(uint256 tokenSeed, uint128 rate) external {
        if (registry.payoutIncidentActive()) return;
        uint256 i = bound(tokenSeed, 0, 2);
        vm.roll(block.number + 1);
        vm.prank(currentTimelock);
        registry.setScoredToken(tokens[i], rate);
        ghostRatePointCount[i]++;
        ghostScoredEver[i] = true;
        successfulRateAppends++;
    }

    function setIncidentActive(bool active) external {
        if (!ghostModuleInstalled) return;
        module.setActive(active ? 1 : 0);
        successfulFreezeTransitions++;
    }

    function toggleModule() external {
        vm.startPrank(currentTimelock);
        if (ghostModuleInstalled) {
            registry.setDefiInsurance(address(0));
            ghostModuleInstalled = false;
        } else {
            module.setActive(0);
            registry.setDefiInsurance(address(module));
            ghostModuleInstalled = true;
        }
        vm.stopPrank();
        successfulModuleTransitions++;
    }

    function setRiskConfig(uint256 bpsSeed, uint64 stalenessSeed, bytes32 pcrSeed, address boosterSeed) external {
        if (registry.payoutIncidentActive()) return;
        uint256 bps = bound(bpsSeed, 1, 9_999);
        uint64 staleness = uint64(bound(stalenessSeed, 1, type(uint64).max));
        bytes32 pcr = pcrSeed == bytes32(0) ? bytes32(uint256(1)) : pcrSeed;
        vm.startPrank(currentTimelock);
        registry.setMaxCoverPoolPayoutBps(bps);
        registry.setMaxOracleStaleness(staleness);
        registry.setTeePcrHash(pcr);
        registry.setBoosterNFT(boosterSeed);
        vm.stopPrank();
        ghostMaxPayoutBps = bps;
        ghostMaxOracleStaleness = staleness;
        ghostPcrHash = pcr;
        ghostBooster = boosterSeed;
    }

    function setCanonicalTopology(address usd8Seed, address treasurySeed, address savingsSeed, address oracleSeed)
        external
    {
        address u = _nonzero(usd8Seed, 0x1001);
        address t = _nonzero(treasurySeed, 0x1002);
        address s = _nonzero(savingsSeed, 0x1003);
        address o = _nonzero(oracleSeed, 0x1004);
        vm.startPrank(currentTimelock);
        registry.setUsd8(u);
        registry.setTreasury(t);
        registry.setSavingsVault(s);
        registry.setUsd8PriceOracle(o);
        vm.stopPrank();
        ghostUsd8 = u;
        ghostTreasury = t;
        ghostSavingsVault = s;
        ghostPriceOracle = o;
    }

    function setAssetFeed(uint256 seed) external {
        if (registry.payoutIncidentActive()) return;
        uint256 i = bound(seed, 0, 2);
        vm.prank(currentTimelock);
        registry.setAssetUsdFeed(tokens[i], address(feeds[i]));
        ghostFeedPresent[i] = true;
    }

    function togglePause(uint256 seed, bool paused_) external {
        uint256 i = bound(seed, 0, 4);
        vm.prank(admin);
        registry.setPaused(pauseTargets[i], paused_);
        ghostPaused[i] = paused_;
    }

    function toggleManagedAdmin(bool allowed) external {
        vm.prank(currentTimelock);
        registry.setAdmin(managedAdmin, allowed);
        ghostManagedAdmin = allowed;
    }

    function rotateTimelock(address seed) external {
        address next = _nonzero(seed, 0x2001);
        vm.prank(currentTimelock);
        registry.setTimelock(next);
        currentTimelock = next;
    }

    function recordScore(address accountSeed, uint256 amountSeed) external {
        if (!ghostModuleInstalled) return;
        uint256 i = uint160(accountSeed) % 2;
        address account = i == 0 ? address(0xCAFE) : address(0xBEEF);
        uint256 amount = bound(amountSeed, 0, 1e36);
        module.record(account, amount);
        ghostScoreByAccount[i] += amount;
        ghostScoreSpent += amount;
        successfulScoreRecords++;
    }

    function endBetaMode() external {
        if (!ghostBetaMode || registry.payoutIncidentActive()) return;
        vm.prank(currentTimelock);
        registry.endBetaMode();
        ghostBetaMode = false;
        successfulBetaEnd++;
    }

    function setSwapRoute(bool allowed) external {
        vm.prank(currentTimelock);
        registry.setSwapRoute(address(0x5151), address(0x5252), allowed);
        ghostSwapRoute = allowed;
    }

    function frozenMutationsRemainAtomic() external {
        if (!registry.payoutIncidentActive()) return;
        uint256 bpsBefore = registry.maxCoverPoolPayoutBps();
        uint64 stalenessBefore = registry.maxOracleStaleness();
        bytes32 pcrBefore = registry.teePcrHash();
        address boosterBefore = registry.boosterNFT();
        Registry.RatePoint[] memory history = registry.getScoredRateHistory(tokens[0]);
        uint256 historyBefore = history.length;
        bool betaBefore = registry.betaMode();

        vm.startPrank(currentTimelock);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setMaxCoverPoolPayoutBps(bpsBefore == 1 ? 2 : 1);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setMaxOracleStaleness(stalenessBefore == 1 ? 2 : 1);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setTeePcrHash(pcrBefore == bytes32(uint256(1)) ? bytes32(uint256(2)) : bytes32(uint256(1)));
        vm.expectRevert(Registry.Frozen.selector);
        registry.setBoosterNFT(address(0xF002));
        vm.expectRevert(Registry.Frozen.selector);
        registry.setScoredToken(tokens[0], 123);
        if (betaBefore) {
            vm.expectRevert(Registry.Frozen.selector);
            registry.endBetaMode();
        }
        vm.stopPrank();

        assertEq(registry.maxCoverPoolPayoutBps(), bpsBefore, "frozen cap mutation");
        assertEq(registry.maxOracleStaleness(), stalenessBefore, "frozen staleness mutation");
        assertEq(registry.teePcrHash(), pcrBefore, "frozen PCR mutation");
        assertEq(registry.boosterNFT(), boosterBefore, "frozen booster mutation");
        Registry.RatePoint[] memory historyAfter = registry.getScoredRateHistory(tokens[0]);
        assertEq(historyAfter.length, historyBefore, "frozen score mutation");
        assertEq(registry.betaMode(), betaBefore, "frozen beta mutation");
        successfulFrozenAtomicityChecks++;
    }

    function token(uint256 i) external view returns (MockERC20) {
        return tokens[i];
    }

    function pool(uint256 i) external view returns (RegistryInvariantPool) {
        return pools[i];
    }

    function feed(uint256 i) external view returns (RegistryInvariantFeed) {
        return feeds[i];
    }

    function pauseTarget(uint256 i) external view returns (address) {
        return pauseTargets[i];
    }

    function _nonzero(address value, uint160 fallbackValue) internal pure returns (address) {
        return value == address(0) ? address(fallbackValue) : value;
    }
}

contract RegistryTopologyInvariantTest is StdInvariant, Test {
    Registry registry;
    RegistryInvariantModule module;
    RegistryTopologyHandler handler;

    address constant TIMELOCK = address(0xA11CE);
    address constant ADMIN = address(0xAD);
    address constant MANAGED_ADMIN = address(0xB0B);

    function setUp() public {
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (TIMELOCK, ADMIN))))
        );
        module = new RegistryInvariantModule(registry);

        MockERC20[3] memory tokens;
        RegistryInvariantPool[3] memory pools;
        RegistryInvariantFeed[3] memory feeds;
        for (uint256 i = 0; i < 3; i++) {
            tokens[i] = new MockERC20("Asset", "AST", 18);
            pools[i] = new RegistryInvariantPool(tokens[i]);
            feeds[i] = new RegistryInvariantFeed();
        }

        vm.prank(TIMELOCK);
        registry.setDefiInsurance(address(module));

        handler = new RegistryTopologyHandler(registry, module, TIMELOCK, ADMIN, MANAGED_ADMIN, tokens, pools, feeds);

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = RegistryTopologyHandler.togglePool.selector;
        selectors[1] = RegistryTopologyHandler.appendScoredRate.selector;
        selectors[2] = RegistryTopologyHandler.setIncidentActive.selector;
        selectors[3] = RegistryTopologyHandler.toggleModule.selector;
        selectors[4] = RegistryTopologyHandler.setRiskConfig.selector;
        selectors[5] = RegistryTopologyHandler.setCanonicalTopology.selector;
        selectors[6] = RegistryTopologyHandler.setAssetFeed.selector;
        selectors[7] = RegistryTopologyHandler.togglePause.selector;
        selectors[8] = RegistryTopologyHandler.toggleManagedAdmin.selector;
        selectors[9] = RegistryTopologyHandler.rotateTimelock.selector;
        selectors[10] = RegistryTopologyHandler.recordScore.selector;
        selectors[11] = RegistryTopologyHandler.endBetaMode.selector;
        selectors[12] = RegistryTopologyHandler.setSwapRoute.selector;
        selectors[13] = RegistryTopologyHandler.frozenMutationsRemainAtomic.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_ProductiveRegistryBranchesAreReachable() public {
        handler.togglePool(0);
        handler.appendScoredRate(0, 1e18);
        handler.setIncidentActive(true);
        handler.frozenMutationsRemainAtomic();
        handler.toggleModule();
        handler.toggleModule();
        handler.recordScore(address(0xCAFE), 123);
        handler.setIncidentActive(false);
        handler.endBetaMode();

        assertGt(handler.successfulPoolMutations(), 0);
        assertGt(handler.successfulRateAppends(), 0);
        assertGt(handler.successfulFreezeTransitions(), 0);
        assertGt(handler.successfulFrozenAtomicityChecks(), 0);
        assertGt(handler.successfulModuleTransitions(), 0);
        assertGt(handler.successfulScoreRecords(), 0);
        assertGt(handler.successfulBetaEnd(), 0);
    }

    function invariant_poolTopologyIsAlignedAndUnique() public view {
        (IERC20[] memory assets, address[] memory poolAddrs) = registry.coverPools();
        assertEq(assets.length, handler.ghostPoolCount(), "pool count drift");
        assertEq(poolAddrs.length, assets.length, "aligned lengths");
        for (uint256 i = 0; i < assets.length; i++) {
            assertEq(registry.coverPool(assets[i]), poolAddrs[i], "mapping/list mismatch");
            assertTrue(poolAddrs[i] != address(0), "zero pool");
            for (uint256 j = i + 1; j < assets.length; j++) {
                assertTrue(assets[i] != assets[j], "duplicate asset");
            }
        }
    }

    function invariant_poolMembershipMatchesGhost() public view {
        for (uint256 i = 0; i < 3; i++) {
            IERC20 asset = handler.token(i);
            address expected = handler.ghostPoolPresent(i) ? address(handler.pool(i)) : address(0);
            assertEq(registry.coverPool(asset), expected, "pool membership drift");
            address expectedFeed = handler.ghostFeedPresent(i) ? address(handler.feed(i)) : address(0);
            assertEq(registry.assetUsdFeed(asset), expectedFeed, "asset feed cleanup drift");
        }
    }

    function invariant_scoredRateHistoriesAreAppendOnlyAndExactLength() public view {
        uint256 listed;
        for (uint256 i = 0; i < 3; i++) {
            IERC20 token = handler.token(i);
            Registry.RatePoint[] memory points = registry.getScoredRateHistory(token);
            assertEq(points.length, handler.ghostRatePointCount(i), "rate point count drift");
            if (handler.ghostScoredEver(i)) listed++;
            for (uint256 j = 1; j < points.length; j++) {
                assertGt(points[j].fromBlock, points[j - 1].fromBlock, "rate blocks not increasing");
            }
        }
        assertEq(registry.scoredTokensLength(), listed, "scored token list drift");
        IERC20[] memory scored = registry.getScoredTokens();
        for (uint256 i = 0; i < scored.length; i++) {
            for (uint256 j = i + 1; j < scored.length; j++) {
                assertTrue(scored[i] != scored[j], "duplicate scored token");
            }
        }
    }

    function invariant_freezeDelegationMatchesInstalledModule() public view {
        bool expected = handler.ghostModuleInstalled() && module.activeIncidentId() != 0;
        assertEq(registry.payoutIncidentActive(), expected, "freeze delegation drift");
        assertEq(registry.defiInsurance(), handler.ghostModuleInstalled() ? address(module) : address(0));
    }

    function invariant_riskConfigurationMatchesGhostAndBounds() public view {
        assertEq(registry.maxCoverPoolPayoutBps(), handler.ghostMaxPayoutBps());
        assertGt(registry.maxCoverPoolPayoutBps(), 0);
        assertLt(registry.maxCoverPoolPayoutBps(), registry.BPS_DENOMINATOR());
        assertEq(registry.maxOracleStaleness(), handler.ghostMaxOracleStaleness());
        assertGt(registry.maxOracleStaleness(), 0);
        assertEq(registry.teePcrHash(), handler.ghostPcrHash());
        assertEq(registry.boosterNFT(), handler.ghostBooster());
    }

    function invariant_pauseStateMatchesGhost() public view {
        for (uint256 i = 0; i < 5; i++) {
            assertEq(registry.paused(handler.pauseTarget(i)), handler.ghostPaused(i));
        }
    }

    function invariant_rolesMatchGhost() public view {
        assertEq(registry.timelock(), handler.currentTimelock());
        assertEq(registry.isAdmin(ADMIN), true);
        assertEq(registry.isAdmin(MANAGED_ADMIN), handler.ghostManagedAdmin());
    }

    function invariant_canonicalTopologyMatchesGhost() public view {
        assertEq(registry.usd8(), handler.ghostUsd8());
        assertEq(registry.treasury(), handler.ghostTreasury());
        assertEq(registry.savingsVault(), handler.ghostSavingsVault());
        assertEq(registry.usd8PriceOracle(), handler.ghostPriceOracle());
    }

    function invariant_betaModeIsOneWay() public view {
        assertEq(registry.betaMode(), handler.ghostBetaMode());
        if (handler.successfulBetaEnd() != 0) assertFalse(registry.betaMode());
    }

    function invariant_scoreSpentMatchesIndependentTotal() public view {
        uint256 total;
        address[2] memory known = [address(0xCAFE), address(0xBEEF)];
        for (uint256 i = 0; i < known.length; i++) {
            uint256 actual = registry.scoreSpent(known[i]);
            assertEq(actual, handler.ghostScoreByAccount(i), "per-account score drift");
            total += actual;
        }
        assertEq(total, handler.ghostScoreSpent(), "score total drift");
    }

    function invariant_swapRouteMatchesGhost() public view {
        assertEq(registry.approvedSwapRoute(address(0x5151), address(0x5252)), handler.ghostSwapRoute());
    }
}
