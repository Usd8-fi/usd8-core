// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";

contract RegistryModuleToken {}

contract RegistryModuleInsuranceModel {
    uint256 internal _activeIncidentId;
    bool internal _revertActive;

    function setActiveIncidentId(uint256 incidentId) external {
        _activeIncidentId = incidentId;
    }

    function setRevertActive(bool value) external {
        _revertActive = value;
    }

    function activeIncidentId() external view returns (uint256) {
        if (_revertActive) revert();
        return _activeIncidentId;
    }

    function isInsuredToken(IERC20) external pure returns (bool) {
        return false;
    }

    function record(Registry registry, address account, uint256 amount) external {
        registry.recordScoreSpent(account, amount);
    }
}

/// @notice Registry payout-module, score-history, booster, and payout-cap properties.
contract RegistryModuleScoringKontrolTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant ALICE = address(0xA1);

    Registry internal registry;
    RegistryModuleInsuranceModel internal moduleA;
    RegistryModuleInsuranceModel internal moduleB;
    IERC20 internal tokenA;
    IERC20 internal tokenB;

    event DefiInsuranceSet(address indexed oldModule, address indexed newModule);
    event ScoredTokenSet(IERC20 indexed token, uint128 rate, uint64 fromBlock);
    event BoosterConfigSet(address indexed collection, uint64 tokenId, uint16 boostBps);
    event MaxCoverPoolPayoutBpsSet(uint256 oldBps, uint256 newBps);
    event ScoreSpentRecorded(address indexed account, uint256 amount, uint256 newTotal);

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        moduleA = new RegistryModuleInsuranceModel();
        moduleB = new RegistryModuleInsuranceModel();
        tokenA = IERC20(address(new RegistryModuleToken()));
        tokenB = IERC20(address(new RegistryModuleToken()));
        vm.roll(1000);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _callAs(address caller, bytes memory callData) internal returns (bool success, bytes memory returndata) {
        vm.prank(caller);
        return address(registry).call(callData);
    }

    function test_moduleInstallSwapAndClearAreExact() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit DefiInsuranceSet(address(0), address(moduleA));
        registry.setDefiInsurance(address(moduleA));
        assert(registry.defiInsurance() == address(moduleA));
        assert(!registry.payoutIncidentActive());

        registry.setDefiInsurance(address(moduleB));
        assert(registry.defiInsurance() == address(moduleB));
        registry.setDefiInsurance(address(0));
        assert(registry.defiInsurance() == address(0));
        assert(!registry.payoutIncidentActive());
    }

    function test_candidateOrCurrentActiveIncidentBlocksNonzeroModuleInstallAtomically() public {
        registry.setDefiInsurance(address(moduleA));
        moduleB.setActiveIncidentId(7);
        (bool candidate, bytes memory candidateData) =
            address(registry).call(abi.encodeCall(Registry.setDefiInsurance, (address(moduleB))));
        assert(!candidate && _selector(candidateData) == Registry.CandidateIncidentActive.selector);
        assert(registry.defiInsurance() == address(moduleA));

        moduleB.setActiveIncidentId(0);
        moduleA.setActiveIncidentId(8);
        (bool frozen, bytes memory frozenData) =
            address(registry).call(abi.encodeCall(Registry.setDefiInsurance, (address(moduleB))));
        assert(!frozen && _selector(frozenData) == Registry.Frozen.selector);
        assert(registry.defiInsurance() == address(moduleA));
        assert(registry.payoutIncidentActive());
    }

    function test_zeroEmergencyClearWorksWhenCurrentModuleIsActiveOrReverting() public {
        registry.setDefiInsurance(address(moduleA));
        moduleA.setActiveIncidentId(1);
        registry.setDefiInsurance(address(0));
        assert(registry.defiInsurance() == address(0));
        assert(!registry.payoutIncidentActive());

        moduleA.setActiveIncidentId(0);
        registry.setDefiInsurance(address(moduleA));
        moduleA.setRevertActive(true);
        registry.setDefiInsurance(address(0));
        assert(registry.defiInsurance() == address(0));
        assert(!registry.payoutIncidentActive());
    }

    function test_moduleSetterIsTimelockOnlyAndNoCodeCandidateRollsBack() public {
        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setDefiInsurance, (address(moduleA))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);
        (bool noCode,) = address(registry).call(abi.encodeCall(Registry.setDefiInsurance, (address(0x1234))));
        assert(!noCode);
        assert(registry.defiInsurance() == address(0));
    }

    function test_firstScoredRateRegistersTokenAndStoresZeroOrPositiveRateExactly(uint128 rate) public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ScoredTokenSet(tokenA, rate, uint64(block.number));
        registry.setScoredToken(tokenA, rate);
        assert(registry.scoredTokensLength() == 1);
        IERC20[] memory tokens = registry.getScoredTokens();
        assert(tokens.length == 1 && tokens[0] == tokenA);
        Registry.RatePoint[] memory history = registry.getScoredRateHistory(tokenA);
        assert(history.length == 1);
        assert(history[0].fromBlock == uint64(block.number));
        assert(history[0].rate == rate);
    }

    function test_rateHistoryIsAppendOnlyStrictlyIncreasingAndTokenListDoesNotDuplicate(uint128 first, uint128 second)
        public
    {
        registry.setScoredToken(tokenA, first);
        vm.roll(block.number + 1);
        registry.setScoredToken(tokenA, second);
        assert(registry.scoredTokensLength() == 1);
        Registry.RatePoint[] memory history = registry.getScoredRateHistory(tokenA);
        assert(history.length == 2);
        assert(history[0].fromBlock == 1000 && history[0].rate == first);
        assert(history[1].fromBlock == 1001 && history[1].rate == second);

        (bool sameBlock, bytes memory sameBlockData) =
            address(registry).call(abi.encodeCall(Registry.setScoredToken, (tokenA, uint128(3))));
        assert(!sameBlock && _selector(sameBlockData) == Registry.NonIncreasingScoredRateBlock.selector);
        assert(registry.getScoredRateHistory(tokenA).length == 2);
    }

    function test_multipleScoredTokensPreserveFirstAppearanceOrder() public {
        registry.setScoredToken(tokenA, 1);
        vm.roll(block.number + 1);
        registry.setScoredToken(tokenB, 2);
        vm.roll(block.number + 1);
        registry.setScoredToken(tokenA, 0);
        IERC20[] memory tokens = registry.getScoredTokens();
        assert(tokens.length == 2 && tokens[0] == tokenA && tokens[1] == tokenB);
        assert(registry.getScoredRateHistory(tokenA).length == 2);
        assert(registry.getScoredRateHistory(tokenB).length == 1);
    }

    function test_scoredTokenZeroAclAndFreezeFailuresAreAtomic() public {
        (bool zero, bytes memory zeroData) =
            address(registry).call(abi.encodeCall(Registry.setScoredToken, (IERC20(address(0)), uint128(1))));
        assert(!zero && _selector(zeroData) == Registry.ZeroAddress.selector);
        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setScoredToken, (tokenA, uint128(1))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);

        registry.setDefiInsurance(address(moduleA));
        moduleA.setActiveIncidentId(1);
        (bool frozen, bytes memory frozenData) =
            address(registry).call(abi.encodeCall(Registry.setScoredToken, (tokenA, uint128(1))));
        assert(!frozen && _selector(frozenData) == Registry.Frozen.selector);
        assert(registry.scoredTokensLength() == 0);
    }

    function test_boosterConfigIsPermanentNonzeroAndRequiresTimelockAndUnfrozenState() public {
        address booster = address(0xB0057);
        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setBoosterConfig, (booster, uint64(7), uint16(125))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);

        registry.setDefiInsurance(address(moduleA));
        moduleA.setActiveIncidentId(1);
        (bool frozen, bytes memory frozenData) =
            address(registry).call(abi.encodeCall(Registry.setBoosterConfig, (booster, uint64(7), uint16(125))));
        assert(!frozen && _selector(frozenData) == Registry.Frozen.selector);
        moduleA.setActiveIncidentId(0);

        (bool zeroCollection, bytes memory zeroData) =
            address(registry).call(abi.encodeCall(Registry.setBoosterConfig, (address(0), uint64(7), uint16(125))));
        assert(!zeroCollection && _selector(zeroData) == Registry.ZeroAddress.selector);
        (bool zeroBoost, bytes memory zeroBoostData) =
            address(registry).call(abi.encodeCall(Registry.setBoosterConfig, (booster, uint64(7), uint16(0))));
        assert(!zeroBoost && _selector(zeroBoostData) == Registry.InvalidBoosterBoostBps.selector);

        vm.expectEmit(true, false, false, true, address(registry));
        emit BoosterConfigSet(booster, 7, 125);
        registry.setBoosterConfig(booster, 7, 125);
        (address collection, uint64 tokenId, uint16 boostBps) = registry.boosterConfig();
        assert(collection == booster && tokenId == 7 && boostBps == 125);

        (bool second, bytes memory secondData) = address(registry)
            .call(abi.encodeCall(Registry.setBoosterConfig, (address(0xB0058), uint64(8), uint16(126))));
        assert(!second && _selector(secondData) == Registry.BoosterConfigAlreadySet.selector);
        (collection, tokenId, boostBps) = registry.boosterConfig();
        assert(collection == booster && tokenId == 7 && boostBps == 125);
    }

    function test_payoutCapAcceptsStrictInteriorAndRejectsEndpointsAclAndFreeze() public {
        vm.expectEmit(false, false, false, true, address(registry));
        emit MaxCoverPoolPayoutBpsSet(5000, 1);
        registry.setMaxCoverPoolPayoutBps(1);
        assert(registry.maxCoverPoolPayoutBps() == 1);
        registry.setMaxCoverPoolPayoutBps(9999);
        assert(registry.maxCoverPoolPayoutBps() == 9999);

        (bool zero, bytes memory zeroData) =
            address(registry).call(abi.encodeCall(Registry.setMaxCoverPoolPayoutBps, (uint256(0))));
        (bool full, bytes memory fullData) =
            address(registry).call(abi.encodeCall(Registry.setMaxCoverPoolPayoutBps, (uint256(10_000))));
        assert(!zero && _selector(zeroData) == Registry.InvalidMaxCoverPoolPayoutBps.selector);
        assert(!full && _selector(fullData) == Registry.InvalidMaxCoverPoolPayoutBps.selector);
        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setMaxCoverPoolPayoutBps, (uint256(100))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);

        registry.setDefiInsurance(address(moduleA));
        moduleA.setActiveIncidentId(1);
        (bool frozen, bytes memory frozenData) =
            address(registry).call(abi.encodeCall(Registry.setMaxCoverPoolPayoutBps, (uint256(100))));
        assert(!frozen && _selector(frozenData) == Registry.Frozen.selector);
        assert(registry.maxCoverPoolPayoutBps() == 9999);
    }

    function test_scoreSpentOnlyLiveModuleAccumulatesExactlyAndRotatesAuthority(uint128 first, uint128 second) public {
        registry.setDefiInsurance(address(moduleA));
        moduleA.record(registry, ALICE, first);
        assert(registry.scoreSpent(ALICE) == first);
        registry.setDefiInsurance(address(moduleB));
        (bool oldSuccess, bytes memory oldData) =
            address(moduleA).call(abi.encodeCall(RegistryModuleInsuranceModel.record, (registry, ALICE, uint256(1))));
        assert(!oldSuccess && _selector(oldData) == Registry.UnauthorizedModule.selector);
        moduleB.record(registry, ALICE, second);
        assert(registry.scoreSpent(ALICE) == uint256(first) + second);
    }

    function test_scoreSpentUnauthorizedAndOverflowFailuresPreserveLedger() public {
        registry.setDefiInsurance(address(moduleA));
        (bool unauthorized, bytes memory unauthorizedData) =
            address(registry).call(abi.encodeCall(Registry.recordScoreSpent, (ALICE, uint256(1))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedModule.selector);
        moduleA.record(registry, ALICE, type(uint256).max);
        (bool overflow,) =
            address(moduleA).call(abi.encodeCall(RegistryModuleInsuranceModel.record, (registry, ALICE, uint256(1))));
        assert(!overflow);
        assert(registry.scoreSpent(ALICE) == type(uint256).max);
    }
}
