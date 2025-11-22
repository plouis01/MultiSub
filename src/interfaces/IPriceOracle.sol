// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPriceOracle
 * @notice Interface for price oracle to get token prices and protocol position values in USD
 */
interface IPriceOracle {
    /**
     * @notice Get the price of a token in USD (18 decimals)
     * @param token The token address
     * @return price The price in USD with 18 decimals
     */
    function getPrice(address token) external view returns (uint256 price);

    /**
     * @notice Get the value of an amount of tokens in USD (18 decimals)
     * @param token The token address
     * @param amount The amount of tokens
     * @return value The value in USD with 18 decimals
     */
    function getValue(address token, uint256 amount) external view returns (uint256 value);

    /**
     * @notice Get the USD value of a protocol position (e.g., vault shares, aTokens)
     * @param protocol The protocol address (e.g., Morpho vault address)
     * @param holder The address holding the position
     * @return value The value in USD with 18 decimals
     */
    function getPositionValue(address protocol, address holder) external view returns (uint256 value);
}
