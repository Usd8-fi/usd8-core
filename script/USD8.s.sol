// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {USD8} from "../src/USD8.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys the USD8 implementation and an ERC-1967 proxy that
///         delegates to it, initializing with the configured admin
///         and treasury.
/// @dev    Requires env vars:
///           USD8_DEFAULT_ADMIN — initial admin / upgrade authority.
///           USD8_TREASURY — initial treasury allowed to mint/burn.
contract USD8Script is Script {
    function run() external {
        address treasury = vm.envAddress("USD8_TREASURY");
        address admin = vm.envAddress("USD8_DEFAULT_ADMIN");

        vm.startBroadcast();
        USD8 impl = new USD8();
        bytes memory init = abi.encodeCall(USD8.initialize, (admin, treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        vm.stopBroadcast();

        console2.log("USD8 implementation:", address(impl));
        console2.log("USD8 proxy:", address(proxy));
    }
}
