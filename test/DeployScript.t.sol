// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../script/Deploy.s.sol";

contract DeployScriptTest is Test {
    function test_DeployRevertsOutsideEthereumMainnet() public {
        vm.chainId(31_337);
        DeployScript script = new DeployScript();

        vm.expectRevert(abi.encodeWithSignature("WrongChainId(uint256,uint256)", uint256(31_337), uint256(1)));
        script.run();
    }

    function test_InitialSavingsProfitWeightIsZero() public {
        DeployScript script = new DeployScript();
        (bool ok, bytes memory result) =
            address(script).staticcall(abi.encodeWithSignature("INITIAL_SAVINGS_PROFIT_WEIGHT()"));

        assertTrue(ok, "deployment must expose its launch savings-weight policy");
        assertEq(abi.decode(result, (uint256)), 0, "dead seed shares must not receive launch revenue");
    }
}
