// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockParser
 * @notice Mock calldata parser for testing (Claim-Only version)
 * @dev Parses withdraw(uint256,address) and claim(address) calldata
 */
contract MockParser {
    bytes4 constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address)"));
    bytes4 constant CLAIM_SELECTOR = bytes4(keccak256("claim(address)"));

    address public tokenAddress;

    constructor(address _token) {
        tokenAddress = _token;
    }

    function extractInputTokens(address, bytes calldata) external pure returns (address[] memory tokens) {
        // CLAIM and WITHDRAW don't have input tokens
        return new address[](0);
    }

    function extractInputAmounts(address, bytes calldata) external pure returns (uint256[] memory amounts) {
        // CLAIM and WITHDRAW don't have input amounts
        return new uint256[](0);
    }

    function extractOutputTokens(address, bytes calldata) external view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = tokenAddress;
        return tokens;
    }

    function extractRecipient(address, bytes calldata data, address defaultRecipient) external pure returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == WITHDRAW_SELECTOR) {
            // withdraw(uint256,address) - recipient is second param
            (, recipient) = abi.decode(data[4:], (uint256, address));
        } else if (selector == CLAIM_SELECTOR) {
            // claim(address) - recipient is first param
            (recipient) = abi.decode(data[4:], (address));
        } else {
            recipient = defaultRecipient;
        }
    }

    function supportsSelector(bytes4 selector) external pure returns (bool) {
        return selector == WITHDRAW_SELECTOR || selector == CLAIM_SELECTOR;
    }

    function getOperationType(bytes calldata data) external pure returns (uint8) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == WITHDRAW_SELECTOR) {
            return 3; // WITHDRAW
        } else if (selector == CLAIM_SELECTOR) {
            return 4; // CLAIM
        }
        return 0; // UNKNOWN
    }
}
