// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/parsers/AaveV3Parser.sol";
import "../src/parsers/UniswapV3Parser.sol";
import "../src/parsers/MerklParser.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title ConfigureParsersAndSelectors
 * @notice Deploy claim-related parsers and register CLAIM selectors only
 * @dev Executes via Safe transaction since Safe is the module owner
 *      This is the claim-only version - only CLAIM operations are supported
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... \
 *   forge script script/ConfigureParsersAndSelectors.s.sol \
 *     --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract ConfigureParsersAndSelectors is Script, SafeTxHelper {
    // ============ Protocol Addresses (Sepolia) ============
    address constant AAVE_V3_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    // ============ Selectors (CLAIM only) ============
    // Aave V3 Rewards
    bytes4 constant AAVE_CLAIM_REWARDS = 0x236300dc;            // claimRewards(address[],uint256,address,address)
    bytes4 constant AAVE_CLAIM_REWARDS_ON_BEHALF = 0x33028b99;  // claimRewardsOnBehalf(address[],uint256,address,address,address)
    bytes4 constant AAVE_CLAIM_ALL_REWARDS = 0xbb492bf5;        // claimAllRewards(address[],address)
    bytes4 constant AAVE_CLAIM_ALL_ON_BEHALF = 0x9ff55db9;      // claimAllRewardsOnBehalf(address[],address,address)
    // NonfungiblePositionManager
    bytes4 constant NPM_COLLECT = 0xfc6f7865;
    // Merkl
    bytes4 constant MERKL_CLAIM = 0x71ee95c0;

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address module = vm.envAddress("DEFI_MODULE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== Configure Parsers and Selectors (Claim-Only) ===");
        console.log("Safe:", safe);
        console.log("Module:", module);

        vm.startBroadcast(deployerPrivateKey);

        // ============ Deploy Parsers ============
        console.log("\n--- Deploying Parsers ---");

        AaveV3Parser aaveParser = new AaveV3Parser();
        console.log("AaveV3Parser:", address(aaveParser));

        UniswapV3Parser uniV3Parser = new UniswapV3Parser();
        console.log("UniswapV3Parser:", address(uniV3Parser));

        MerklParser merklParser = new MerklParser();
        console.log("MerklParser:", address(merklParser));

        // ============ Register Parsers via Safe ============
        console.log("\n--- Registering Parsers ---");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", AAVE_V3_REWARDS, address(aaveParser)
        ), deployerPrivateKey);
        console.log("Aave V3 Rewards -> AaveV3Parser");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", NONFUNGIBLE_POSITION_MANAGER, address(uniV3Parser)
        ), deployerPrivateKey);
        console.log("Uniswap V3 NPM -> UniswapV3Parser");

        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", MERKL_DISTRIBUTOR, address(merklParser)
        ), deployerPrivateKey);
        console.log("Merkl Distributor -> MerklParser");

        // ============ Register Selectors via Safe (CLAIM only) ============
        console.log("\n--- Registering Selectors (CLAIM=4) ---");

        // Aave V3 Rewards - CLAIM
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_REWARDS, uint8(4)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_REWARDS_ON_BEHALF, uint8(4)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_ALL_REWARDS, uint8(4)), deployerPrivateKey);
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", AAVE_CLAIM_ALL_ON_BEHALF, uint8(4)), deployerPrivateKey);
        console.log("Aave claim* -> CLAIM");

        // NonfungiblePositionManager - CLAIM
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", NPM_COLLECT, uint8(4)), deployerPrivateKey);
        console.log("NPM collect -> CLAIM");

        // Merkl - CLAIM
        _executeSafeTx(safe, module, abi.encodeWithSignature("registerSelector(bytes4,uint8)", MERKL_CLAIM, uint8(4)), deployerPrivateKey);
        console.log("Merkl claim -> CLAIM");

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
        console.log("Supported operations: CLAIM (4) only");
    }
}
