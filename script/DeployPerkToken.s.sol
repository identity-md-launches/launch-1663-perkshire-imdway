// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PerkToken} from "../src/PerkToken.sol";

/// @title DeployPerkToken
/// @notice Reviewable deployment of `PerkToken` for local or test networks.
/// @dev The IMD launch does NOT use this script: ProjectFactory.launchCustom deploys the token from
///      its creation code and the manifest step records it. This script exists so the deployment is
///      reproducible and testable elsewhere. `deploy()` takes no configuration because the token has
///      no constructor arguments; tests call it directly. `run()` only wraps it in a broadcast.
contract DeployPerkToken is Script {
    /// @notice Deploys the token and returns it. Whoever calls this (the broadcaster, in `run()`)
    ///         receives the full supply.
    function deploy() public returns (PerkToken token) {
        token = new PerkToken();
    }

    /// @notice Broadcast entry point. Not used by the IMD launch.
    function run() external returns (PerkToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
