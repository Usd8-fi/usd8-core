// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../../src/Registry.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";

contract ERC4626StrategyHarnessToken is ERC20 {
    constructor() ERC20("Kontrol USDC", "kUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ERC4626StrategySwapRouter {
    using SafeERC20 for IERC20;

    bytes4 public callbackError;

    event RouterCalled(uint256 amountIn, uint256 amountOut);

    function swap(
        IERC20 tokenIn,
        uint256 amountIn,
        ERC4626StrategyHarnessToken tokenOut,
        uint256 amountOut,
        address recipient
    ) external {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.mint(recipient, amountOut);
        emit RouterCalled(amountIn, amountOut);
    }

    function outputOnly(ERC4626StrategyHarnessToken tokenOut, uint256 amountOut, address recipient) external {
        tokenOut.mint(recipient, amountOut);
    }

    function consumePositionAndOutput(
        IERC20 position,
        address owner,
        ERC4626StrategyHarnessToken tokenOut,
        uint256 amountOut,
        address recipient
    ) external {
        position.safeTransferFrom(owner, address(this), 1);
        tokenOut.mint(recipient, amountOut);
    }

    function reenterAndCatch(
        ERC4626Strategy strategy,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        ERC4626StrategyHarnessToken output,
        uint256 amountOut
    ) external {
        (bool success, bytes memory data) = address(strategy)
            .call(
                abi.encodeCall(
                    strategy.swap, (tokenIn, tokenOut, uint256(1), address(this), address(this), bytes(""), uint256(1))
                )
            );
        require(!success, "callback unexpectedly succeeded");
        if (data.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(data, 0x20))
            }
            callbackError = selector;
        }
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        output.mint(address(strategy), amountOut);
    }

    function revertRoute() external pure {
        revert("ROUTE_REVERT");
    }
}

contract ERC4626StrategyRejectETH {
    receive() external payable {
        revert("NO_ETH");
    }
}

contract ERC4626StrategyLogReceiver {
    event Received(uint256 amount);

    receive() external payable {
        emit Received(msg.value);
    }
}

contract ERC4626StrategyHarnessTreasury {
    IERC20 public immutable USDC;

    constructor(IERC20 usdc_) {
        USDC = usdc_;
    }

    function deployInto(ERC4626Strategy strategy, uint256 amount) external {
        strategy.deploy(amount);
    }

    function withdrawFrom(ERC4626Strategy strategy, uint256 amount) external {
        strategy.withdraw(amount);
    }
}

contract ERC4626StrategyHarnessVault is ERC20, ERC4626 {
    constructor(IERC20 asset_) ERC20("Kontrol Vault", "kVLT") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

contract ERC4626StrategyZeroShareVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Zero Share", "ZERO") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function deposit(uint256 assets, address) public override returns (uint256) {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        return 0;
    }
}

contract ERC4626StrategyFeeVault is ERC20, ERC4626 {
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

/// @notice Stateful adversarial vault model for reaching the strategy's
///         post-redeem balance-delta guard after shares and assets move.
contract ERC4626StrategyAdversarialVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    enum WithdrawMode {
        Exact,
        Short,
        Over
    }

    WithdrawMode public withdrawMode;
    uint256 public shortfall;
    uint256 public redeemCalls;
    uint256 public lastRedeemShares;
    uint256 public lastRedeemAssets;

    constructor(IERC20 asset_) ERC20("Adversarial Vault", "ADV") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function setWithdrawMode(WithdrawMode mode, uint256 shortfall_) external {
        withdrawMode = mode;
        shortfall = shortfall_;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (withdrawMode == WithdrawMode.Exact) {
            super._withdraw(caller, receiver, owner, assets, shares);
            return;
        }

        ++redeemCalls;
        lastRedeemShares = shares;
        lastRedeemAssets = assets;
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);
        uint256 delivered = withdrawMode == WithdrawMode.Short ? assets - shortfall : assets + shortfall;
        IERC20(asset()).safeTransfer(receiver, delivered);
        emit Withdraw(caller, receiver, owner, delivered, shares);
    }
}

contract ERC4626StrategyFactory {
    function deploy(address treasury, Registry registry, IERC4626 vault) external returns (ERC4626Strategy) {
        return new ERC4626Strategy(treasury, registry, vault);
    }
}

abstract contract ERC4626StrategyKontrolBase is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant OUTSIDER = address(0xBAD);

    Registry internal registry;
    ERC4626StrategyHarnessToken internal usdc;
    ERC4626StrategyHarnessTreasury internal treasury;
    ERC4626StrategyHarnessVault internal vault;
    ERC4626Strategy internal strategy;

    function setUp() public virtual {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usdc = new ERC4626StrategyHarnessToken();
        treasury = new ERC4626StrategyHarnessTreasury(usdc);
        vault = new ERC4626StrategyHarnessVault(usdc);
        strategy = new ERC4626Strategy(address(treasury), registry, vault);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _assertExactBytes(bytes memory actual, bytes memory expected) internal pure {
        assert(actual.length == expected.length);
        assert(keccak256(actual) == keccak256(expected));
    }

    function _fundStrategy(uint256 amount) internal {
        usdc.mint(address(strategy), amount);
    }

    function _deploy(uint256 amount) internal {
        treasury.deployInto(strategy, amount);
    }

    function _withdraw(uint256 amount) internal {
        treasury.withdrawFrom(strategy, amount);
    }
}
