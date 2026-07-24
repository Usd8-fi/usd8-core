// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../../src/Registry.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StrategyInvariantVault is ERC20, ERC4626 {
    constructor(IERC20 asset_) ERC20("Invariant Vault", "ivUSDC") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

contract StrategyInvariantTreasury {
    IERC20 public immutable USDC;

    constructor(IERC20 usdc_) {
        USDC = usdc_;
    }

    function transferTo(IERC20 token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }

    function deployTo(ERC4626Strategy strategy, uint256 amount) external {
        strategy.deploy(amount);
    }

    function transferAndDeploy(ERC4626Strategy strategy, uint256 amount) external {
        USDC.transfer(address(strategy), amount);
        strategy.deploy(amount);
    }

    function withdrawFrom(ERC4626Strategy strategy, uint256 amount) external {
        strategy.withdraw(amount);
    }
}

contract ERC4626StrategyHandler is Test {
    MockERC20 public immutable usdc;
    StrategyInvariantVault public immutable vault;
    StrategyInvariantTreasury public immutable treasury;
    ERC4626Strategy public immutable strategy;

    uint256 public ghostMinted;
    uint256 public ghostDeployed;
    uint256 public ghostWithdrawn;
    uint256 public ghostYieldDonated;

    uint256 public successfulDeploys;
    uint256 public successfulWithdrawals;
    uint256 public successfulYieldDonations;
    uint256 public successfulZeroShareRejections;

    constructor(
        MockERC20 usdc_,
        StrategyInvariantVault vault_,
        StrategyInvariantTreasury treasury_,
        ERC4626Strategy strategy_
    ) {
        usdc = usdc_;
        vault = vault_;
        treasury = treasury_;
        strategy = strategy_;
    }

    function mintTreasury(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 1e24);
        usdc.mint(address(treasury), amount);
        ghostMinted += amount;
    }

    function deploy(uint256 amountSeed) external {
        uint256 balance = usdc.balanceOf(address(treasury));
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        if (vault.previewDeposit(amount) == 0) return;

        treasury.transferTo(usdc, address(strategy), amount);
        treasury.deployTo(strategy, amount);
        ghostDeployed += amount;
        successfulDeploys++;
    }

    function withdraw(uint256 amountSeed) external {
        uint256 available = vault.maxWithdraw(address(strategy));
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        treasury.withdrawFrom(strategy, amount);
        ghostWithdrawn += amount;
        successfulWithdrawals++;
    }

    function donateYield(uint256 amountSeed) external {
        if (vault.totalSupply() == 0) return;
        uint256 amount = bound(amountSeed, 0, 1e24);
        usdc.mint(address(vault), amount);
        ghostMinted += amount;
        ghostYieldDonated += amount;
        successfulYieldDonations++;
    }

    function zeroShareDeployRemainsAtomic() external {
        if (vault.totalSupply() != 0 || vault.totalAssets() != 0) return;
        usdc.mint(address(vault), 2);
        usdc.mint(address(treasury), 1);
        ghostMinted += 3;
        ghostYieldDonated += 2;
        assertEq(vault.previewDeposit(1), 0, "fixture did not reach zero-share branch");

        vm.expectRevert(ERC4626Strategy.ZeroSharesMinted.selector);
        treasury.transferAndDeploy(strategy, 1);
        successfulZeroShareRejections++;
    }
}

contract ERC4626StrategyInvariantTest is StdInvariant, Test {
    MockERC20 usdc;
    Registry registry;
    StrategyInvariantVault vault;
    StrategyInvariantTreasury treasury;
    ERC4626Strategy strategy;
    ERC4626StrategyHandler handler;

    address constant TIMELOCK = address(0xA11CE);
    address constant ADMIN = address(0xAD);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (TIMELOCK, ADMIN))))
        );
        vault = new StrategyInvariantVault(usdc);
        treasury = new StrategyInvariantTreasury(usdc);
        strategy = new ERC4626Strategy(address(treasury), registry, vault);
        handler = new ERC4626StrategyHandler(usdc, vault, treasury, strategy);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = ERC4626StrategyHandler.mintTreasury.selector;
        selectors[1] = ERC4626StrategyHandler.deploy.selector;
        selectors[2] = ERC4626StrategyHandler.withdraw.selector;
        selectors[3] = ERC4626StrategyHandler.donateYield.selector;
        selectors[4] = ERC4626StrategyHandler.zeroShareDeployRemainsAtomic.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_ProductiveStrategyBranchesAreReachable() public {
        handler.zeroShareDeployRemainsAtomic();
        handler.mintTreasury(1_000e6);
        handler.deploy(600e6);
        handler.donateYield(100e6);
        handler.withdraw(300e6);

        assertGt(handler.successfulDeploys(), 0);
        assertGt(handler.successfulYieldDonations(), 0);
        assertGt(handler.successfulWithdrawals(), 0);
        assertGt(handler.successfulZeroShareRejections(), 0);
    }

    function invariant_usdcSupplyIsFullyConserved() public view {
        uint256 accounted =
            usdc.balanceOf(address(treasury)) + usdc.balanceOf(address(strategy)) + usdc.balanceOf(address(vault));
        assertEq(usdc.totalSupply(), handler.ghostMinted(), "mint ghost drift");
        assertEq(accounted, usdc.totalSupply(), "USDC conservation");
    }

    function invariant_strategyNeverRetainsLooseUsdc() public view {
        assertEq(usdc.balanceOf(address(strategy)), 0, "loose strategy USDC");
    }

    /// @dev Closed-harness premise only: no external vault depositor is modeled.
    function invariant_closedHarnessHasNoExternalShareOwners() public view {
        assertEq(vault.balanceOf(address(strategy)), vault.totalSupply(), "unexpected vault-share holder");
        assertEq(
            strategy.totalAssets(), vault.convertToAssets(vault.balanceOf(address(strategy))), "position value drift"
        );
    }

    /// @dev Custodial mock-vault premise only; production vaults may deploy assets externally.
    function invariant_custodialMockVaultHasNoExternalPositions() public view {
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)), "vault accounting drift");
    }

    function invariant_treasuryFlowMatchesIndependentGhost() public view {
        uint256 inflows = handler.ghostMinted() + handler.ghostWithdrawn();
        uint256 outflows = handler.ghostDeployed() + handler.ghostYieldDonated();
        assertGe(inflows, outflows, "treasury ghost underflow");
        assertEq(usdc.balanceOf(address(treasury)), inflows - outflows, "treasury flow drift");
    }
}
