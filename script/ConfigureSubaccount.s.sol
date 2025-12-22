// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title ConfigureSubaccount
 * @notice Configure a sub-account with CLAIM_ROLE and whitelisted claim addresses
 * @dev Executes via Safe transaction since Safe is the module owner
 *      This is the claim-only version - only grants CLAIM_ROLE
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - SUB_ACCOUNT_ADDRESS: The sub-account wallet address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... SUB_ACCOUNT_ADDRESS=0x... \
 *   forge script script/ConfigureSubaccount.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract ConfigureSubaccount is Script, SafeTxHelper {
    // ============ Protocol Addresses (Sepolia) - Claim-only ============
    address constant AAVE_V3_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        address subAccount = vm.envAddress("SUB_ACCOUNT_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        DeFiInteractorModule defiModule = DeFiInteractorModule(module);

        console.log("=== Configure Sub-Account (Claim-Only) ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("Sub-account:", subAccount);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Grant CLAIM_ROLE
        console.log("\n1. Granting CLAIM_ROLE...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "grantRole(address,uint16)",
            subAccount,
            defiModule.CLAIM_ROLE()
        ), deployerPrivateKey);
        console.log("   Done");

        // 2. Whitelist claim-only protocol addresses
        console.log("\n2. Whitelisting claim-only protocols...");
        address[] memory protocols = new address[](3);
        protocols[0] = AAVE_V3_REWARDS;                // For claim rewards
        protocols[1] = NONFUNGIBLE_POSITION_MANAGER;   // For collect fees
        protocols[2] = MERKL_DISTRIBUTOR;              // For Merkl claims

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "setAllowedAddresses(address,address[],bool)",
            subAccount,
            protocols,
            true
        ), deployerPrivateKey);
        console.log("   Whitelisted:", protocols.length, "protocols");

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
        console.log("Sub-account:", subAccount);
        console.log("Role: CLAIM_ROLE (claim only)");
    }
}
