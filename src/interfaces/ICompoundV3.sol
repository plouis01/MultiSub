// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICompoundV3
 * @notice Interface for Compound V3 (Comet)
 * @dev Compound V3 uses a different model - the Comet contract itself tracks balances
 */
interface ICompoundV3 {
    /**
     * @notice Get the current balance of an account (principal + interest)
     * @param account The account to query
     * @return The balance with interest
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Get the base asset (underlying token)
     * @return The address of the base asset
     */
    function baseToken() external view returns (address);

    /**
     * @notice Get the base token balance of an account
     * @param account The account to query
     * @return The base token balance
     */
    function balanceOfBase(address account) external view returns (uint256);
}
