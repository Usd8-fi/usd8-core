// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";

/// @notice Executes and proves an exact 1 mUSDC -> 1 USD8 -> 1 mUSDC Sepolia round trip.
contract SmokeSepoliaMockUsdcScript is Script {
    uint256 private constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 private constant USDC_AMOUNT = 1e6;
    uint256 private constant USD8_AMOUNT = 1e18;
    address private constant SEPOLIA_ADMIN = 0x724e8951d39E14CEBcB5fB02638f49A637C97838;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        require(msg.sender == SEPOLIA_ADMIN, "broadcaster/admin mismatch");

        IERC20 usdc = IERC20(vm.envAddress("SEPOLIA_USDC"));
        Treasury treasury = Treasury(vm.envAddress("SEPOLIA_TREASURY"));
        USD8 usd8 = USD8(vm.envAddress("SEPOLIA_USD8"));
        require(address(treasury.USDC()) == address(usdc), "wrong reserve asset");

        uint256 usdcBefore = usdc.balanceOf(SEPOLIA_ADMIN);
        uint256 usd8Before = usd8.balanceOf(SEPOLIA_ADMIN);
        uint256 reserveBefore = treasury.getReserveBalance();

        vm.startBroadcast();
        usdc.approve(address(treasury), USDC_AMOUNT);
        treasury.mintUSD8(USDC_AMOUNT);
        treasury.redeemUSD8(USD8_AMOUNT, USDC_AMOUNT);
        vm.stopBroadcast();

        require(usdc.balanceOf(SEPOLIA_ADMIN) == usdcBefore, "USDC round trip mismatch");
        require(usd8.balanceOf(SEPOLIA_ADMIN) == usd8Before, "USD8 round trip mismatch");
        require(treasury.getReserveBalance() == reserveBefore, "reserve round trip mismatch");
        require(usdc.allowance(SEPOLIA_ADMIN, address(treasury)) == 0, "allowance not consumed");

        console2.log("Sepolia mock-USDC mint/redeem smoke passed");
        console2.log("Treasury", address(treasury));
        console2.log("Mock USDC", address(usdc));
        console2.log("USD8", address(usd8));
    }
}
