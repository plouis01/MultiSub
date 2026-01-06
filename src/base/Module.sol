// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {ISafe} from "../interfaces/ISafe.sol";

/**
 * @title Module
 * @notice Base contract for Zodiac modules
 * @dev Modules allow designated addresses to execute transactions through a Safe
 */
abstract contract Module {
    /// @notice Address of the Safe (avatar) that this module interacts with
    address public immutable avatar;

    /// @notice Owner address that can configure the module
    address public immutable owner;

    event AvatarSet(address indexed avatar);
    event OwnershipSet(address indexed owner);

    error Unauthorized();
    error InvalidAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /**
     * @notice Initialize the module
     * @param _avatar The Safe address (avatar)
     * @param _owner The owner address
     */
    constructor(address _avatar, address _owner) {
        if (_avatar == address(0) || _owner == address(0)) {
            revert InvalidAddress();
        }
        avatar = _avatar;
        owner = _owner;

        emit AvatarSet(_avatar);
        emit OwnershipSet(_owner);
    }

    /**
     * @notice Execute a transaction from the module
     * @param to Target address
     * @param value ETH value to send
     * @param data Transaction data
     * @param operation Call (0) or DelegateCall (1)
     * @return success Whether the transaction succeeded
     */
    function exec(
        address to,
        uint256 value,
        bytes memory data,
        ISafe.Operation operation
    ) internal returns (bool success) {
        return ISafe(avatar).execTransactionFromModule(to, value, data, operation);
    }

}
