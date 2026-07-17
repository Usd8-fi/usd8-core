// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DeployTimelockScript} from "../script/01_DeployTimelock.s.sol";
import {DeployUSD8SystemScript} from "../script/02_DeployUSD8System.s.sol";
import {Registry} from "../src/Registry.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployTimelockScriptHarness is DeployTimelockScript {
    function deployForTest(address proposer) external returns (TimelockController) {
        return _deployTimelock(proposer);
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

contract DeployUSD8SystemScriptHarness is DeployUSD8SystemScript {
    function validateForTest(address timelock, address proposer) external view {
        _validateTimelock(timelock, proposer);
    }

    function validateTreasuryBindingForTest(USD8 usd8, Registry registry, Treasury treasury) external view {
        _validateTreasuryBinding(usd8, registry, treasury);
    }

    function insuredTokenConfigsForTest() external pure returns (InsuredTokenDeploymentConfig[3] memory) {
        return _initialInsuredTokenConfigs();
    }

    function addInitialInsuredTokensForTest(DefiInsurance defiInsurance) external {
        _addInitialInsuredTokens(defiInsurance);
    }

    function protocolInsuredTokenConfigsForTest(address usd8, address savings, address usd8PriceOracle)
        external
        pure
        returns (InsuredTokenDeploymentConfig[2] memory)
    {
        return _protocolInsuredTokenConfigs(usd8, savings, usd8PriceOracle);
    }

    function addProtocolInsuredTokensForTest(
        DefiInsurance defiInsurance,
        address usd8,
        address savings,
        address usd8PriceOracle
    ) external {
        _addProtocolInsuredTokens(defiInsurance, usd8, savings, usd8PriceOracle);
    }
}

contract DeploymentScriptsTest is Test {
    address proposer = makeAddr("proposer");

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
        Treasury treasury = Treasury(
            address(new ERC1967Proxy(address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry))))
        );

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
        Treasury treasury = Treasury(
            address(new ERC1967Proxy(address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry))))
        );

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
                DeployUSD8SystemScript.MissingTimelockRole.selector, timelock.PROPOSER_ROLE(), proposer
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
                DeployUSD8SystemScript.InvalidTimelockDelay.selector, uint256(12 hours), uint256(24 hours)
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
            abi.encodeWithSelector(DeployUSD8SystemScript.MissingTimelockRole.selector, cancellerRole, proposer)
        );
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentRejectsClosedExecutor() public {
        TimelockController timelock = _deployCustomTimelock(24 hours, proposer, false, address(0));
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployUSD8SystemScript.MissingTimelockRole.selector, timelock.EXECUTOR_ROLE(), address(0)
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
            abi.encodeWithSelector(DeployUSD8SystemScript.MissingTimelockRole.selector, adminRole, address(timelock))
        );
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_SystemDeploymentRejectsExternalTimelockAdmin() public {
        TimelockController timelock = _deployCustomTimelock(24 hours, proposer, true, proposer);
        DeployUSD8SystemScriptHarness systemScript = new DeployUSD8SystemScriptHarness();

        vm.expectRevert(abi.encodeWithSelector(DeployUSD8SystemScript.UnexpectedTimelockAdmin.selector, proposer));
        systemScript.validateForTest(address(timelock), proposer);
    }

    function test_TimelockDeploymentRevertsOutsideEthereumMainnet() public {
        vm.chainId(31_337);
        DeployTimelockScript script = new DeployTimelockScript();

        vm.expectRevert(abi.encodeWithSignature("WrongChainId(uint256,uint256)", uint256(31_337), uint256(1)));
        script.run();
    }

    function test_SystemDeploymentRevertsOutsideEthereumMainnet() public {
        vm.chainId(31_337);
        DeployUSD8SystemScript script = new DeployUSD8SystemScript();

        vm.expectRevert(abi.encodeWithSignature("WrongChainId(uint256,uint256)", uint256(31_337), uint256(1)));
        script.run();
    }

    function test_InitialSavingsProfitWeightIsZero() public {
        DeployUSD8SystemScript script = new DeployUSD8SystemScript();
        assertEq(script.INITIAL_SAVINGS_PROFIT_WEIGHT(), 0, "dead seed shares must not receive launch revenue");
    }

    function test_InitialInsuredTokenConfigurations() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        DeployUSD8SystemScript.InsuredTokenDeploymentConfig[3] memory configs = script.insuredTokenConfigsForTest();
        bytes memory conversionCallData = abi.encodeCall(IERC4626.convertToAssets, (1e18));

        assertEq(configs[0].token, 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d, "new ERC-4626 sGHO");
        assertEq(configs[0].maxCoverageBps, 8000);
        assertEq(configs[0].underlyingPriceOracle, 0xff221Bf2E61B62182210b3d42dE7f77da5b5b41F);

        assertEq(configs[1].token, 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367, "scrvUSD");
        assertEq(configs[1].maxCoverageBps, 7000);
        assertEq(configs[1].underlyingPriceOracle, 0xf3A0a2363Ee3e5FC1CcF923F4eA9c06BaC1A6834);

        assertEq(configs[2].token, 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD, "sUSDS");
        assertEq(configs[2].maxCoverageBps, 7000);
        assertEq(configs[2].underlyingPriceOracle, 0x592700e4FcDd674dC54d2681DED3B63f54F63f9A);

        for (uint256 i; i < configs.length; ++i) {
            assertEq(configs[i].minClaimAmount, 1e18);
            assertEq(configs[i].conversionAddress, configs[i].token);
            assertEq(configs[i].conversionCallData, conversionCallData);
        }
    }

    function test_DeploymentAddsInitialInsuredTokens() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(script), address(this)))
                )
            )
        );
        DefiInsurance defiInsurance = new DefiInsurance(registry);
        DeployUSD8SystemScript.InsuredTokenDeploymentConfig[3] memory expected = script.insuredTokenConfigsForTest();
        for (uint256 i; i < expected.length; ++i) {
            vm.mockCall(expected[i].conversionAddress, expected[i].conversionCallData, abi.encode(1e18));
        }

        script.addInitialInsuredTokensForTest(defiInsurance);

        assertEq(defiInsurance.insuredTokenListLength(), 3);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(address(defiInsurance.insuredTokenList(i)), expected[i].token);
            DefiInsurance.InsuredToken memory stored = defiInsurance.getInsuredToken(IERC20(expected[i].token));
            assertEq(stored.maxCoverageBps, expected[i].maxCoverageBps);
            assertEq(stored.minClaimAmount, expected[i].minClaimAmount);
            assertEq(stored.underlyingPriceOracle, expected[i].underlyingPriceOracle);
            assertEq(stored.underlyingConversionAddress, expected[i].conversionAddress);
            assertEq(stored.underlyingConversionCallData, expected[i].conversionCallData);
        }
    }

    function test_ProtocolInsuredTokenConfigurationsAndWiring() public {
        DeployUSD8SystemScriptHarness script = new DeployUSD8SystemScriptHarness();
        address usd8 = makeAddr("USD8");
        address savings = makeAddr("sUSD8");
        address usd8PriceOracle = makeAddr("USD8/USD oracle");
        DeployUSD8SystemScript.InsuredTokenDeploymentConfig[2] memory configs =
            script.protocolInsuredTokenConfigsForTest(usd8, savings, usd8PriceOracle);

        assertEq(configs[0].token, usd8);
        assertEq(configs[0].maxCoverageBps, 8000);
        assertEq(configs[0].minClaimAmount, 1e18);
        assertEq(configs[0].underlyingPriceOracle, usd8PriceOracle);
        assertEq(configs[0].conversionAddress, address(0));
        assertEq(configs[0].conversionCallData, bytes(""));

        assertEq(configs[1].token, savings);
        assertEq(configs[1].maxCoverageBps, 8000);
        assertEq(configs[1].minClaimAmount, 1e18);
        assertEq(configs[1].underlyingPriceOracle, usd8PriceOracle);
        assertEq(configs[1].conversionAddress, savings);
        assertEq(configs[1].conversionCallData, abi.encodeCall(IERC4626.convertToAssets, (1e18)));

        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(script), address(this)))
                )
            )
        );
        DefiInsurance defiInsurance = new DefiInsurance(registry);
        vm.mockCall(savings, configs[1].conversionCallData, abi.encode(1e18));
        script.addProtocolInsuredTokensForTest(defiInsurance, usd8, savings, usd8PriceOracle);

        assertEq(defiInsurance.insuredTokenListLength(), 2);
        for (uint256 i; i < configs.length; ++i) {
            DefiInsurance.InsuredToken memory stored = defiInsurance.getInsuredToken(IERC20(configs[i].token));
            assertEq(stored.maxCoverageBps, configs[i].maxCoverageBps);
            assertEq(stored.minClaimAmount, configs[i].minClaimAmount);
            assertEq(stored.underlyingPriceOracle, configs[i].underlyingPriceOracle);
            assertEq(stored.underlyingConversionAddress, configs[i].conversionAddress);
            assertEq(stored.underlyingConversionCallData, configs[i].conversionCallData);
        }
    }
}
