// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DeFiInteractorModule.sol";
import "../src/parsers/AaveV3Parser.sol";
import "../src/parsers/UniswapV3Parser.sol";
import "../src/parsers/MerklParser.sol";
import "./utils/SafeTxHelper.sol";

/**
 * @title UpdateParser
 * @notice Redeploy a parser and update its registration on the module
 * @dev Executes via Safe transaction since Safe is the module owner
 *      This is the claim-only version - supports aave, uniswapv3, merkl parsers
 *
 * Environment variables:
 *   - SAFE_ADDRESS: The Safe multisig address (owner of the module)
 *   - DEFI_MODULE_ADDRESS: The deployed DeFiInteractorModule address
 *   - DEPLOYER_PRIVATE_KEY: Private key of Safe owner
 *   - PARSER_TYPE: Which parser to update (aave, uniswapv3, merkl)
 *   - PROTOCOL_ADDRESS: (Optional) Additional protocol address to register the parser for
 *
 * Usage:
 *   SAFE_ADDRESS=0x... DEFI_MODULE_ADDRESS=0x... PARSER_TYPE=aave \
 *   forge script script/UpdateParser.s.sol --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
 */
contract UpdateParser is Script, SafeTxHelper {
    // ============ Protocol Addresses (Sepolia) ============
    address constant AAVE_V3_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant AAVE_V3_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    address safe;
    address module;
    uint256 deployerPrivateKey;

    function run() external {
        safe = vm.envAddress("SAFE_ADDRESS");
        module = vm.envAddress("DEFI_MODULE_ADDRESS");
        deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory parserType = vm.envString("PARSER_TYPE");
        address extraProtocol = vm.envOr("PROTOCOL_ADDRESS", address(0));

        console.log("=== Update Parser (Claim-Only) ===");
        console.log("Safe:", safe);
        console.log("Module:", module);
        console.log("Parser type:", parserType);

        vm.startBroadcast(deployerPrivateKey);

        bytes32 parserTypeHash = keccak256(bytes(parserType));

        if (parserTypeHash == keccak256("aave")) {
            _updateAaveParser(extraProtocol);
        } else if (parserTypeHash == keccak256("uniswapv3")) {
            _updateUniswapV3Parser(extraProtocol);
        } else if (parserTypeHash == keccak256("merkl")) {
            _updateMerklParser(extraProtocol);
        } else {
            revert("Unknown parser type. Use: aave, uniswapv3, merkl");
        }

        vm.stopBroadcast();
    }

    function _updateAaveParser(address extraProtocol) internal {
        console.log("\nDeploying new AaveV3Parser...");
        AaveV3Parser parser = new AaveV3Parser();
        console.log("Deployed at:", address(parser));

        console.log("Registering for Aave V3 Pool...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", AAVE_V3_POOL, address(parser)
        ), deployerPrivateKey);

        console.log("Registering for Aave V3 Rewards...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", AAVE_V3_REWARDS, address(parser)
        ), deployerPrivateKey);

        if (extraProtocol != address(0)) {
            console.log("Registering for extra protocol:", extraProtocol);
            _executeSafeTx(safe, module, abi.encodeWithSignature(
                "registerParser(address,address)", extraProtocol, address(parser)
            ), deployerPrivateKey);
        }

        console.log("\n=== AaveV3Parser Updated ===");
        console.log("New parser:", address(parser));
    }

    function _updateUniswapV3Parser(address extraProtocol) internal {
        console.log("\nDeploying new UniswapV3Parser...");
        UniswapV3Parser parser = new UniswapV3Parser();
        console.log("Deployed at:", address(parser));

        console.log("Registering for NonfungiblePositionManager...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", NONFUNGIBLE_POSITION_MANAGER, address(parser)
        ), deployerPrivateKey);

        if (extraProtocol != address(0)) {
            console.log("Registering for extra protocol:", extraProtocol);
            _executeSafeTx(safe, module, abi.encodeWithSignature(
                "registerParser(address,address)", extraProtocol, address(parser)
            ), deployerPrivateKey);
        }

        console.log("\n=== UniswapV3Parser Updated ===");
        console.log("New parser:", address(parser));
    }

    function _updateMerklParser(address extraProtocol) internal {
        console.log("\nDeploying new MerklParser...");
        MerklParser parser = new MerklParser();
        console.log("Deployed at:", address(parser));

        console.log("Registering for Merkl Distributor...");
        _executeSafeTx(safe, module, abi.encodeWithSignature(
            "registerParser(address,address)", MERKL_DISTRIBUTOR, address(parser)
        ), deployerPrivateKey);

        if (extraProtocol != address(0)) {
            console.log("Registering for extra protocol:", extraProtocol);
            _executeSafeTx(safe, module, abi.encodeWithSignature(
                "registerParser(address,address)", extraProtocol, address(parser)
            ), deployerPrivateKey);
        }

        console.log("\n=== MerklParser Updated ===");
        console.log("New parser:", address(parser));
    }
}
