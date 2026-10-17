// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeployUSD8SystemScript} from "../script/01_DeployUSD8System.s.sol";
import {DeployTimelockAndHandOffScript} from "../script/02_DeployTimelockAndHandOff.s.sol";
import {TimelockHandOff} from "../script/lib/TimelockHandOff.sol";
import {DeploymentConfig} from "../script/config/DeploymentConfig.sol";
import {Registry} from "../src/Registry.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {CreateXFixture} from "./utils/CreateXFixture.sol";
import {Create3Deployer, ICreateX} from "../script/lib/Create3Deployer.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";

contract DeployTimelockScriptHarness is DeployTimelockAndHandOffScript {
    function deployForTest(address proposer) external returns (TimelockController) {
        return _deployTimelock(address(this), proposer);
    }

    function predictTimelockForTest() external view returns (address) {
        return _predictCreate3(address(this), LABEL_TIMELOCK);
    }

    function create3SaltForTest(string memory label) external view returns (bytes32) {
        return _create3Salt(address(this), label);
    }
}

contract TrustedTreasuryBinding {
    USD8 public immutable usd8;
    Registry public immutable registry;

    constructor(USD8 usd8_, Registry registry_) {
        usd8 = usd8_;
        registry = registry_;
    }
}

contract ConfiguredDependencyMock {
    uint8 public decimals = 6;
    address public asset = address(this);
    uint256 public conversion = 1e18;
    int256 public answer = 1e8;

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function setAsset(address value) external {
        asset = value;
    }

    function setConversion(uint256 value) external {
        conversion = value;
    }

    function setAnswer(int256 value) external {
        answer = value;
    }

    function convertToAssets(uint256) external view returns (uint256) {
        return conversion;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function vaultV2(address owner, address, bytes32) external pure returns (address) {
        require(owner == address(1), "unstable probe owner");
        return address(0);
    }

    function isVaultV2(address) external pure returns (bool) {
        return false;
    }
}

contract NoSemanticInterfaces {}

/// @dev Runs both steps from one deployer address (step 01 + step 02 logic).
contract DeployUSD8SystemScriptHarness is DeployUSD8SystemScript, TimelockHandOff {
    function deployAndWireForTest(Addresses memory addresses) external returns (Deployed memory d) {
        d = _deployAndWire(address(this), addresses);
        _grantConfiguredAdmin(d, address(this), addresses.admin);
    }

    function handOffForTest(Registry registry, address beacon, address admin)
        external
        returns (TimelockController timelock)
    {
        _validateInterimAuthority(registry, beacon, address(this));
        timelock = _deployTimelock(address(this), admin);
        _validateTimelock(address(timelock), admin);
        _handOffToTimelock(registry, beacon, timelock, address(this), admin);
    }
    function validateConfiguredContractsForTest(Addresses memory addresses) external view {
        _validateConfiguredContracts(addresses);
    }

    function wstethUsdOracleForTest() external view returns (address) {
        return _deploymentConfig(1).wstethUsdOracle;
    }

    function validateForTest(address timelock, address proposer) external view {
        _validateTimelock(timelock, proposer);
    }

    function validateTreasuryBindingForTest(USD8 usd8, Registry registry, Treasury treasury) external view {
        _validateTreasuryBinding(usd8, registry, treasury);
    }

    function coreProtocolInsuredTokenConfigForTest(address usd8, address treasury, address usdcUsdOracle)
        external
        pure
        returns (InsuredTokenDeploymentConfig memory)
    {
        return _coreProtocolInsuredTokenConfig(usd8, treasury, usdcUsdOracle);
    }

    function addCoreProtocolInsuredTokenForTest(
        DefiInsurance defiInsurance,
        address usd8,
        address treasury,
        address usdcUsdOracle
    ) external {
        _addCoreProtocolInsuredToken(defiInsurance, usd8, treasury, usdcUsdOracle);
    }
}

contract DeploymentScriptsTest is Test {
    address proposer = makeAddr("proposer");

    function setUp() public {
        CreateXFixture.install();
    }

    // ───────────────────────────── CREATE3 ─────────────────────────────

    function test_TimelockLandsOnPredictedAddressIndependentOfChainAndArgs() public {
        DeployTimelockScriptHarness script = new DeployTimelockScriptHarness();
        address predicted = script.predictTimelockForTest();
        uint256 snapshot = vm.snapshotState();

        vm.chainId(1);
        address onMainnet = address(script.deployForTest(proposer));

        vm.revertToState(snapshot);
        vm.chainId(8453);
        address onOtherChain = address(script.deployForTest(makeAddr("other proposer")));

        assertEq(onMainnet, predicted, "mainnet address != prediction");
        assertEq(onOtherChain, predicted, "constructor args / chain id changed the address");
    }

    function test_Create3SaltCannotBeSquattedByAnotherSender() public {
        DeployTimelockScriptHarness script = new DeployTimelockScriptHarness();
        address predicted = script.predictTimelockForTest();
        bytes32 salt = script.create3SaltForTest("usd8.v1.TimelockController");

        // An attacker replaying our exact salt lands elsewhere: CreateX only honours the
        // deployer prefix for that deployer.
        vm.prank(makeAddr("attacker"));
        address squatted = ICreateX(CreateXFixture.CREATEX).deployCreate3(salt, type(NoSemanticInterfaces).creationCode);
        assertTrue(squatted != predicted, "attacker reached our address");

        assertEq(address(script.deployForTest(proposer)), predicted);
    }

    function test_Create3RevertsOnSecondDeploymentOfSameLabel() public {
        DeployTimelockScriptHarness script = new DeployTimelockScriptHarness();
        address predicted = address(script.deployForTest(proposer));

        vm.expectRevert(
            abi.encodeWithSelector(
                Create3Deployer.Create3AddressOccupied.selector, "usd8.v1.TimelockController", predicted
            )
        );
        script.deployForTest(proposer);
    }

    function test_Create3RequiresCreateX() public {
        DeployTimelockScriptHarness script = new DeployTimelockScriptHarness();
        vm.etch(CreateXFixture.CREATEX, "");

        vm.expectRevert(abi.encodeWithSelector(Create3Deployer.CreateXMissing.selector, CreateXFixture.CREATEX));
        script.deployForTest(proposer);
    }

    function test_FullSystemDeploymentHasSameAddressesOnEveryChain() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        uint256 snapshot = vm.snapshotState();

        vm.chainId(1);
        (DeployUSD8SystemScript.Deployed memory a, address usdcA, DeploymentConfig.Addresses memory cfgA) =
            _fullDeployment(script, proposer);
        TimelockController timelockA = script.handOffForTest(a.registry, a.poolBeacon, cfgA.admin);

        vm.revertToState(snapshot);
        vm.chainId(8453);
        // Different dependency addresses (USDC, feeds...) on the second chain.
        vm.setNonce(address(this), vm.getNonce(address(this)) + 1000);
        (DeployUSD8SystemScript.Deployed memory b, address usdcB, DeploymentConfig.Addresses memory cfgB) =
            _fullDeployment(script, proposer);
        address deployer = address(script);

        // ── After step 01: deployer holds interim governance, no timelock yet ──
        assertEq(b.registry.timelock(), deployer, "deployer is interim timelock");
        assertEq(UpgradeableBeacon(b.poolBeacon).owner(), deployer, "deployer is interim beacon owner");
        assertTrue(b.registry.isAdmin(proposer), "configured admin granted in step 01");
        assertTrue(b.registry.isAdmin(deployer), "deployer keeps admin until step 02");

        TimelockController timelockB = script.handOffForTest(b.registry, b.poolBeacon, cfgB.admin);

        assertTrue(usdcA != usdcB, "dependencies should differ between runs");
        _assertSame(script, deployer, "usd8.v1.TimelockController", address(timelockA), address(timelockB));
        _assertSame(script, deployer, "usd8.v1.Registry.impl", _impl(address(a.registry)), _impl(address(b.registry)));
        _assertSame(script, deployer, "usd8.v1.Registry.proxy", address(a.registry), address(b.registry));
        _assertSame(script, deployer, "usd8.v1.USD8.impl", a.usd8Impl, b.usd8Impl);
        _assertSame(script, deployer, "usd8.v1.USD8.proxy", address(a.usd8), address(b.usd8));
        _assertSame(script, deployer, "usd8.v1.Treasury.impl", a.treasuryImpl, b.treasuryImpl);
        _assertSame(script, deployer, "usd8.v1.Treasury.proxy", address(a.treasury), address(b.treasury));
        _assertSame(script, deployer, "usd8.v1.SingleAssetCoverPool.impl", a.poolImpl, b.poolImpl);
        _assertSame(script, deployer, "usd8.v1.SingleAssetCoverPool.beacon", a.poolBeacon, b.poolBeacon);
        _assertSame(script, deployer, "usd8.v1.SingleAssetCoverPool.wstETH", address(a.wstethPool), address(b.wstethPool));
        _assertSame(script, deployer, "usd8.v1.DefiInsurance.impl", a.defiInsuranceImpl, b.defiInsuranceImpl);
        _assertSame(script, deployer, "usd8.v1.DefiInsurance.proxy", address(a.defiInsurance), address(b.defiInsurance));
        _assertSame(script, deployer, "usd8.v1.USD8PriceOracle", a.usd8PriceOracle, b.usd8PriceOracle);

        // ── After step 02: governance handed to the timelock ──
        assertEq(b.registry.timelock(), address(timelockB));
        assertEq(timelockB.getMinDelay(), 24 hours);
        assertTrue(timelockB.hasRole(timelockB.PROPOSER_ROLE(), proposer));
        assertTrue(b.registry.isAdmin(proposer));
        assertFalse(b.registry.isAdmin(deployer));
        assertEq(UpgradeableBeacon(b.poolBeacon).owner(), address(timelockB));
        assertEq(UpgradeableBeacon(b.poolBeacon).implementation(), b.poolImpl);

        // ── Launch scope ──
        assertEq(b.treasury.strategiesLength(), 0, "treasury launches with no strategies");
        assertEq(b.registry.usd8(), address(b.usd8));
        assertEq(b.registry.treasury(), address(b.treasury));
        assertEq(b.registry.defiInsurance(), address(b.defiInsurance));
        assertEq(address(b.treasury.USDC()), usdcB);
        assertEq(b.registry.savingsVault(), address(0), "sUSD8 is launched after deployment");
        (, address[] memory pools) = b.registry.coverPools();
        assertEq(pools.length, 1, "launch has a single cover pool");
        assertEq(pools[0], address(b.wstethPool));
        assertTrue(b.defiInsurance.isInsuredToken(IERC20(address(b.usd8))));
        assertGt(b.wstethPool.totalSupply(), 0);
    }

    /// @dev Mainnet layout: the deployer IS the configured admin. It must stay admin after hand-off.
    function test_HandOffKeepsDeployerAdminWhenDeployerIsConfiguredAdmin() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        address deployer = address(script);
        (DeployUSD8SystemScript.Deployed memory d,,) = _fullDeployment(script, deployer);

        TimelockController timelock = script.handOffForTest(d.registry, d.poolBeacon, deployer);

        assertEq(d.registry.timelock(), address(timelock));
        assertTrue(d.registry.isAdmin(deployer), "admin set must not be empty");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer));
        assertEq(UpgradeableBeacon(d.poolBeacon).owner(), address(timelock));
    }

    function test_HandOffCannotRunTwice() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        (DeployUSD8SystemScript.Deployed memory d,,) = _fullDeployment(script, proposer);
        TimelockController timelock = script.handOffForTest(d.registry, d.poolBeacon, proposer);

        vm.expectRevert(
            abi.encodeWithSelector(TimelockHandOff.NotInterimTimelock.selector, address(script), address(timelock))
        );
        script.handOffForTest(d.registry, d.poolBeacon, proposer);
    }

    function test_HandOffRequiresDeployedSystem() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        address registry = makeAddr("missing registry");

        vm.expectRevert(abi.encodeWithSelector(TimelockHandOff.SystemNotDeployed.selector, bytes32("registry"), registry));
        script.handOffForTest(Registry(registry), makeAddr("missing beacon"), proposer);
    }

    function test_InterimDeployerCanConfigureWithoutDelay() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        (DeployUSD8SystemScript.Deployed memory d,,) = _fullDeployment(script, proposer);
        address token = address(new MockERC20("Extra", "EXT", 18));
        address feed = _feed();
        ConfiguredDependencyMock conversion = new ConfiguredDependencyMock();

        // Before step 02 the deployer is the Registry timelock, so timelock-only setters apply immediately.
        vm.prank(address(script));
        d.defiInsurance.editInsuredToken(
            IERC20(token), 5000, feed, address(conversion), abi.encodeCall(IERC4626.convertToAssets, (1e18))
        );
        assertTrue(d.defiInsurance.isInsuredToken(IERC20(token)));
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
    }

    function _assertSame(
        DeployUSD8SystemScriptHarness script,
        address deployer,
        string memory label,
        address first,
        address second
    ) internal view {
        assertEq(first, second, string.concat(label, ": address differs across chains"));
        assertEq(first, script.predictedAddress(deployer, label), string.concat(label, ": not at predicted address"));
    }

    function _fullDeployment(DeployUSD8SystemScriptHarness script, address admin)
        internal
        returns (DeployUSD8SystemScript.Deployed memory d, address usdc, DeploymentConfig.Addresses memory a)
    {
        a = _mockDependencies();
        a.admin = admin;
        usdc = a.usdc;
        MockERC20(a.wsteth).mint(address(script), script.COVER_POOL_SEED());
        d = script.deployAndWireForTest(a);
    }

    function _mockDependencies() internal returns (DeploymentConfig.Addresses memory a) {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        a.admin = proposer;
        a.usdc = address(usdc);
        a.seedSink = address(0xdead);
        a.booster = address(new NoSemanticInterfaces());
        a.wsteth = address(new MockERC20("Wrapped stETH", "wstETH", 18));
        a.wstethUsdOracle = _feed();
        a.usdcUsdOracle = _feed();
    }

    function _feed() internal returns (address) {
        ConfiguredDependencyMock feed = new ConfiguredDependencyMock();
        feed.setDecimals(8);
        return address(feed);
    }

    function _deployConfiguredTreasury(Registry registry) internal returns (Treasury) {
        MockERC20 reserveAsset = new MockERC20("Configured USDC", "cUSDC", 6);
        return Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()),
                    abi.encodeCall(Treasury.initialize, (registry, IERC20(address(reserveAsset))))
                )
            )
        );
    }

    function _validConfiguredAddresses()
        internal
        returns (DeploymentConfig.Addresses memory addresses, ConfiguredDependencyMock dependency)
    {
        dependency = new ConfiguredDependencyMock();
        address configured = address(dependency);
        addresses = DeploymentConfig.Addresses({
            admin: proposer,
            usdc: configured,
            seedSink: address(0xdead),
            booster: configured,
            wsteth: configured,
            wstethUsdOracle: configured,
            usdcUsdOracle: configured
        });
    }

    function _semanticError(bytes32 field, address candidate) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("InvalidConfiguredDependency(bytes32,address)", field, candidate);
    }

    function test_SystemDeploymentRunTakesNoTimelockParameter() public pure {
        assertEq(DeployUSD8SystemScript.run.selector, bytes4(keccak256("run()")));
        assertEq(DeployTimelockAndHandOffScript.run.selector, bytes4(keccak256("run()")));
    }

    function test_SystemDeploymentRejectsConfiguredAddressWithoutCode() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        (DeploymentConfig.Addresses memory addresses,) = _validConfiguredAddresses();
        address missingCode = makeAddr("missing cover asset");
        addresses.wsteth = missingCode;

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployUSD8SystemScript.InvalidConfiguredContract.selector, bytes32("wsteth"), missingCode
            )
        );
        script.validateConfiguredContractsForTest(addresses);
    }

    function test_SystemDeploymentRejectsWrongReserveDecimalsBeforeBroadcast() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        (DeploymentConfig.Addresses memory addresses, ConfiguredDependencyMock dependency) = _validConfiguredAddresses();
        dependency.setDecimals(18);

        vm.expectRevert(_semanticError("usdc", address(dependency)));
        script.validateConfiguredContractsForTest(addresses);
    }

    function test_SystemDeploymentRejectsNonPositiveOracleBeforeBroadcast() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        (DeploymentConfig.Addresses memory addresses, ConfiguredDependencyMock dependency) = _validConfiguredAddresses();
        dependency.setAnswer(0);

        vm.expectRevert(_semanticError("wstethUsdOracle", address(dependency)));
        script.validateConfiguredContractsForTest(addresses);
    }

    function test_SystemDeploymentPreflightAcceptsValidConfiguredAddresses() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        (DeploymentConfig.Addresses memory addresses,) = _validConfiguredAddresses();

        script.validateConfiguredContractsForTest(addresses);
    }

    function test_SystemDeploymentUsesCanonicalWstethUsdOracle() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        assertEq(script.wstethUsdOracleForTest(), 0x164b276057258d81941e97B0a900D4C7B358bCe0);
    }

    function _deployCustomTimelock(uint256 delay, address proposer_, bool openExecutor, address externalAdmin)
        internal
        returns (TimelockController timelock)
    {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer_;
        address[] memory executors = new address[](1);
        executors[0] = openExecutor ? address(0) : proposer_;
        timelock = new TimelockController(delay, proposers, executors, externalAdmin);
    }

    function test_StandaloneTimelockHasExpectedGovernanceRoles() public {
        DeployTimelockScriptHarness script = new DeployTimelockScriptHarness();
        TimelockController timelock = script.deployForTest(proposer);

        assertEq(timelock.getMinDelay(), 24 hours);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), proposer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(script)));
    }

    function test_SystemDeploymentAcceptsExpectedPredeployedTimelock() public {
        DeployTimelockScriptHarness timelockScript = new DeployTimelockScriptHarness();
        TimelockController timelock = timelockScript.deployForTest(proposer);
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentAcceptsMatchingTreasuryBinding() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        USD8 usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(usd8));
        Treasury treasury = _deployConfiguredTreasury(registry);

        script.validateTreasuryBindingForTest(usd8, registry, treasury);
    }

    function test_SystemDeploymentAcceptsTrustedNonProxyTreasuryBinding() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        USD8 usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        TrustedTreasuryBinding treasury = new TrustedTreasuryBinding(usd8, registry);

        script.validateTreasuryBindingForTest(usd8, registry, Treasury(address(treasury)));
    }

    function test_SystemDeploymentRejectsTreasuryBoundToAnotherUsd8() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        USD8 expectedUsd8 =
            USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        USD8 otherUsd8 =
            USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(otherUsd8));
        Treasury treasury = _deployConfiguredTreasury(registry);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployUSD8SystemScript.InvalidTreasuryBinding.selector,
                address(treasury),
                address(otherUsd8),
                address(registry)
            )
        );
        script.validateTreasuryBindingForTest(expectedUsd8, registry, treasury);
    }

    function test_SystemDeploymentRejectsTreasuryAddressWithoutCode() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        address noCode = makeAddr("treasury without code");

        vm.expectRevert();
        script.validateTreasuryBindingForTest(USD8(address(1)), Registry(address(2)), Treasury(noCode));
    }

    function test_SystemDeploymentRejectsTimelockWithoutExpectedProposer() public {
        DeployTimelockScriptHarness timelockScript = new DeployTimelockScriptHarness();
        TimelockController timelock = timelockScript.deployForTest(makeAddr("wrong proposer"));
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockHandOff.MissingTimelockRole.selector, timelock.PROPOSER_ROLE(), proposer
            )
        );
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentRejectsAddressWithoutCode() public {
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();
        address noCode = makeAddr("no code");

        vm.expectRevert();
        systemScript.validateForTest(noCode, proposer);
    }

    function test_SystemDeploymentRejectsWrongTimelockDelay() public {
        TimelockController timelock = _deployCustomTimelock(12 hours, proposer, true, address(0));
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockHandOff.InvalidTimelockDelay.selector, uint256(12 hours), uint256(24 hours)
            )
        );
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentRejectsMissingCanceller() public {
        TimelockController timelock = _deployCustomTimelock(24 hours, proposer, true, address(0));
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        vm.prank(address(timelock));
        timelock.revokeRole(cancellerRole, proposer);
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(
            abi.encodeWithSelector(TimelockHandOff.MissingTimelockRole.selector, cancellerRole, proposer)
        );
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentRejectsClosedExecutor() public {
        TimelockController timelock = _deployCustomTimelock(24 hours, proposer, false, address(0));
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockHandOff.MissingTimelockRole.selector, timelock.EXECUTOR_ROLE(), address(0)
            )
        );
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentRejectsMissingSelfAdmin() public {
        TimelockController timelock = _deployCustomTimelock(24 hours, proposer, true, address(0));
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(address(timelock));
        timelock.revokeRole(adminRole, address(timelock));
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(
            abi.encodeWithSelector(TimelockHandOff.MissingTimelockRole.selector, adminRole, address(timelock))
        );
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentRejectsExternalTimelockAdmin() public {
        TimelockController timelock = _deployCustomTimelock(24 hours, proposer, true, proposer);
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(abi.encodeWithSelector(TimelockHandOff.UnexpectedTimelockAdmin.selector, proposer));
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_TimelockDeploymentRevertsOnUnsupportedChain() public {
        vm.chainId(31_337);
        DeployTimelockAndHandOffScript script = new DeployTimelockAndHandOffScript();

        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.UnsupportedChain.selector, uint256(31_337)));
        script.run();
    }

    function test_SystemDeploymentRevertsOnUnsupportedChain() public {
        vm.chainId(31_337);
        DeployUSD8SystemScript script = new DeployUSD8SystemScript();

        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.UnsupportedChain.selector, uint256(31_337)));
        script.run();
    }

    function test_CoreProtocolInsuredTokenConfiguration() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        address usd8 = makeAddr("USD8");
        address treasury = makeAddr("Treasury");
        address usdcUsdOracle = makeAddr("USDC/USD oracle");
        DeployUSD8SystemScript.InsuredTokenDeploymentConfig memory config =
            script.coreProtocolInsuredTokenConfigForTest(usd8, treasury, usdcUsdOracle);

        assertEq(config.token, usd8);
        assertEq(config.maxCoverageBps, 8000);
        assertEq(config.underlyingPriceOracle, usdcUsdOracle);
        assertEq(config.conversionAddress, treasury);
        assertEq(config.conversionCallData, abi.encodeCall(Treasury.usd8ToUsdcRate, ()));

        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(script), address(this)))
                )
            )
        );
        DefiInsurance defiInsurance = DefiInsurance(
            address(
                new ERC1967Proxy(address(new DefiInsurance()), abi.encodeCall(DefiInsurance.initialize, (registry)))
            )
        );
        script.addCoreProtocolInsuredTokenForTest(defiInsurance, usd8, treasury, usdcUsdOracle);

        assertTrue(defiInsurance.isInsuredToken(IERC20(usd8)));
        DefiInsurance.InsuredToken memory stored = defiInsurance.getInsuredToken(IERC20(usd8));
        assertEq(stored.maxCoverageBps, config.maxCoverageBps);
        assertEq(stored.underlyingPriceOracle, config.underlyingPriceOracle);
        assertEq(stored.underlyingConversionAddress, config.conversionAddress);
        assertEq(stored.underlyingConversionCallData, config.conversionCallData);
    }
}
