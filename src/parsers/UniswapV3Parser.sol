// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title INonfungiblePositionManager
 * @notice Interface for querying position details from Uniswap V3 NonfungiblePositionManager
 */
interface INonfungiblePositionManager {
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
    );
}

/**
 * @title UniswapV3Parser (Claim-Only Version)
 * @notice Calldata parser for Uniswap V3 NonfungiblePositionManager collect operation
 * @dev Only supports COLLECT_SELECTOR for claiming fees from LP positions
 *
 *      Supported contracts:
 *      - NonfungiblePositionManager (0xC36442b4a4522E871399CD717aBDD847Ab11FE88)
 */
contract UniswapV3Parser is ICalldataParser {
    error UnsupportedSelector();

    // collect((uint256,address,uint128,uint128))
    bytes4 public constant COLLECT_SELECTOR = 0xfc6f7865;

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == COLLECT_SELECTOR) {
            // Collect is a claim operation - no input tokens
            return new address[](0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmounts(address, bytes calldata data) external pure override returns (uint256[] memory amounts) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == COLLECT_SELECTOR) {
            // Collect is a claim operation - no input amounts
            return new uint256[](0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address target, bytes calldata data) external view override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == COLLECT_SELECTOR) {
            // CollectParams: (tokenId, recipient, amount0Max, amount1Max)
            // Returns fees in both token0 and token1 - query position for tokens
            (uint256 tokenId,,,) = abi.decode(data[4:], (uint256, address, uint128, uint128));
            (,, address token0, address token1,,,,,,,,) = INonfungiblePositionManager(target).positions(tokenId);
            tokens = new address[](2);
            tokens[0] = token0;
            tokens[1] = token1;
            return tokens;
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == COLLECT_SELECTOR) {
            // CollectParams: (tokenId, recipient, amount0Max, amount1Max)
            (, recipient,,) = abi.decode(data[4:], (uint256, address, uint128, uint128));
            return recipient;
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return selector == COLLECT_SELECTOR;
    }

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType 4=CLAIM for collect operation
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == COLLECT_SELECTOR) {
            return 4; // CLAIM
        }
        return 0; // UNKNOWN
    }
}
