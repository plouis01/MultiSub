// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/SmartWallet.sol";
import "../src/DeFiInteractor.sol";

/**
 * @title DeploySmartWallet
 * @notice Script to deploy the SmartWallet system
 * @dev Run with: forge script script/DeploySmartWallet.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */
contract DeploySmartWallet is Script {
    function run() external {
        // Get deployment parameters from environment
        address safe = vm.envAddress("SAFE_ADDRESS");
        address rolesModifier = vm.envAddress("ZODIAC_ROLES_ADDRESS");

        console.log("Deploying SmartWallet with:");
        console.log("  Safe:", safe);
        console.log("  Zodiac Roles:", rolesModifier);

        vm.startBroadcast();

        // Deploy SmartWallet
        SmartWallet smartWallet = new SmartWallet(safe, rolesModifier);
        console.log("SmartWallet deployed at:", address(smartWallet));

        // Deploy DeFiInteractor
        DeFiInteractor defiInteractor = new DeFiInteractor(safe, rolesModifier);
        console.log("DeFiInteractor deployed at:", address(defiInteractor));

        vm.stopBroadcast();

        // Log deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("SmartWallet:", address(smartWallet));
        console.log("DeFiInteractor:", address(defiInteractor));
        console.log("\nNext steps:");
        console.log("1. Enable SmartWallet and DeFiInteractor as modules on Safe");
        console.log("2. Configure Zodiac Roles with appropriate permissions");
        console.log("3. Add sub-accounts via SmartWallet.addSubAccount()");
        console.log("4. Whitelist protocols via SmartWallet.whitelistProtocol()");
        console.log("5. Grant roles via DeFiInteractor.grantRole()");
    }
}
