// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";

/**
 * @title MockNonfungiblePositionManager
 * @notice Mock NPM for testing positions() call
 */
contract MockNonfungiblePositionManager {
    mapping(uint256 => address) public token0s;
    mapping(uint256 => address) public token1s;

    function setPosition(uint256 tokenId, address token0, address token1) external {
        token0s[tokenId] = token0;
        token1s[tokenId] = token1;
    }

    function positions(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) {
        return (
            0,              // nonce
            address(0),     // operator
            token0s[tokenId], // token0
            token1s[tokenId], // token1
            3000,           // fee
            int24(-887220), // tickLower
            int24(887220),  // tickUpper
            1e18,           // liquidity
            0,              // feeGrowthInside0LastX128
            0,              // feeGrowthInside1LastX128
            1000,           // tokensOwed0
            2000            // tokensOwed1
        );
    }
}

/**
 * @title UniswapV3ParserTest
 * @notice Tests for the Uniswap V3 NonfungiblePositionManager parser (Claim-Only Version)
 */
contract UniswapV3ParserTest is Test {
    UniswapV3Parser public parser;
    MockNonfungiblePositionManager public mockNPM;

    // Test addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USER = address(0x1234);

    uint256 constant TEST_TOKEN_ID = 12345;

    function setUp() public {
        parser = new UniswapV3Parser();
        mockNPM = new MockNonfungiblePositionManager();
        mockNPM.setPosition(TEST_TOKEN_ID, USDC, WETH);
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.COLLECT_SELECTOR(), bytes4(0xfc6f7865), "Collect selector mismatch");
    }

    function testSupportsSelector() public view {
        // Only COLLECT is supported in claim-only version
        assertTrue(parser.supportsSelector(parser.COLLECT_SELECTOR()), "Should support collect");

        // Swap operations NOT supported
        assertFalse(parser.supportsSelector(bytes4(0x414bf389)), "Should NOT support exactInputSingle");
        assertFalse(parser.supportsSelector(bytes4(0xc04b8d59)), "Should NOT support exactInput");
        assertFalse(parser.supportsSelector(bytes4(0xdb3e2198)), "Should NOT support exactOutputSingle");
        assertFalse(parser.supportsSelector(bytes4(0xf28c0498)), "Should NOT support exactOutput");

        // Unknown selector
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ Collect Tests ============

    function testCollectNoInputTokens() public view {
        // collect((uint256 tokenId, address recipient, uint128 amount0Max, uint128 amount1Max))
        bytes memory data = abi.encodeWithSelector(
            parser.COLLECT_SELECTOR(),
            TEST_TOKEN_ID,
            USER,
            type(uint128).max,
            type(uint128).max
        );

        address[] memory tokens = parser.extractInputTokens(address(mockNPM), data);
        assertEq(tokens.length, 0, "Collect should have no input tokens");
    }

    function testCollectNoInputAmounts() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.COLLECT_SELECTOR(),
            TEST_TOKEN_ID,
            USER,
            type(uint128).max,
            type(uint128).max
        );

        uint256[] memory amounts = parser.extractInputAmounts(address(mockNPM), data);
        assertEq(amounts.length, 0, "Collect should have no input amounts");
    }

    function testCollectExtractOutputTokens() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.COLLECT_SELECTOR(),
            TEST_TOKEN_ID,
            USER,
            type(uint128).max,
            type(uint128).max
        );

        address[] memory tokens = parser.extractOutputTokens(address(mockNPM), data);
        assertEq(tokens.length, 2, "Should have 2 output tokens");
        assertEq(tokens[0], USDC, "Token0 should be USDC");
        assertEq(tokens[1], WETH, "Token1 should be WETH");
    }

    function testCollectExtractRecipient() public view {
        bytes memory data = abi.encodeWithSelector(
            parser.COLLECT_SELECTOR(),
            TEST_TOKEN_ID,
            USER,
            type(uint128).max,
            type(uint128).max
        );

        address recipient = parser.extractRecipient(address(mockNPM), data, address(0));
        assertEq(recipient, USER, "Recipient should be USER");
    }

    function testCollectDifferentRecipient() public view {
        address differentRecipient = address(0x9999);
        bytes memory data = abi.encodeWithSelector(
            parser.COLLECT_SELECTOR(),
            TEST_TOKEN_ID,
            differentRecipient,
            type(uint128).max,
            type(uint128).max
        );

        address recipient = parser.extractRecipient(address(mockNPM), data, address(0));
        assertEq(recipient, differentRecipient, "Recipient should be different address");
    }

    // ============ Operation Type Tests ============

    function testGetOperationType() public view {
        bytes memory collectData = abi.encodeWithSelector(parser.COLLECT_SELECTOR());
        bytes memory unknownData = abi.encodeWithSelector(bytes4(0xdeadbeef));

        assertEq(parser.getOperationType(collectData), 4, "Collect should be CLAIM (4)");
        assertEq(parser.getOperationType(unknownData), 0, "Unknown should return 0");
    }

    // ============ Revert Tests ============

    function testUnsupportedSelectorReverts() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractInputTokens(address(mockNPM), badData);

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractInputAmounts(address(mockNPM), badData);

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractOutputTokens(address(mockNPM), badData);

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractRecipient(address(mockNPM), badData, address(0));
    }

    // Test that swap selectors are now rejected
    function testSwapSelectorsRevert() public {
        // exactInputSingle (old SWAP selector)
        bytes memory swapData = abi.encodeWithSelector(bytes4(0x414bf389), uint256(100));

        vm.expectRevert(UniswapV3Parser.UnsupportedSelector.selector);
        parser.extractInputTokens(address(mockNPM), swapData);
    }
}
