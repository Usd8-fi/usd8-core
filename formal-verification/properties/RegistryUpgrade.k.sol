// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";

contract RegistryUpgradeV2 is Registry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract RegistryUpgradePayableV2 is Registry {
    uint256 public candidateValue;
    uint256 public initializerValue;

    function initializeV2Payable(uint256 value) external payable reinitializer(2) {
        candidateValue = value;
        initializerValue = msg.value;
    }
}

contract RegistryUpgradeFailingV2 is Registry {
    error InitializationFailed();

    uint256 public candidateValue;

    function initializeV2ThenRevert(uint256 value) external payable reinitializer(2) {
        candidateValue = value;
        revert InitializationFailed();
    }
}

contract RegistryUpgradeNonUUPS {
    function version() external pure returns (uint256) {
        return 999;
    }
}

contract RegistryUpgradeWrongUUID {
    bytes32 public constant WRONG_UUID = keccak256("usd8.registry.kontrol.wrong.uuid");

    function proxiableUUID() external pure returns (bytes32) {
        return WRONG_UUID;
    }
}

contract RegistryUpgradeToken {}

contract RegistryUpgradeFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, 0, 1, 1);
    }
}

contract RegistryUpgradePool {
    IERC20 public immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }
}

contract RegistryUpgradeInsurance {
    uint256 public activeIncidentId;

    function setActiveIncidentId(uint256 incidentId) external {
        activeIncidentId = incidentId;
    }

    function isInsuredToken(IERC20) external pure returns (bool) {
        return false;
    }

    function record(Registry registry, address account, uint256 amount) external {
        registry.recordScoreSpent(account, amount);
    }
}

