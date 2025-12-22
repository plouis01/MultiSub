// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/interfaces/ISafe.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title Deploy
 * @notice Deploy DeFiInteractorModule (Claim-Only Version) and enable it on the Safe
 * @dev Executes enableModule via Safe transaction since only the Safe can enable modules
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *
 * Usage:
 *   SAFE_ADDRESS=0x... \
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract Deploy is Script, SafeTxHelper {
    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Deploy DeFiInteractorModule (Claim-Only) ===");
        console.log("Safe:", safe);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the module (Safe is both avatar and owner)
        DeFiInteractorModule module = new DeFiInteractorModule(safe, safe);
        console.log("\n1. Module deployed at:", address(module));

        // 2. Enable module on Safe via execTransaction
        console.log("\n2. Enabling module on Safe...");
        _executeSafeTx(safe, safe, abi.encodeWithSignature(
            "enableModule(address)",
            address(module)
        ), deployerPrivateKey);
        console.log("   Module enabled");

        vm.stopBroadcast();

        // Verify
        require(ISafe(safe).isModuleEnabled(address(module)), "Module not enabled");

        console.log("\n=== Deployment Complete ===");
        console.log("DeFiInteractorModule:", address(module));
        console.log("\nNext steps:");
        console.log("1. Run ConfigureParsersAndSelectors.s.sol to set up protocol support");
        console.log("2. Run ConfigureSubaccount.s.sol to set up sub-accounts with CLAIM_ROLE");
    }
}
