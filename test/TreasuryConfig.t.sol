// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../src/Registry.sol";
import {SharedBase} from "../src/SharedBase.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TreasuryConfigTest is Test {
    Registry internal registry;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
    }

    function _deploy(IERC20 reserveAsset) internal returns (Treasury) {
        Treasury implementation = new Treasury();
        return Treasury(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeCall(Treasury.initialize, (registry, reserveAsset)))
            )
        );
    }

    function test_ProxyUsesConfiguredReserveAsset() public {
        MockERC20 reserveAsset = new MockERC20("Configured USDC", "cUSDC", 6);

        Treasury treasury = _deploy(IERC20(address(reserveAsset)));

        assertEq(address(treasury.USDC()), address(reserveAsset));
    }

    function test_InitializeRejectsZeroReserveAsset() public {
        Treasury implementation = new Treasury();
        vm.expectRevert(SharedBase.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(0)))));
    }

    function test_InitializeRejectsReserveAssetWithoutCode() public {
        Treasury implementation = new Treasury();
        address noCode = makeAddr("reserve without code");

        vm.expectRevert(abi.encodeWithSelector(Treasury.InvalidReserveAsset.selector, noCode));
        new ERC1967Proxy(address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(noCode))));
    }

    function test_InitializeRejectsWrongReserveDecimals() public {
        MockERC20 reserveAsset = new MockERC20("Wrong reserve", "WRONG", 18);
        Treasury implementation = new Treasury();

        vm.expectRevert(abi.encodeWithSelector(Treasury.InvalidReserveDecimals.selector, uint8(18)));
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(reserveAsset))))
        );
    }
}
