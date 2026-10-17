// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Registry} from "../../src/Registry.sol";
import {Create3Deployer} from "./Create3Deployer.sol";
import {USD8DeploymentLabels} from "./USD8DeploymentLabels.sol";

/// @title TimelockHandOff
/// @notice Deploys, validates and installs the USD8 governance timelock. Used by step 02 after
///         the system (step 01) has been deployed and configured under interim deployer authority.
/// @dev Governance has TWO independent handles and both must move together:
///        1. Registry.timelock — upgrade/config authority for Registry, USD8, Treasury,
///           DefiInsurance and every Registry topology setter;
///        2. the pool UpgradeableBeacon owner — upgrade authority for every cover pool.
///      Registry.setTimelock is single-step and IRREVERSIBLE, so it is always the LAST call,
///      after the timelock's delay and roles have been validated.
abstract contract TimelockHandOff is Create3Deployer, USD8DeploymentLabels {
    /// @notice TimelockController minDelay. During beta it must stay strictly under
    ///         DefiInsurance.CORRECTION_WINDOW (2 days) so timelock root correction fits.
    uint256 public constant TIMELOCK_MIN_DELAY = 24 hours;

    error InvalidTimelockDelay(uint256 actual, uint256 expected);
    error MissingTimelockRole(bytes32 role, address account);
    error UnexpectedTimelockAdmin(address account);
    error SystemNotDeployed(bytes32 field, address expected);
    error NotInterimTimelock(address expected, address actual);
    error UnexpectedBeaconOwner(address expected, address actual);
    error HandOffIncomplete();

    /// @notice Self-administered timelock: one proposer/canceller, open execution, 24h delay.
    /// @param deployer Account that calls CreateX (the broadcaster); owns the CREATE3 salt.
    function _deployTimelock(address deployer, address proposer) internal returns (TimelockController timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = address(0);

        timelock = TimelockController(
            payable(
                _create3(
                    deployer,
                    LABEL_TIMELOCK,
                    abi.encodePacked(
                        type(TimelockController).creationCode,
                        abi.encode(TIMELOCK_MIN_DELAY, proposers, executors, address(0))
                    )
                )
            )
        );
    }

    /// @notice Reverts unless `timelockAddress` has exactly the expected delay and role layout.
    function _validateTimelock(address timelockAddress, address proposer) internal view {
        TimelockController timelock = TimelockController(payable(timelockAddress));
        uint256 actualDelay = timelock.getMinDelay();
        if (actualDelay != TIMELOCK_MIN_DELAY) revert InvalidTimelockDelay(actualDelay, TIMELOCK_MIN_DELAY);

        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        if (!timelock.hasRole(proposerRole, proposer)) revert MissingTimelockRole(proposerRole, proposer);

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        if (!timelock.hasRole(cancellerRole, proposer)) revert MissingTimelockRole(cancellerRole, proposer);

        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        if (!timelock.hasRole(executorRole, address(0))) revert MissingTimelockRole(executorRole, address(0));

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        if (!timelock.hasRole(adminRole, timelockAddress)) revert MissingTimelockRole(adminRole, timelockAddress);
        if (timelock.hasRole(adminRole, proposer)) revert UnexpectedTimelockAdmin(proposer);
    }

    /// @notice Reverts unless the step-01 system exists and `deployer` still holds BOTH interim
    ///         governance handles (i.e. the hand-off has not happened yet).
    function _validateInterimAuthority(Registry registry, address beacon, address deployer) internal view {
        if (address(registry).code.length == 0) revert SystemNotDeployed("registry", address(registry));
        if (beacon.code.length == 0) revert SystemNotDeployed("poolBeacon", beacon);

        address currentTimelock = registry.timelock();
        if (currentTimelock != deployer) revert NotInterimTimelock(deployer, currentTimelock);

        address beaconOwner = UpgradeableBeacon(beacon).owner();
        if (beaconOwner != deployer) revert UnexpectedBeaconOwner(deployer, beaconOwner);
    }

    /// @notice Moves all governance from the interim deployer to `timelock`.
    /// @dev Order: beacon ownership, then admin set (grant configured admin; drop the deployer
    ///      only when it is not the configured admin — otherwise the two calls would cancel out
    ///      and leave an EMPTY admin set), then setTimelock LAST (irreversible).
    function _handOffToTimelock(
        Registry registry,
        address beacon,
        TimelockController timelock,
        address deployer,
        address admin
    ) internal {
        UpgradeableBeacon(beacon).transferOwnership(address(timelock));

        if (!registry.isAdmin(admin)) registry.setAdmin(admin, true);
        if (deployer != admin && registry.isAdmin(deployer)) registry.setAdmin(deployer, false);

        registry.setTimelock(address(timelock));

        if (
            registry.timelock() != address(timelock) || UpgradeableBeacon(beacon).owner() != address(timelock)
                || !registry.isAdmin(admin)
        ) revert HandOffIncomplete();
    }
}
