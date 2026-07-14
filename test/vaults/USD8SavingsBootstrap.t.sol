// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";
import {USD8SavingsBootstrap} from "../../src/deployment/USD8SavingsBootstrap.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract USD8SavingsBootstrapTest is Test {
    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant GOVERNANCE = address(0xBEEF);
    address constant SEED_SINK = address(0xdead);
    uint256 constant SEED_USDC = 100e6;
    uint256 constant MAX_RATE = 20e16 / uint256(365 days);

    Registry registry;
    USD8 usd8;
    Treasury treasury;
    MockERC20 usdc;
    VaultV2Factory vaultFactory;

    function setUp() public {
        MockERC20 usdcTemplate = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(usdcTemplate).code);
        usdc = MockERC20(USDC_ADDR);

        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        usd8 = USD8(
            address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry, address(this)))))
        );
        treasury = Treasury(
            address(new ERC1967Proxy(address(new Treasury()), abi.encodeCall(Treasury.initialize, (usd8, registry))))
        );
        usd8.setTreasury(address(treasury));
        vaultFactory = new VaultV2Factory();
    }

    function _bootstrap() internal returns (USD8SavingsBootstrap.Deployment memory d) {
        USD8SavingsBootstrap bootstrap = new USD8SavingsBootstrap();
        usdc.mint(address(bootstrap), SEED_USDC);
        d = bootstrap.run(
            USD8SavingsBootstrap.Config({
                vaultFactory: address(vaultFactory),
                registry: registry,
                usd8: usd8,
                treasury: treasury,
                seedUsdc: SEED_USDC,
                seedSink: SEED_SINK,
                governance: GOVERNANCE,
                maxRate: MAX_RATE,
                salt: keccak256("sUSD8")
            })
        );
    }

    /// forge-config: default.isolate = true
    function test_AtomicallyCreatesConfiguresAndSeedsCanonicalMorphoVault() public {
        USD8SavingsBootstrap.Deployment memory d = _bootstrap();
        IVaultV2 vault = IVaultV2(d.vault);
        USD8SavingsAdapter adapter = USD8SavingsAdapter(d.adapter);

        assertTrue(vaultFactory.isVaultV2(d.vault));
        assertEq(vault.asset(), address(usd8));
        assertEq(vault.name(), "Savings USD8");
        assertEq(vault.symbol(), "sUSD8");
        assertEq(vault.owner(), GOVERNANCE);
        assertEq(vault.curator(), GOVERNANCE);
        assertTrue(vault.isAllocator(GOVERNANCE));
        assertFalse(vault.isAllocator(d.bootstrap));
        assertEq(vault.liquidityAdapter(), d.adapter);
        assertEq(vault.maxRate(), MAX_RATE);
        assertEq(vault.performanceFee(), 0);
        assertEq(vault.managementFee(), 0);
        assertEq(vault.balanceOf(SEED_SINK), SEED_USDC * treasury.USDC_TO_USD8_SCALE());
        assertEq(usd8.balanceOf(d.adapter), SEED_USDC * treasury.USDC_TO_USD8_SCALE());
        assertEq(adapter.realAssets(), SEED_USDC * treasury.USDC_TO_USD8_SCALE());
        assertEq(vault.sendAssetsGate(), d.gate);
        assertEq(vault.receiveAssetsGate(), d.gate);
        assertEq(vault.sendSharesGate(), d.gate);
        assertEq(vault.receiveSharesGate(), d.gate);
    }

    /// forge-config: default.isolate = true
    function test_RegistryPauseGateBlocksAndRestoresVaultUserFlows() public {
        USD8SavingsBootstrap.Deployment memory d = _bootstrap();
        IVaultV2 vault = IVaultV2(d.vault);
        address alice = makeAddr("alice");

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 10e6);
        treasury.mintUSD8(10e6);
        usd8.approve(d.vault, 10e18);
        uint256 shares = vault.deposit(10e18, alice);
        vm.stopPrank();

        registry.setPaused(d.vault, true);
        vm.startPrank(alice);
        vm.expectRevert();
        vault.deposit(1, alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        registry.setPaused(d.vault, false);
        vm.prank(alice);
        assertGt(vault.redeem(shares, alice, alice), 0);
    }
}
