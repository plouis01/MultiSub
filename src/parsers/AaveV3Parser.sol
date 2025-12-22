// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title AaveV3Parser (Claim-Only Version)
 * @notice Calldata parser for Aave V3 RewardsController claim operations
 * @dev Only supports claim reward operations, no supply/withdraw/borrow
 *
 *      Supported contracts:
 *      - RewardsController (e.g., 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb on Sepolia)
 */
contract AaveV3Parser is ICalldataParser {
    error UnsupportedSelector();

    // Aave V3 RewardsController selectors (CLAIM operations only)
    bytes4 public constant CLAIM_REWARDS_SELECTOR = 0x236300dc;           // claimRewards(address[],uint256,address,address)
    bytes4 public constant CLAIM_REWARDS_ON_BEHALF_SELECTOR = 0x33028b99; // claimRewardsOnBehalf(address[],uint256,address,address,address)
    bytes4 public constant CLAIM_ALL_REWARDS_SELECTOR = 0xbb492bf5;       // claimAllRewards(address[],address)
    bytes4 public constant CLAIM_ALL_ON_BEHALF_SELECTOR = 0x9ff55db9;     // claimAllRewardsOnBehalf(address[],address,address)

    /// @inheritdoc ICalldataParser
    function extractInputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);
        if (_isClaimSelector(selector)) {
            // CLAIM operations don't have input tokens
            return new address[](0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractInputAmounts(address, bytes calldata data) external pure override returns (uint256[] memory amounts) {
        bytes4 selector = bytes4(data[:4]);
        if (_isClaimSelector(selector)) {
            // CLAIM operations don't have input amounts
            return new uint256[](0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractOutputTokens(address, bytes calldata data) external pure override returns (address[] memory tokens) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_REWARDS_SELECTOR) {
            // claimRewards(address[] assets, uint256 amount, address to, address reward)
            // reward token is the 4th parameter
            address token;
            (, , , token) = abi.decode(data[4:], (address[], uint256, address, address));
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == CLAIM_REWARDS_ON_BEHALF_SELECTOR) {
            // claimRewardsOnBehalf(address[] assets, uint256 amount, address user, address to, address reward)
            // reward token is the 5th parameter
            address token;
            (, , , , token) = abi.decode(data[4:], (address[], uint256, address, address, address));
            tokens = new address[](1);
            tokens[0] = token;
            return tokens;
        } else if (selector == CLAIM_ALL_REWARDS_SELECTOR || selector == CLAIM_ALL_ON_BEHALF_SELECTOR) {
            // claimAllRewards claims multiple reward tokens - unknown from calldata
            // Returns empty array - balance changes tracked externally
            return new address[](0);
        }
        revert UnsupportedSelector();
    }

    /// @inheritdoc ICalldataParser
    function extractRecipient(address, bytes calldata data, address) external pure override returns (address recipient) {
        bytes4 selector = bytes4(data[:4]);

        if (selector == CLAIM_REWARDS_SELECTOR) {
            // claimRewards(address[] assets, uint256 amount, address to, address reward)
            // 'to' is where rewards go
            (,, recipient,) = abi.decode(data[4:], (address[], uint256, address, address));
        } else if (selector == CLAIM_REWARDS_ON_BEHALF_SELECTOR) {
            // claimRewardsOnBehalf(address[] assets, uint256 amount, address user, address to, address reward)
            // 'to' is where rewards go (4th param)
            (,,, recipient,) = abi.decode(data[4:], (address[], uint256, address, address, address));
        } else if (selector == CLAIM_ALL_REWARDS_SELECTOR) {
            // claimAllRewards(address[] assets, address to)
            // 'to' is where rewards go
            (, recipient) = abi.decode(data[4:], (address[], address));
        } else if (selector == CLAIM_ALL_ON_BEHALF_SELECTOR) {
            // claimAllRewardsOnBehalf(address[] assets, address user, address to)
            // 'to' is where rewards go (3rd param)
            (,, recipient) = abi.decode(data[4:], (address[], address, address));
        } else {
            revert UnsupportedSelector();
        }
    }

    /// @inheritdoc ICalldataParser
    function supportsSelector(bytes4 selector) external pure override returns (bool) {
        return _isClaimSelector(selector);
    }

    /**
     * @notice Get the operation type for the given calldata
     * @param data The calldata to analyze
     * @return opType 4=CLAIM for all supported operations
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        if (_isClaimSelector(selector)) {
            return 4; // CLAIM
        }
        return 0; // UNKNOWN
    }

    /**
     * @notice Check if selector is a CLAIM operation
     */
    function _isClaimSelector(bytes4 selector) internal pure returns (bool) {
        return selector == CLAIM_REWARDS_SELECTOR ||
               selector == CLAIM_REWARDS_ON_BEHALF_SELECTOR ||
               selector == CLAIM_ALL_REWARDS_SELECTOR ||
               selector == CLAIM_ALL_ON_BEHALF_SELECTOR;
    }
}
