// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockProtocol
 * @notice Mock DeFi protocol for testing (Claim-Only version)
 */
contract MockProtocol {
    event ProtocolCalled(address indexed caller, uint256 amount);
    event ClaimCalled(address indexed caller, address indexed recipient);

    function withdraw(uint256 amount, address) external {
        emit ProtocolCalled(msg.sender, amount);
    }

    function claim(address recipient) external {
        emit ClaimCalled(msg.sender, recipient);
    }
}
