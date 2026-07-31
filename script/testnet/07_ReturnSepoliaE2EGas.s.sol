// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Returns a fixed, bounded amount of Sepolia gas from a disposable E2E actor.
contract ReturnSepoliaE2EGasScript is Script {
    uint256 internal constant RETURN_AMOUNT = 0.03 ether;

    function run() external {
        require(block.chainid == 11_155_111, "Sepolia only");
        address destination = vm.envAddress("SEPOLIA_GAS_DESTINATION");
        require(destination != address(0), "zero destination");
        vm.startBroadcast();
        payable(destination).transfer(RETURN_AMOUNT);
        vm.stopBroadcast();
        console2.log("Returned Sepolia ETH", RETURN_AMOUNT);
        console2.log("to", destination);
    }
}
