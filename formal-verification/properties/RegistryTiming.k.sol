// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";

contract RegistryTimingHarnessInsurance {
    uint256 public activeIncidentId;

    function setActiveIncidentId(uint256 incidentId) external {
        activeIncidentId = incidentId;
    }

    function isInsuredToken(IERC20) external pure returns (bool) {
        return false;
    }
}

/// @notice Registry timing and incident-open price-policy properties.
/// @dev Slots 21-23 are pinned to the current production storage layout solely to
///      model a legacy proxy upgraded before these appended fields existed.
contract RegistryTimingKontrolTest is Test {
    address internal constant OUTSIDER = address(0xBAD);

    Registry internal registry;
    RegistryTimingHarnessInsurance internal insurance;

    event IncidentTimingConfigSet(Registry.IncidentTimingConfig config);
    event ExitTimingConfigSet(Registry.ExitTimingConfig config);
    event IncidentOpenPriceConfigSet(Registry.IncidentOpenPriceConfig config);
    event ProtocolFeeConfigSet(Registry.ProtocolFeeConfig config);

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        insurance = new RegistryTimingHarnessInsurance();
        registry.setDefiInsurance(address(insurance));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _hashIncident() internal view returns (bytes32) {
        return keccak256(abi.encode(registry.incidentTimingConfig()));
    }

    function _hashExit() internal view returns (bytes32) {
        return keccak256(abi.encode(registry.exitTimingConfig()));
    }

    function _hashPrice() internal view returns (bytes32) {
        return keccak256(abi.encode(registry.incidentOpenPriceConfig()));
    }

    function _hashProtocolFee() internal view returns (bytes32) {
        return keccak256(abi.encode(registry.protocolFeeConfig()));
    }

    function _assertIncidentInvalid(Registry.IncidentTimingConfig memory config, bytes32 before_) internal {
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setIncidentTimingConfig, (config)));
        assert(!success && _selector(data) == Registry.InvalidIncidentTimingConfig.selector);
        assert(_hashIncident() == before_);
    }

    function _assertExitInvalid(Registry.ExitTimingConfig memory config, bytes32 before_) internal {
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setExitTimingConfig, (config)));
        assert(!success && _selector(data) == Registry.InvalidExitTimingConfig.selector);
        assert(_hashExit() == before_);
    }

    function _assertPriceInvalid(Registry.IncidentOpenPriceConfig memory config, bytes32 before_) internal {
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setIncidentOpenPriceConfig, (config)));
        assert(!success && _selector(data) == Registry.InvalidIncidentOpenPriceConfig.selector);
        assert(_hashPrice() == before_);
    }

    function _assertUnauthorizedIncident(Registry.IncidentTimingConfig memory config) internal {
        vm.prank(OUTSIDER);
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setIncidentTimingConfig, (config)));
        assert(!success && _selector(data) == Registry.UnauthorizedTimelock.selector);
    }

    function _assertUnauthorizedExit(Registry.ExitTimingConfig memory config) internal {
        vm.prank(OUTSIDER);
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setExitTimingConfig, (config)));
        assert(!success && _selector(data) == Registry.UnauthorizedTimelock.selector);
    }

    function _assertUnauthorizedPrice(Registry.IncidentOpenPriceConfig memory config) internal {
        vm.prank(OUTSIDER);
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setIncidentOpenPriceConfig, (config)));
        assert(!success && _selector(data) == Registry.UnauthorizedTimelock.selector);
    }

    function _assertFrozenIncident(Registry.IncidentTimingConfig memory config) internal {
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setIncidentTimingConfig, (config)));
        assert(!success && _selector(data) == Registry.Frozen.selector);
    }

    function _assertFrozenExit(Registry.ExitTimingConfig memory config) internal {
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setExitTimingConfig, (config)));
        assert(!success && _selector(data) == Registry.Frozen.selector);
    }

    function _assertFrozenPrice(Registry.IncidentOpenPriceConfig memory config) internal {
        (bool success, bytes memory data) =
            address(registry).call(abi.encodeCall(Registry.setIncidentOpenPriceConfig, (config)));
        assert(!success && _selector(data) == Registry.Frozen.selector);
    }

    function test_defaultPoliciesAreExact() public view {
        assert(registry.MAX_PROTOCOL_FEE_BPS() == 2_000);
        Registry.ProtocolFeeConfig memory fee = registry.protocolFeeConfig();
        assert(fee.receiver == address(this));
        assert(fee.claimProtocolFeeShareBps == 2_000);
        assert(fee.reserveYieldFeeBps == 2_000);

        Registry.IncidentTimingConfig memory incident = registry.incidentTimingConfig();
        assert(incident.phaseWindow == 3 days);
        assert(incident.maxReferenceBlockAge == 43_200);

        Registry.ExitTimingConfig memory exit = registry.exitTimingConfig();
        assert(exit.unstakeCooldown == 7 days);
        assert(exit.exitBatchInterval == 3 days);

        Registry.IncidentOpenPriceConfig memory price = registry.incidentOpenPriceConfig();
        assert(price.twapBlocks == 7200);
        assert(price.sampleStepBlocks == 300);
        assert(price.minimumDropBps == 2000);
    }

    function test_legacyZeroStorageReadsZeroWithoutChangingPriorState() public {
        address timelockBefore = registry.timelock();
        address insuranceBefore = registry.defiInsurance();
        vm.store(address(registry), bytes32(uint256(21)), bytes32(0));
        vm.store(address(registry), bytes32(uint256(22)), bytes32(0));
        vm.store(address(registry), bytes32(uint256(23)), bytes32(0));

        assert(registry.timelock() == timelockBefore);
        assert(registry.defiInsurance() == insuranceBefore);
        Registry.IncidentTimingConfig memory incident = registry.incidentTimingConfig();
        Registry.ExitTimingConfig memory exit = registry.exitTimingConfig();
        Registry.IncidentOpenPriceConfig memory price = registry.incidentOpenPriceConfig();
        assert(incident.phaseWindow == 0 && incident.maxReferenceBlockAge == 0);
        assert(exit.unstakeCooldown == 0 && exit.exitBatchInterval == 0);
        assert(price.twapBlocks == 0 && price.sampleStepBlocks == 0 && price.minimumDropBps == 0);
    }

    function test_validPoliciesStoreExactValuesAndEmitExactEvents() public {
        Registry.ProtocolFeeConfig memory fee = Registry.ProtocolFeeConfig({
            receiver: address(0xFEE), claimProtocolFeeShareBps: 1234, reserveYieldFeeBps: 567
        });
        vm.expectEmit(false, false, false, true, address(registry));
        emit ProtocolFeeConfigSet(fee);
        registry.setProtocolFeeConfig(fee);
        bytes32 feeBefore = keccak256(abi.encode(fee));
        assert(_hashProtocolFee() == feeBefore);

        Registry.ProtocolFeeConfig memory invalidFee =
            Registry.ProtocolFeeConfig({receiver: address(0), claimProtocolFeeShareBps: 1234, reserveYieldFeeBps: 567});
        (bool zeroReceiver, bytes memory zeroReceiverData) =
            address(registry).call(abi.encodeCall(Registry.setProtocolFeeConfig, (invalidFee)));
        assert(
            !zeroReceiver
                && keccak256(zeroReceiverData) == keccak256(abi.encodeWithSelector(Registry.ZeroAddress.selector))
                && _hashProtocolFee() == feeBefore
        );

        invalidFee = Registry.ProtocolFeeConfig({
            receiver: address(0xFEE), claimProtocolFeeShareBps: 2_001, reserveYieldFeeBps: 567
        });
        (bool invalidClaimFee, bytes memory invalidClaimData) =
            address(registry).call(abi.encodeCall(Registry.setProtocolFeeConfig, (invalidFee)));
        assert(
            !invalidClaimFee
                && keccak256(invalidClaimData)
                    == keccak256(abi.encodeWithSelector(Registry.InvalidProtocolFeeBps.selector, uint256(2_001)))
                && _hashProtocolFee() == feeBefore
        );

        invalidFee = Registry.ProtocolFeeConfig({
            receiver: address(0xFEE), claimProtocolFeeShareBps: 1234, reserveYieldFeeBps: 2_001
        });
        (bool invalidReserveFee, bytes memory invalidReserveData) =
            address(registry).call(abi.encodeCall(Registry.setProtocolFeeConfig, (invalidFee)));
        assert(
            !invalidReserveFee
                && keccak256(invalidReserveData)
                    == keccak256(abi.encodeWithSelector(Registry.InvalidProtocolFeeBps.selector, uint256(2_001)))
                && _hashProtocolFee() == feeBefore
        );

        vm.prank(OUTSIDER);
        (bool unauthorized, bytes memory unauthorizedData) =
            address(registry).call(abi.encodeCall(Registry.setProtocolFeeConfig, (fee)));
        assert(
            !unauthorized
                && keccak256(unauthorizedData)
                    == keccak256(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, OUTSIDER))
                && _hashProtocolFee() == feeBefore
        );

        Registry.IncidentTimingConfig memory incident =
            Registry.IncidentTimingConfig({phaseWindow: 11, maxReferenceBlockAge: 10_000});
        vm.expectEmit(false, false, false, true, address(registry));
        emit IncidentTimingConfigSet(incident);
        registry.setIncidentTimingConfig(incident);
        assert(_hashIncident() == keccak256(abi.encode(incident)));

        Registry.ExitTimingConfig memory exit = Registry.ExitTimingConfig({unstakeCooldown: 15, exitBatchInterval: 16});
        vm.expectEmit(false, false, false, true, address(registry));
        emit ExitTimingConfigSet(exit);
        registry.setExitTimingConfig(exit);
        assert(_hashExit() == keccak256(abi.encode(exit)));

        Registry.IncidentOpenPriceConfig memory price =
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 1234});
        vm.expectEmit(false, false, false, true, address(registry));
        emit IncidentOpenPriceConfigSet(price);
        registry.setIncidentOpenPriceConfig(price);
        assert(_hashPrice() == keccak256(abi.encode(price)));
    }

    function test_incidentTimingInvalidBoundariesRollbackAtomically() public {
        Registry.IncidentTimingConfig memory valid = registry.incidentTimingConfig();
        bytes32 before_ = _hashIncident();

        Registry.IncidentTimingConfig memory c = valid;
        c.phaseWindow = 0;
        _assertIncidentInvalid(c, before_);

        c = valid;
        c.maxReferenceBlockAge = 0;
        _assertIncidentInvalid(c, before_);
        c.maxReferenceBlockAge = registry.incidentOpenPriceConfig().twapBlocks;
        _assertIncidentInvalid(c, before_);
    }

    function test_exitTimingInvalidBoundariesRollbackAtomically() public {
        Registry.ExitTimingConfig memory valid = registry.exitTimingConfig();
        bytes32 before_ = _hashExit();

        Registry.ExitTimingConfig memory c = valid;
        c.unstakeCooldown = 0;
        _assertExitInvalid(c, before_);

        c = valid;
        c.exitBatchInterval = 0;
        _assertExitInvalid(c, before_);

        Registry.ExitTimingConfig memory maximum =
            Registry.ExitTimingConfig({unstakeCooldown: type(uint64).max, exitBatchInterval: type(uint64).max});
        registry.setExitTimingConfig(maximum);
        assert(_hashExit() == keccak256(abi.encode(maximum)));
    }

    function test_incidentOpenPriceInvalidBoundariesRollbackAtomically() public {
        Registry.IncidentOpenPriceConfig memory valid = registry.incidentOpenPriceConfig();
        bytes32 before_ = _hashPrice();

        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 0, sampleStepBlocks: 1, minimumDropBps: 1}), before_
        );
        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 0, minimumDropBps: 1}), before_
        );
        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 1201, minimumDropBps: 1}), before_
        );
        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 1201, sampleStepBlocks: 300, minimumDropBps: 1}), before_
        );
        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 300, sampleStepBlocks: 300, minimumDropBps: 1}), before_
        );
        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 0}), before_
        );
        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 10_000}), before_
        );
        _assertPriceInvalid(
            Registry.IncidentOpenPriceConfig({twapBlocks: 43_200, sampleStepBlocks: 300, minimumDropBps: 1}), before_
        );
        assert(_hashPrice() == keccak256(abi.encode(valid)));
    }

    function test_incidentOpenPriceAcceptedBoundariesStoreExactly() public {
        Registry.IncidentOpenPriceConfig memory minimum =
            Registry.IncidentOpenPriceConfig({twapBlocks: 2, sampleStepBlocks: 1, minimumDropBps: 1});
        registry.setIncidentOpenPriceConfig(minimum);
        assert(_hashPrice() == keccak256(abi.encode(minimum)));

        Registry.IncidentOpenPriceConfig memory maximum =
            Registry.IncidentOpenPriceConfig({twapBlocks: 43_199, sampleStepBlocks: 1, minimumDropBps: 9_999});
        registry.setIncidentOpenPriceConfig(maximum);
        assert(_hashPrice() == keccak256(abi.encode(maximum)));
    }

    function test_unauthorizedAndFrozenPolicyUpdatesRollbackAllFamilies() public {
        Registry.IncidentTimingConfig memory incident =
            Registry.IncidentTimingConfig({phaseWindow: 11, maxReferenceBlockAge: 10_000});
        Registry.ExitTimingConfig memory exit = Registry.ExitTimingConfig({unstakeCooldown: 15, exitBatchInterval: 16});
        Registry.IncidentOpenPriceConfig memory price =
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 1234});
        bytes32 incidentBefore = _hashIncident();
        bytes32 exitBefore = _hashExit();
        bytes32 priceBefore = _hashPrice();

        _assertUnauthorizedIncident(incident);
        _assertUnauthorizedExit(exit);
        _assertUnauthorizedPrice(price);

        insurance.setActiveIncidentId(1);
        _assertFrozenIncident(incident);
        _assertFrozenExit(exit);
        _assertFrozenPrice(price);
        assert(_hashIncident() == incidentBefore);
        assert(_hashExit() == exitBefore);
        assert(_hashPrice() == priceBefore);
    }

    function test_crossPolicyReferenceWindowInvariantIsMaintainedBothDirections() public {
        Registry.IncidentOpenPriceConfig memory price =
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 1234});
        registry.setIncidentOpenPriceConfig(price);
        Registry.IncidentTimingConfig memory incident =
            Registry.IncidentTimingConfig({phaseWindow: 11, maxReferenceBlockAge: 2000});
        registry.setIncidentTimingConfig(incident);

        bytes32 incidentBefore = _hashIncident();
        bytes32 priceBefore = _hashPrice();
        incident.maxReferenceBlockAge = 1200;
        _assertIncidentInvalid(incident, incidentBefore);
        price.twapBlocks = 2000;
        price.sampleStepBlocks = 250;
        _assertPriceInvalid(price, priceBefore);
    }
}
