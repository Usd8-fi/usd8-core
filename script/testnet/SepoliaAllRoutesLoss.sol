// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library SepoliaAllRoutesLoss {
    function amount(uint256 assets, uint256 bps) internal pure returns (uint256) {
        require(bps != 0 && bps < 10_000, "invalid loss bps");
        return Math.mulDiv(assets, bps, 10_000);
    }
}
