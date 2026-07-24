// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../src/Registry.sol";
import {Treasury} from "../src/Treasury.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ConfiguredAssetVault is ERC20, ERC4626 {
    constructor(IERC20 asset_) ERC20("Configured vault", "CV") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

contract StrategyConfigTest is Test {
    Registry internal registry;
    Treasury internal treasury;
    MockERC20 internal reserveAsset;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        reserveAsset = new MockERC20("Configured USDC", "cUSDC", 6);
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()),
                    abi.encodeCall(Treasury.initialize, (registry, IERC20(address(reserveAsset))))
                )
            )
        );
    }

    function test_StrategyDerivesConfiguredReserveAssetFromTreasury() public {
        ConfiguredAssetVault vault = new ConfiguredAssetVault(IERC20(address(reserveAsset)));

        ERC4626Strategy strategy = new ERC4626Strategy(address(treasury), registry, IERC4626(address(vault)));

        assertEq(address(strategy.USDC()), address(reserveAsset));
        assertEq(strategy.underlying(), address(reserveAsset));
    }

    function test_StrategyRejectsVaultWithDifferentAsset() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 6);
        ConfiguredAssetVault vault = new ConfiguredAssetVault(IERC20(address(other)));

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Strategy.VaultAssetMismatch.selector, address(reserveAsset), address(other))
        );
        new ERC4626Strategy(address(treasury), registry, IERC4626(address(vault)));
    }
}
