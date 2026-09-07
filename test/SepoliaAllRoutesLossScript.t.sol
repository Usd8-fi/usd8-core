// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SepoliaAllRoutesLoss} from "../script/testnet/SepoliaAllRoutesLoss.sol";

contract SepoliaAllRoutesLossHarness {
    function amount(uint256 assets, uint256 bps) external pure returns (uint256) {
        return SepoliaAllRoutesLoss.amount(assets, bps);
    }
}

contract SepoliaAllRoutesLossScriptTest is Test {
    SepoliaAllRoutesLossHarness internal harness;

    function setUp() public {
        harness = new SepoliaAllRoutesLossHarness();
    }

    function test_ComputesExactFloorLossInBasisPoints() public view {
        assertEq(harness.amount(1_001, 2_200), 220);
        assertEq(harness.amount(1e18, 2_200), 0.22e18);
    }

    function test_RejectsZeroAndFullLoss() public {
        vm.expectRevert("invalid loss bps");
        harness.amount(1e18, 0);
        vm.expectRevert("invalid loss bps");
        harness.amount(1e18, 10_000);
    }
}
