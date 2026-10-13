// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPerkToken} from "../script/DeployPerkToken.s.sol";
import {PerkToken} from "../src/PerkToken.sol";

/// @notice Calls the script's deploy function directly, without `run()`, broadcast or environment.
contract DeployPerkTokenTest is Test {
    function test_deployMintsSupplyToTheCaller() public {
        DeployPerkToken deployer = new DeployPerkToken();
        PerkToken token = deployer.deploy();
        // The script contract is msg.sender of the constructor, so it holds the supply.
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 ether);
        assertEq(token.name(), "Perkshire IMDway");
        assertEq(token.symbol(), "PERK");
        assertEq(token.decimals(), 18);
    }

    function test_twoDeploymentsAreIndependent() public {
        DeployPerkToken deployer = new DeployPerkToken();
        PerkToken first = deployer.deploy();
        PerkToken second = deployer.deploy();
        assertTrue(address(first) != address(second));
        assertEq(first.totalSupply(), second.totalSupply());
        assertEq(first.balanceOf(address(deployer)), 1_000_000_000 ether);
        assertEq(second.balanceOf(address(deployer)), 1_000_000_000 ether);
    }
}
