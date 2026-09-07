// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";

library SepoliaAllRoutesRelisting {
    function salt(string memory lane) internal pure returns (bytes32) {
        return keccak256(abi.encode("USD8 Sepolia all-routes relist v1", lane));
    }

    function payload(IERC20 lossToken, address usdcOracle) internal pure returns (bytes memory) {
        bytes memory recipe = abi.encodeCall(IERC4626.convertToAssets, (1e18));
        return abi.encodeCall(
            DefiInsurance.editInsuredToken,
            (lossToken, 8000, usdcOracle, address(lossToken), recipe)
        );
    }
}
