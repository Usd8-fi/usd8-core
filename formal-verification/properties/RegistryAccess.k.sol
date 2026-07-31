// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";

contract RegistryAccessInsuranceModel {
    uint256 public activeIncidentId;

    function setActiveIncidentId(uint256 incidentId) external {
        activeIncidentId = incidentId;
    }

    function isInsuredToken(IERC20) external pure returns (bool) {
        return false;
    }
}

/// @notice Registry initialization, authority, pause, canonical-address, and beta properties.
contract RegistryAccessKontrolTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant NEXT_TIMELOCK = address(0xBEEF);

    Registry internal implementation;
    Registry internal registry;
    RegistryAccessInsuranceModel internal insurance;

    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);
    event AdminSet(address indexed account, bool allowed);
    event PausedSet(address indexed target, bool paused);
    event SwapRouteSet(address indexed target, address indexed spender, bool allowed);
    event TeePcrHashSet(bytes32 indexed oldHash, bytes32 indexed newHash);
    event Usd8Set(address indexed oldUsd8, address indexed newUsd8);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event SavingsVaultSet(address indexed oldSavingsVault, address indexed newSavingsVault);
    event Usd8PriceOracleSet(address indexed oldOracle, address indexed newOracle);
    event BetaModeEnded();

    function setUp() public {
        implementation = new Registry();
        registry = Registry(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        insurance = new RegistryAccessInsuranceModel();
        registry.setDefiInsurance(address(insurance));
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

    function _assertCanonicalZeroRejectedBeforeSet() internal {
        (bool z0, bytes memory z0d) = address(registry).call(abi.encodeCall(Registry.setUsd8, (address(0))));
        (bool z1, bytes memory z1d) = address(registry).call(abi.encodeCall(Registry.setTreasury, (address(0))));
        (bool z2, bytes memory z2d) = address(registry).call(abi.encodeCall(Registry.setSavingsVault, (address(0))));
        (bool z3, bytes memory z3d) = address(registry).call(abi.encodeCall(Registry.setUsd8PriceOracle, (address(0))));
        assert(!z0 && !z1 && !z2 && !z3);
        assert(_selector(z0d) == Registry.ZeroAddress.selector);
        assert(_selector(z1d) == Registry.ZeroAddress.selector);
        assert(_selector(z2d) == Registry.ZeroAddress.selector);
        assert(_selector(z3d) == Registry.ZeroAddress.selector);
    }

    function _assertOneTimeCanonicalSettersRejectRepeat() internal {
        address usd8Before = registry.usd8();
        address treasuryBefore = registry.treasury();
        address vaultBefore = registry.savingsVault();
        (bool usd8Again, bytes memory usd8AgainData) =
            address(registry).call(abi.encodeCall(Registry.setUsd8, (address(0x2001))));
        (bool treasuryAgain, bytes memory treasuryAgainData) =
            address(registry).call(abi.encodeCall(Registry.setTreasury, (address(0x2002))));
        (bool vaultAgain, bytes memory vaultAgainData) =
            address(registry).call(abi.encodeCall(Registry.setSavingsVault, (address(0x2003))));
        assert(!usd8Again && _selector(usd8AgainData) == Registry.Usd8AlreadySet.selector);
        assert(!treasuryAgain && _selector(treasuryAgainData) == Registry.TreasuryAlreadySet.selector);
        assert(!vaultAgain && _selector(vaultAgainData) == Registry.SavingsVaultAlreadySet.selector);
        assert(registry.usd8() == usd8Before);
        assert(registry.treasury() == treasuryBefore);
        assert(registry.savingsVault() == vaultBefore);
    }

    function test_initializationDefaultsAndRolesAreExact() public view {
        assert(registry.timelock() == address(this));
        assert(registry.isAdmin(ADMIN));
        assert(!registry.isAdmin(OUTSIDER));
        assert(registry.betaMode());
        assert(registry.maxCoverPoolPayoutBps() == 5000);
        assert(registry.maxOracleStaleness() == 36 hours);
        assert(registry.coverPoolsLength() == 0);
        assert(registry.scoredTokensLength() == 0);
    }

    function test_directImplementationAndProxyReinitializationAreLocked() public {
        (bool direct, bytes memory directData) =
            address(implementation).call(abi.encodeCall(Registry.initialize, (address(this), ADMIN)));
        assert(!direct && _selector(directData) == Initializable.InvalidInitialization.selector);
        (bool proxy, bytes memory proxyData) =
            address(registry).call(abi.encodeCall(Registry.initialize, (address(this), ADMIN)));
        assert(!proxy && _selector(proxyData) == Initializable.InvalidInitialization.selector);
        assert(registry.timelock() == address(this));
        assert(registry.isAdmin(ADMIN));
    }

    function test_timelockRotationImmediatelyTransfersAuthority() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit TimelockChanged(address(this), NEXT_TIMELOCK);
        registry.setTimelock(NEXT_TIMELOCK);
        assert(registry.timelock() == NEXT_TIMELOCK);

        (bool oldSuccess, bytes memory oldData) =
            address(registry).call(abi.encodeCall(Registry.setAdmin, (OUTSIDER, true)));
        assert(!oldSuccess && _selector(oldData) == Registry.UnauthorizedTimelock.selector);
        vm.prank(NEXT_TIMELOCK);
        registry.setAdmin(OUTSIDER, true);
        assert(registry.isAdmin(OUTSIDER));
    }

    function test_timelockAndAdminMutationRejectZeroAndUnauthorizedAtomically() public {
        (bool zeroTimelock, bytes memory zeroTimelockData) =
            address(registry).call(abi.encodeCall(Registry.setTimelock, (address(0))));
        (bool zeroAdmin, bytes memory zeroAdminData) =
            address(registry).call(abi.encodeCall(Registry.setAdmin, (address(0), true)));
        assert(!zeroTimelock && _selector(zeroTimelockData) == Registry.ZeroAddress.selector);
        assert(!zeroAdmin && _selector(zeroAdminData) == Registry.ZeroAddress.selector);

        vm.expectEmit(true, false, false, true, address(registry));
        emit AdminSet(OUTSIDER, true);
        registry.setAdmin(OUTSIDER, true);
        assert(registry.isAdmin(OUTSIDER));
        registry.setAdmin(OUTSIDER, false);
        assert(!registry.isAdmin(OUTSIDER));

        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setAdmin, (OUTSIDER, true)));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);
        assert(!registry.isAdmin(OUTSIDER));
        assert(registry.timelock() == address(this));
    }

    function test_canonicalAddressSettersRespectOneTimeAndRepeatableSemantics() public {
        address a = address(0x1001);
        address b = address(0x1002);
        address c = address(0x1003);
        address d = address(0x1004);

        _assertCanonicalZeroRejectedBeforeSet();

        vm.expectEmit(true, true, false, true, address(registry));
        emit Usd8Set(address(0), a);
        registry.setUsd8(a);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TreasurySet(address(0), b);
        registry.setTreasury(b);
        vm.expectEmit(true, true, false, true, address(registry));
        emit SavingsVaultSet(address(0), c);
        registry.setSavingsVault(c);
        vm.expectEmit(true, true, false, true, address(registry));
        emit Usd8PriceOracleSet(address(0), d);
        registry.setUsd8PriceOracle(d);
        assert(registry.usd8() == a);
        assert(registry.treasury() == b);
        assert(registry.savingsVault() == c);
        assert(registry.usd8PriceOracle() == d);

        _assertOneTimeCanonicalSettersRejectRepeat();

        address nextOracle = address(0x2004);
        vm.expectEmit(true, true, false, true, address(registry));
        emit Usd8PriceOracleSet(d, nextOracle);
        registry.setUsd8PriceOracle(nextOracle);
        assert(registry.usd8PriceOracle() == nextOracle);

        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setTreasury, (address(0xCAFE))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);
        assert(registry.treasury() == b);
    }

    function test_swapRoutePairGrantRevokeAclAndZeroGuardsAreExact() public {
        address target = address(0x2001);
        address spender = address(0x2002);
        vm.expectEmit(true, true, false, true, address(registry));
        emit SwapRouteSet(target, spender, true);
        registry.setSwapRoute(target, spender, true);
        assert(registry.approvedSwapRoute(target, spender));
        assert(!registry.approvedSwapRoute(target, address(0x2003)));
        registry.setSwapRoute(target, spender, false);
        assert(!registry.approvedSwapRoute(target, spender));

        (bool z0, bytes memory z0d) =
            address(registry).call(abi.encodeCall(Registry.setSwapRoute, (address(0), spender, true)));
        (bool z1, bytes memory z1d) =
            address(registry).call(abi.encodeCall(Registry.setSwapRoute, (target, address(0), true)));
        assert(!z0 && _selector(z0d) == Registry.ZeroAddress.selector);
        assert(!z1 && _selector(z1d) == Registry.ZeroAddress.selector);
        (bool adminSuccess, bytes memory adminData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setSwapRoute, (target, spender, true)));
        assert(!adminSuccess && _selector(adminData) == Registry.UnauthorizedTimelock.selector);
    }

    function test_pauseSingleBatchAndCrossContractChecksAreExact() public {
        address a = address(0x3001);
        address b = address(0x3002);
        address[] memory targets = new address[](3);
        targets[0] = a;
        targets[1] = b;
        targets[2] = a;

        vm.prank(ADMIN);
        registry.setPaused(a, true);
        assert(registry.paused(a));
        (bool pausedCheck, bytes memory pausedData) =
            address(registry).staticcall(abi.encodeCall(Registry.requireNotPaused, (a)));
        assert(!pausedCheck && _selector(pausedData) == Registry.Paused.selector);

        vm.prank(ADMIN);
        registry.setPausedBatch(targets, false);
        assert(!registry.paused(a) && !registry.paused(b));
        registry.requireNotPaused(a);

        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(OUTSIDER, abi.encodeCall(Registry.setPaused, (a, true)));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedAdmin.selector);
        assert(!registry.paused(a));
    }

    function test_externalRoleChecksAcceptLiveRolesAndRejectRepresentativeOutsider() public view {
        registry.requireTimelock(address(this));
        registry.requireAdminOrTimelock(address(this));
        registry.requireAdminOrTimelock(ADMIN);
        (bool timelockOk, bytes memory timelockData) =
            address(registry).staticcall(abi.encodeCall(Registry.requireTimelock, (OUTSIDER)));
        (bool adminOk, bytes memory adminData) =
            address(registry).staticcall(abi.encodeCall(Registry.requireAdminOrTimelock, (OUTSIDER)));
        assert(!timelockOk && _selector(timelockData) == Registry.UnauthorizedTimelock.selector);
        assert(!adminOk && _selector(adminData) == Registry.UnauthorizedAdmin.selector);
    }

    function test_teePcrHashExactAclZeroAndFreezeBehavior() public {
        bytes32 h = keccak256("PCR");
        vm.expectEmit(true, true, false, true, address(registry));
        emit TeePcrHashSet(bytes32(0), h);
        registry.setTeePcrHash(h);
        assert(registry.teePcrHash() == h);

        (bool zero, bytes memory zeroData) =
            address(registry).call(abi.encodeCall(Registry.setTeePcrHash, (bytes32(0))));
        assert(!zero && _selector(zeroData) == Registry.InvalidTeePcrHash.selector);
        insurance.setActiveIncidentId(1);
        (bool frozen, bytes memory frozenData) =
            address(registry).call(abi.encodeCall(Registry.setTeePcrHash, (keccak256("NEW"))));
        assert(!frozen && _selector(frozenData) == Registry.Frozen.selector);
        assert(registry.teePcrHash() == h);
    }

    function test_endBetaIsTimelockOnlyOneWayAndFrozenGated() public {
        (bool unauthorized, bytes memory unauthorizedData) = _callAs(ADMIN, abi.encodeCall(Registry.endBetaMode, ()));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);
        insurance.setActiveIncidentId(1);
        (bool frozen, bytes memory frozenData) = address(registry).call(abi.encodeCall(Registry.endBetaMode, ()));
        assert(!frozen && _selector(frozenData) == Registry.Frozen.selector);
        assert(registry.betaMode());

        insurance.setActiveIncidentId(0);
        vm.expectEmit(false, false, false, true, address(registry));
        emit BetaModeEnded();
        registry.endBetaMode();
        assert(!registry.betaMode());
        registry.endBetaMode();
        assert(!registry.betaMode());
    }
}
