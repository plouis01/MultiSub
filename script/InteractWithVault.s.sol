// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractor.sol";
import "../src/interfaces/IMorphoVault.sol";

/**
 * @title InteractWithVault
 * @notice Example script showing how a sub-account interacts with Morpho Vault
 * @dev Run with sub-account private key: forge script script/InteractWithVault.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */
contract InteractWithVault is Script {
    function run() external {
        // Get addresses from environment
        address defiInteractorAddress = vm.envAddress("DEFI_INTERACTOR_ADDRESS");
        address morphoVaultAddress = vm.envAddress("MORPHO_VAULT_ADDRESS");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");

        DeFiInteractor defiInteractor = DeFiInteractor(defiInteractorAddress);
        IMorphoVault vault = IMorphoVault(morphoVaultAddress);

        console.log("Interacting with Morpho Vault:");
        console.log("  DeFiInteractor:", defiInteractorAddress);
        console.log("  Morpho Vault:", morphoVaultAddress);
        console.log("  Safe:", safeAddress);

        // Get vault info
        uint256 totalAssets = vault.totalAssets();
        console.log("\nVault Total Assets:", totalAssets);

        // Calculate max deposit (10%)
        uint256 maxDeposit = (totalAssets * 1000) / 10000;
        console.log("Max Deposit (10%):", maxDeposit);

        // Calculate max withdraw (5%)
        uint256 maxWithdraw = (totalAssets * 500) / 10000;
        console.log("Max Withdraw (5%):", maxWithdraw);

        vm.startBroadcast();

        // Example 1: Deposit 5% of total assets
        uint256 depositAmount = (totalAssets * 500) / 10000;
        console.log("\n=== Depositing ===");
        console.log("Amount:", depositAmount);

        try defiInteractor.depositTo(morphoVaultAddress, depositAmount, safeAddress, 0) returns (uint256 shares) {
            console.log("Success! Shares received:", shares);
        } catch Error(string memory reason) {
            console.log("Failed:", reason);
        }

        // Example 2: Withdraw 2% of total assets
        uint256 withdrawAmount = (totalAssets * 200) / 10000;
        console.log("\n=== Withdrawing ===");
        console.log("Amount:", withdrawAmount);

        try defiInteractor.withdrawFrom(
            morphoVaultAddress,
            withdrawAmount,
            safeAddress,
            safeAddress,
            type(uint256).max
        ) returns (uint256 shares) {
            console.log("Success! Shares burned:", shares);
        } catch Error(string memory reason) {
            console.log("Failed:", reason);
        }

        vm.stopBroadcast();
    }
}