/// @notice Registry beta-only UUPS compatibility and representative-state preservation properties.
/// @dev Arbitrary future implementation safety remains a trusted-governance boundary.
contract RegistryUpgradeKontrolTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xBEEF);
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant NO_CODE_CANDIDATE = address(0xF00D);

    Registry internal implementation;
    Registry internal registry;
    RegistryUpgradeInsurance internal insurance;
    IERC20 internal token;
    RegistryUpgradeFeed internal feed;
    RegistryUpgradePool internal pool;

    event Upgraded(address indexed implementation);

    function setUp() public {
        implementation = new Registry();
        registry = Registry(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        insurance = new RegistryUpgradeInsurance();
        token = IERC20(address(new RegistryUpgradeToken()));
        feed = new RegistryUpgradeFeed();
        pool = new RegistryUpgradePool(token);
        vm.roll(1000);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _implementationWord() internal view returns (bytes32) {
        return vm.load(address(registry), IMPLEMENTATION_SLOT);
    }

    function _implementationWord(address candidate) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(candidate)));
    }

    function _seedRepresentativeState() internal {
        registry.setAdmin(USER, true);
        registry.setPaused(USER, true);
        registry.setUsd8(address(0x1001));
        registry.setTreasury(address(0x1002));
        registry.setSavingsVault(address(0x1003));
        registry.setUsd8PriceOracle(address(0x1004));
        registry.setSwapRoute(address(0x2001), address(0x2002), true);
        registry.setTeePcrHash(keccak256("PCR"));
        registry.setBoosterConfig(address(0x3001), 7, 125);
        registry.setMaxCoverPoolPayoutBps(7777);
        registry.setMaxOracleStaleness(123);
        registry.setExitTimingConfig(Registry.ExitTimingConfig({unstakeCooldown: 11, exitBatchInterval: 12}));
        registry.setIncidentTimingConfig(Registry.IncidentTimingConfig({phaseWindow: 13, maxReferenceBlockAge: 10_000}));
        registry.setIncidentOpenPriceConfig(
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 1234})
        );
        registry.setDefiInsurance(address(insurance));
        registry.addPool(address(pool), address(feed));
        registry.setScoredToken(token, 99);
        insurance.record(registry, USER, 42);
    }

    function _stateHash() internal view returns (bytes32) {
        bytes32 authorityHash = keccak256(
            abi.encode(
                registry.timelock(),
                registry.isAdmin(ADMIN),
                registry.isAdmin(USER),
                registry.paused(USER),
                registry.betaMode(),
                registry.teePcrHash(),
                registry.usd8(),
                registry.treasury(),
                registry.savingsVault(),
                registry.usd8PriceOracle()
            )
        );
        (address booster, uint64 boosterId, uint16 boosterBoostBps) = registry.boosterConfig();
        bytes32 riskHash = keccak256(
            abi.encode(
                registry.maxCoverPoolPayoutBps(),
                registry.maxOracleStaleness(),
                booster,
                boosterId,
                boosterBoostBps,
                registry.defiInsurance(),
                registry.approvedSwapRoute(address(0x2001), address(0x2002)),
                registry.scoreSpent(USER)
            )
        );
        (IERC20[] memory assets, address[] memory pools) = registry.coverPools();
        IERC20[] memory scored = registry.getScoredTokens();
        Registry.RatePoint[] memory history = registry.getScoredRateHistory(token);
        bytes32 topologyHash = keccak256(abi.encode(assets, pools, registry.assetUsdFeed(token), scored, history));
        bytes32 policyHash = keccak256(
            abi.encode(registry.incidentTimingConfig(), registry.exitTimingConfig(), registry.incidentOpenPriceConfig())
        );
        return keccak256(abi.encode(authorityHash, riskHash, topologyHash, policyHash));
    }

    function test_proxiableUUIDAndUpgradeInterfaceContextsAreExact() public view {
        assert(implementation.proxiableUUID() == IMPLEMENTATION_SLOT);
        assert(keccak256(bytes(implementation.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));
        assert(keccak256(bytes(registry.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));
        (bool success, bytes memory data) =
            address(registry).staticcall(abi.encodeCall(IERC1822Proxiable.proxiableUUID, ()));
        assert(!success && _selector(data) == UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
    }

    function test_directImplementationCannotUpgrade() public {
        RegistryUpgradeV2 candidate = new RegistryUpgradeV2();
        (bool success, bytes memory data) = address(implementation)
            .call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!success && _selector(data) == UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
    }

    function test_namedV2UpgradePreservesRepresentativeRegistryState() public {
        _seedRepresentativeState();
        bytes32 stateBefore = _stateHash();
        RegistryUpgradeV2 candidate = new RegistryUpgradeV2();
        vm.expectEmit(true, false, false, true, address(registry));
        emit Upgraded(address(candidate));
        registry.upgradeToAndCall(address(candidate), "");
        assert(_implementationWord() == _implementationWord(address(candidate)));
        assert(RegistryUpgradeV2(address(registry)).version() == 2);
        assert(_stateHash() == stateBefore);
    }

    function test_nonTimelockAndPostBetaUpgradeFailuresAreAtomic() public {
        RegistryUpgradeV2 candidate = new RegistryUpgradeV2();
        bytes32 implementationBefore = _implementationWord();
        vm.prank(OUTSIDER);
        (bool unauthorized, bytes memory unauthorizedData) =
            address(registry).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);
        assert(_implementationWord() == implementationBefore);

        registry.endBetaMode();
        (bool disabled, bytes memory disabledData) =
            address(registry).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!disabled && _selector(disabledData) == Registry.UpgradesPermanentlyDisabled.selector);
        assert(_implementationWord() == implementationBefore);
    }

    function test_noCodeNonUUPSAndWrongUUIDCandidatesRollbackImplementation() public {
        bytes32 implementationBefore = _implementationWord();
        (bool noCode, bytes memory noCodeData) =
            address(registry).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (NO_CODE_CANDIDATE, bytes(""))));
        assert(!noCode && noCodeData.length == 0);
        assert(_implementationWord() == implementationBefore);

        RegistryUpgradeNonUUPS nonUups = new RegistryUpgradeNonUUPS();
        (bool nonUupsSuccess, bytes memory nonUupsData) =
            address(registry).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(nonUups), bytes(""))));
        assert(!nonUupsSuccess);
        assert(
            keccak256(nonUupsData)
                == keccak256(
                    abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(nonUups))
                )
        );
        assert(_implementationWord() == implementationBefore);

        RegistryUpgradeWrongUUID wrong = new RegistryUpgradeWrongUUID();
        (bool wrongSuccess, bytes memory wrongData) =
            address(registry).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(wrong), bytes(""))));
        assert(!wrongSuccess);
        assert(
            keccak256(wrongData)
                == keccak256(
                    abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, wrong.WRONG_UUID())
                )
        );
        assert(_implementationWord() == implementationBefore);
    }

    function test_emptyUpgradeDataWithValueRevertsAndRollsBack() public {
        RegistryUpgradeV2 candidate = new RegistryUpgradeV2();
        bytes32 implementationBefore = _implementationWord();
        vm.deal(address(this), 1 ether);
        uint256 callerBefore = address(this).balance;
        (bool success, bytes memory data) = address(registry).call{value: 1 ether}(
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes("")))
        );
        assert(!success && _selector(data) == ERC1967Utils.ERC1967NonPayable.selector);
        assert(_implementationWord() == implementationBefore);
        assert(address(registry).balance == 0);
        assert(address(this).balance == callerBefore);
    }

    function test_payableV2InitializerReceivesValueAndPreservesPriorState() public {
        _seedRepresentativeState();
        bytes32 stateBefore = _stateHash();
        RegistryUpgradePayableV2 candidate = new RegistryUpgradePayableV2();
        vm.deal(address(this), 1 ether);
        registry.upgradeToAndCall{value: 1 ether}(
            address(candidate), abi.encodeCall(RegistryUpgradePayableV2.initializeV2Payable, (uint256(77)))
        );
        RegistryUpgradePayableV2 upgraded = RegistryUpgradePayableV2(payable(address(registry)));
        assert(upgraded.candidateValue() == 77);
        assert(upgraded.initializerValue() == 1 ether);
        assert(address(registry).balance == 1 ether);
        assert(_stateHash() == stateBefore);
    }

    function test_failingPayableInitializerRollsBackImplementationStateAndValue() public {
        _seedRepresentativeState();
        bytes32 stateBefore = _stateHash();
        bytes32 implementationBefore = _implementationWord();
        RegistryUpgradeFailingV2 candidate = new RegistryUpgradeFailingV2();
        vm.deal(address(this), 1 ether);
        uint256 callerBefore = address(this).balance;
        bytes memory initializer = abi.encodeCall(RegistryUpgradeFailingV2.initializeV2ThenRevert, (uint256(88)));
        (bool success, bytes memory data) = address(registry).call{value: 1 ether}(
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), initializer))
        );
        assert(!success && _selector(data) == RegistryUpgradeFailingV2.InitializationFailed.selector);
        assert(_implementationWord() == implementationBefore);
        assert(_stateHash() == stateBefore);
        assert(address(registry).balance == 0);
        assert(address(this).balance == callerBefore);
    }

    function test_betaUpgradeDuringActiveIncidentIsCurrentlyAllowedAndPreservesFreeze() public {
        registry.setDefiInsurance(address(insurance));
        insurance.setActiveIncidentId(1);
        assert(registry.payoutIncidentActive());
        RegistryUpgradeV2 candidate = new RegistryUpgradeV2();
        registry.upgradeToAndCall(address(candidate), "");
        assert(RegistryUpgradeV2(address(registry)).version() == 2);
        assert(registry.defiInsurance() == address(insurance));
        assert(registry.payoutIncidentActive());
        assert(registry.betaMode());
    }
}
