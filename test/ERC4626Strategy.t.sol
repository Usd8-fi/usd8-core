// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";

import {Registry} from "../src/Registry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ZeroShareVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Bad Vault", "BAD") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function deposit(uint256 assets, address) public override returns (uint256 shares) {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        return 0;
    }
}

/// @dev Vault whose share price is a fixed, high rate. Deposits round down by
///      up to one share's value, exercising share-granularity rounding.
contract AppreciatedVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public constant RATE = 1000;

    constructor(IERC20 asset_) ERC20("Appreciated", "APR") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = assets / RATE;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function convertToAssets(uint256 shares) public pure override returns (uint256) {
        return shares * RATE;
    }
}

/// @dev Vault that removes a deposit fee, leaving the depositor's position
///      materially short of the supplied assets.
contract FeeSkimVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Fee Vault", "FEE") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        IERC20(asset()).safeTransfer(address(0xFEE), assets / 10);
    }
}

/// @dev Vault whose asset-denominated withdrawal burns one extra share while
///      share-denominated redemption follows standard ERC-4626 semantics.
contract WithdrawalFeeVault is ERC20, ERC4626 {
    constructor(IERC20 asset_) ERC20("Withdrawal Fee Vault", "WFEE") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares + 1);
    }
}

contract MockTreasuryReserveAsset {
    IERC20 public immutable USDC;

    constructor(IERC20 usdc_) {
        USDC = usdc_;
    }
}

contract ERC4626StrategyTest is Test {
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant TREASURY = address(0xBEEF);
    address constant TIMELOCK = address(0xA11CE);
    address constant ADMIN = address(0xAD);

    MockERC20 usdc;
    Registry registry;

    function setUp() public {
        MockERC20 template = new MockERC20("USDC", "USDC", 6);
        vm.etch(MAINNET_USDC, address(template).code);
        usdc = MockERC20(MAINNET_USDC);
        MockTreasuryReserveAsset treasuryTemplate = new MockTreasuryReserveAsset(IERC20(MAINNET_USDC));
        vm.etch(TREASURY, address(treasuryTemplate).code);

        Registry implementation = new Registry();
        registry = Registry(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(Registry.initialize, (TIMELOCK, ADMIN))))
        );
    }

    function test_ZeroShareDepositReverts() public {
        ZeroShareVault vault = new ZeroShareVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);

        usdc.mint(address(strategy), 100e6);
        vm.prank(TREASURY);
        vm.expectRevert(ERC4626Strategy.ZeroSharesMinted.selector);
        strategy.deploy(100e6);
    }

    function test_AppreciatedVaultDepositDoesNotFalselyRevert() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);

        uint256 amount = 100_000_000 + 7;
        usdc.mint(address(strategy), amount);
        vm.prank(TREASURY);
        strategy.deploy(amount);

        assertEq(strategy.totalAssets(), 100_000_000, "position value reflects share rounding");
    }

    function test_ValueShortDepositReverts() public {
        FeeSkimVault vault = new FeeSkimVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);

        usdc.mint(address(strategy), 100e6);
        vm.prank(TREASURY);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Strategy.DepositValueShort.selector, 100e6, 90e6));
        strategy.deploy(100e6);
    }

    function test_WithdrawBurnsExactlyPreviewedShares() public {
        WithdrawalFeeVault vault = new WithdrawalFeeVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);

        usdc.mint(address(strategy), 100e6);
        vm.prank(TREASURY);
        strategy.deploy(100e6);

        uint256 amount = 50e6;
        uint256 expectedShares = vault.previewWithdraw(amount);
        uint256 sharesBefore = vault.balanceOf(address(strategy));

        vm.prank(TREASURY);
        strategy.withdraw(amount);

        assertEq(sharesBefore - vault.balanceOf(address(strategy)), expectedShares);
        assertGe(usdc.balanceOf(TREASURY), amount);
    }
}
