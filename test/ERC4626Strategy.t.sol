// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {StrategyBase} from "../src/strategies/StrategyBase.sol";
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

contract MockSwapRouter {
    using SafeERC20 for IERC20;

    function swap(IERC20 tokenIn, uint256 amountIn, MockERC20 tokenOut, uint256 amountOut, address recipient) external {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.mint(recipient, amountOut);
    }
}

contract MockUsdtStrategy is StrategyBase {
    constructor(address treasury_, Registry registry_, IERC20 strategyToken_)
        StrategyBase(treasury_, registry_, strategyToken_)
    {}

    function _principalBalance() internal pure override returns (uint256) {
        return 0;
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

    function test_AdminCanSwapRewardToUSDCAndSendItToTreasury() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        MockSwapRouter router = new MockSwapRouter();

        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(router), address(router), true);

        uint256 amountIn = 10e18;
        uint256 amountOut = 25e6;
        reward.mint(address(strategy), amountIn);
        bytes memory route = abi.encodeCall(
            MockSwapRouter.swap, (IERC20(address(reward)), amountIn, usdc, amountOut, address(strategy))
        );

        vm.prank(ADMIN);
        uint256 received = strategy.swap(
            IERC20(address(reward)), IERC20(address(usdc)), amountIn, address(router), address(router), route, amountOut
        );

        assertEq(received, amountOut);
        assertEq(usdc.balanceOf(TREASURY), amountOut);
        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertEq(reward.allowance(address(strategy), address(router)), 0);
    }

    function test_AdminCanSwapUSDCToStrategyTokenAndKeepOutputInStrategy() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        MockUsdtStrategy strategy = new MockUsdtStrategy(TREASURY, registry, usdt);
        MockSwapRouter router = new MockSwapRouter();
        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(router), address(router), true);

        uint256 amount = 100e6;
        usdc.mint(address(strategy), amount);
        bytes memory route =
            abi.encodeCall(MockSwapRouter.swap, (IERC20(address(usdc)), amount, usdt, amount, address(strategy)));

        vm.prank(ADMIN);
        uint256 received = strategy.swap(
            IERC20(address(usdc)), IERC20(address(usdt)), amount, address(router), address(router), route, amount
        );

        assertEq(received, amount);
        assertEq(usdt.balanceOf(address(strategy)), amount);
        assertEq(usdt.balanceOf(TREASURY), 0);
        assertEq(usdc.balanceOf(TREASURY), 0);
        assertEq(usdc.allowance(address(strategy), address(router)), 0);
    }

    function test_AdminCanSwapStrategyTokenToUSDCAndSendOutputToTreasury() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        MockUsdtStrategy strategy = new MockUsdtStrategy(TREASURY, registry, usdt);
        MockSwapRouter router = new MockSwapRouter();
        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(router), address(router), true);

        uint256 amount = 100e6;
        usdt.mint(address(strategy), amount);
        bytes memory route =
            abi.encodeCall(MockSwapRouter.swap, (IERC20(address(usdt)), amount, usdc, amount, address(strategy)));

        vm.prank(ADMIN);
        uint256 received = strategy.swap(
            IERC20(address(usdt)), IERC20(address(usdc)), amount, address(router), address(router), route, amount
        );

        assertEq(received, amount);
        assertEq(usdc.balanceOf(TREASURY), amount);
        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertEq(usdt.allowance(address(strategy), address(router)), 0);
    }

    function test_RewardTokenCannotBeSwappedToStrategyToken() public {
        MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        MockUsdtStrategy strategy = new MockUsdtStrategy(TREASURY, registry, usdt);
        MockSwapRouter router = new MockSwapRouter();
        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(router), address(router), true);

        vm.expectRevert(
            abi.encodeWithSelector(StrategyBase.UnsupportedSwapPair.selector, address(reward), address(usdt))
        );
        vm.prank(ADMIN);
        strategy.swap(IERC20(address(reward)), IERC20(address(usdt)), 1, address(router), address(router), "", 1);
    }

    function test_TimelockCanSwapRewardToUSDC() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        MockSwapRouter router = new MockSwapRouter();
        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(router), address(router), true);

        reward.mint(address(strategy), 1e18);
        bytes memory route =
            abi.encodeCall(MockSwapRouter.swap, (IERC20(address(reward)), 1e18, usdc, 2e6, address(strategy)));

        vm.prank(TIMELOCK);
        strategy.swap(
            IERC20(address(reward)), IERC20(address(usdc)), 1e18, address(router), address(router), route, 2e6
        );

        assertEq(usdc.balanceOf(TREASURY), 2e6);
    }

    function test_UnauthorizedCallerCannotSwap() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        MockSwapRouter router = new MockSwapRouter();

        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, address(this)));
        strategy.swap(IERC20(address(reward)), IERC20(address(usdc)), 1, address(router), address(router), "", 1);
    }

    function test_AdminCannotApproveSwapRoute() public {
        MockSwapRouter router = new MockSwapRouter();

        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, ADMIN));
        vm.prank(ADMIN);
        registry.setSwapRoute(address(router), address(router), true);
    }

    function test_UnapprovedSwapRouteReverts() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        MockSwapRouter router = new MockSwapRouter();

        vm.expectRevert(
            abi.encodeWithSelector(StrategyBase.SwapRouteNotApproved.selector, address(router), address(router))
        );
        vm.prank(ADMIN);
        strategy.swap(IERC20(address(reward)), IERC20(address(usdc)), 1, address(router), address(router), "", 1);
    }

    function test_SameTokenSwapReverts() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);
        MockSwapRouter router = new MockSwapRouter();
        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(router), address(router), true);

        vm.expectRevert(abi.encodeWithSelector(StrategyBase.UnsupportedSwapPair.selector, MAINNET_USDC, MAINNET_USDC));
        vm.prank(ADMIN);
        strategy.swap(IERC20(MAINNET_USDC), IERC20(MAINNET_USDC), 1, address(router), address(router), "", 1);
    }

    function test_VaultCannotBeCalledAsSwapTarget() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(vault), address(vault), true);

        vm.expectRevert(abi.encodeWithSelector(StrategyBase.ProtectedSwapAsset.selector, address(vault)));
        vm.prank(ADMIN);
        strategy.swap(IERC20(address(reward)), IERC20(address(usdc)), 1, address(vault), address(vault), "", 1);
    }

    function test_MinimumOutputFailureRevertsSwapAndApproval() public {
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(TREASURY, registry, vault);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        MockSwapRouter router = new MockSwapRouter();
        vm.prank(TIMELOCK);
        registry.setSwapRoute(address(router), address(router), true);

        reward.mint(address(strategy), 1e18);
        bytes memory route =
            abi.encodeCall(MockSwapRouter.swap, (IERC20(address(reward)), 1e18, usdc, 2e6, address(strategy)));

        vm.expectRevert(abi.encodeWithSelector(StrategyBase.InsufficientSwapOutput.selector, 3e6, 2e6));
        vm.prank(ADMIN);
        strategy.swap(
            IERC20(address(reward)), IERC20(address(usdc)), 1e18, address(router), address(router), route, 3e6
        );

        assertEq(reward.balanceOf(address(strategy)), 1e18);
        assertEq(reward.allowance(address(strategy), address(router)), 0);
        assertEq(usdc.balanceOf(TREASURY), 0);
    }
}
