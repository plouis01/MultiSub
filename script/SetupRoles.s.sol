// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/SmartWallet.sol";
import "../src/DeFiInteractor.sol";

/**
 * @title SetupRoles
 * @notice Script to configure sub-accounts and roles after deployment
 * @dev Run with: forge script script/SetupRoles.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */
contract SetupRoles is Script {
    function run() external {
        // Get addresses from environment
        address smartWalletAddress = vm.envAddress("SMART_WALLET_ADDRESS");
        address defiInteractorAddress = vm.envAddress("DEFI_INTERACTOR_ADDRESS");
        address subAccountAddress = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        address morphoVaultAddress = vm.envAddress("MORPHO_VAULT_ADDRESS");

        SmartWallet smartWallet = SmartWallet(smartWalletAddress);
        DeFiInteractor defiInteractor = DeFiInteractor(defiInteractorAddress);

        console.log("Setting up roles with:");
        console.log("  SmartWallet:", smartWalletAddress);
        console.log("  DeFiInteractor:", defiInteractorAddress);
        console.log("  Sub-Account:", subAccountAddress);
        console.log("  Morpho Vault:", morphoVaultAddress);

        vm.startBroadcast();

        // Add sub-account to SmartWallet
        console.log("\n1. Adding sub-account...");
        smartWallet.addSubAccount(subAccountAddress);
        console.log("   Sub-account added:", subAccountAddress);

        // Whitelist Morpho Vault protocol
        console.log("\n2. Whitelisting Morpho Vault...");
        smartWallet.whitelistProtocol(morphoVaultAddress);
        console.log("   Protocol whitelisted:", morphoVaultAddress);

        // Grant deposit role to sub-account
        console.log("\n3. Granting deposit role...");
        defiInteractor.grantRole(subAccountAddress, defiInteractor.DEFI_DEPOSIT_ROLE());
        console.log("   Deposit role granted to:", subAccountAddress);

        // Grant withdraw role to sub-account (optional, more restrictive)
        console.log("\n4. Granting withdraw role...");
        defiInteractor.grantRole(subAccountAddress, defiInteractor.DEFI_WITHDRAW_ROLE());
        console.log("   Withdraw role granted to:", subAccountAddress);

        vm.stopBroadcast();

        // Verify setup
        console.log("\n=== Setup Verification ===");
        console.log("Sub-account enabled:", smartWallet.isSubAccount(subAccountAddress));
        console.log("Protocol whitelisted:", smartWallet.isWhitelisted(morphoVaultAddress));
        console.log("Has deposit role:", defiInteractor.hasRole(subAccountAddress, 1));
        console.log("Has withdraw role:", defiInteractor.hasRole(subAccountAddress, 2));

        console.log("\n=== Limits ===");
        console.log("Max deposit: 10% of vault assets");
        console.log("Max withdraw: 5% of vault assets");
    }
}
