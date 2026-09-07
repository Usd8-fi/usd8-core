// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DefiInsurance} from "../src/DefiInsurance.sol";
import {SepoliaAllRoutesRelisting} from "../script/testnet/SepoliaAllRoutesRelisting.sol";

contract SepoliaAllRoutesRelistingHarness {
    function salt(string memory lane) external pure returns (bytes32) {
        return SepoliaAllRoutesRelisting.salt(lane);
    }

    function payload(address token, address oracle) external pure returns (bytes memory) {
        return SepoliaAllRoutesRelisting.payload(IERC20(token), oracle);
    }
}

contract SepoliaAllRoutesRelistingScriptTest is Test {
    SepoliaAllRoutesRelistingHarness internal harness;

    function setUp() public {
        harness = new SepoliaAllRoutesRelistingHarness();
    }

    function test_SaltBindsDistinctRouteLanes() public view {
        bytes32 laneD = harness.salt("D-all-cancel");
        bytes32 laneA = harness.salt("A-normal-root");

        assertEq(laneD, keccak256(abi.encode("USD8 Sepolia all-routes relist v1", "D-all-cancel")));
        assertTrue(laneD != laneA);
    }

    function test_PayloadRestoresCanonicalLossTokenConfiguration() public {
        address token = makeAddr("token");
        address oracle = makeAddr("oracle");
        bytes memory recipe = abi.encodeCall(IERC4626.convertToAssets, (1e18));

        assertEq(
            harness.payload(token, oracle),
            abi.encodeCall(DefiInsurance.editInsuredToken, (IERC20(token), 8000, oracle, token, recipe))
        );
    }
}
