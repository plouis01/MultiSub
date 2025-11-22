// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SafeValueStorage
 * @notice Stores the USD value of a Safe multisig wallet, updated by Chainlink Runtime Environment
 * @dev Only authorized Chainlink nodes can update the value via signed reports
 */
contract SafeValueStorage {
    struct SafeValue {
        uint256 totalValueUSD; // Total USD value with 18 decimals (e.g., 1000.50 USD = 1000500000000000000000)
        uint256 lastUpdated;   // Timestamp of last update
        uint256 updateCount;   // Number of updates received
    }

    // Safe address => SafeValue data
    mapping(address => SafeValue) public safeValues;

    // Authorized updater (Chainlink CRE proxy contract)
    address public authorizedUpdater;

    // Owner for admin functions
    address public owner;

    event SafeValueUpdated(
        address indexed safeAddress,
        uint256 totalValueUSD,
        uint256 timestamp,
        uint256 updateCount
    );

    event AuthorizedUpdaterChanged(
        address indexed oldUpdater,
        address indexed newUpdater
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == authorizedUpdater, "Only authorized updater");
        _;
    }

    constructor(address _authorizedUpdater) {
        owner = msg.sender;
        authorizedUpdater = _authorizedUpdater;
    }

    /**
     * @notice Update the USD value for a Safe multisig
     * @param safeAddress The address of the Safe wallet
     * @param totalValueUSD The total USD value with 18 decimals
     */
    function updateSafeValue(
        address safeAddress,
        uint256 totalValueUSD
    ) external onlyAuthorized {
        require(safeAddress != address(0), "Invalid safe address");

        SafeValue storage sv = safeValues[safeAddress];
        sv.totalValueUSD = totalValueUSD;
        sv.lastUpdated = block.timestamp;
        sv.updateCount += 1;

        emit SafeValueUpdated(
            safeAddress,
            totalValueUSD,
            block.timestamp,
            sv.updateCount
        );
    }

    /**
     * @notice Get the current USD value of a Safe
     * @param safeAddress The address of the Safe wallet
     * @return totalValueUSD The total USD value with 18 decimals
     * @return lastUpdated Timestamp of last update
     * @return updateCount Number of updates
     */
    function getSafeValue(address safeAddress)
        external
        view
        returns (
            uint256 totalValueUSD,
            uint256 lastUpdated,
            uint256 updateCount
        )
    {
        SafeValue memory sv = safeValues[safeAddress];
        return (sv.totalValueUSD, sv.lastUpdated, sv.updateCount);
    }

    /**
     * @notice Check if the Safe value is stale (not updated in specified time)
     * @param safeAddress The address of the Safe wallet
     * @param maxAge Maximum age in seconds before considered stale
     * @return isStale True if the data is stale
     */
    function isValueStale(address safeAddress, uint256 maxAge)
        external
        view
        returns (bool isStale)
    {
        SafeValue memory sv = safeValues[safeAddress];
        if (sv.lastUpdated == 0) return true; // Never updated
        return (block.timestamp - sv.lastUpdated) > maxAge;
    }

    /**
     * @notice Set the authorized updater address
     * @param newUpdater The new authorized updater address
     */
    function setAuthorizedUpdater(address newUpdater) external onlyOwner {
        require(newUpdater != address(0), "Invalid updater address");
        address oldUpdater = authorizedUpdater;
        authorizedUpdater = newUpdater;
        emit AuthorizedUpdaterChanged(oldUpdater, newUpdater);
    }

    /**
     * @notice Transfer ownership
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner address");
        owner = newOwner;
    }
}
