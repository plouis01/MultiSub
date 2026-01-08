// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/**
 * @title IRewardsController
 * @notice Interface for querying reward tokens from Aave V3 RewardsController
 */
interface IRewardsController {
    /// @notice Returns the list of available reward token addresses for an asset
    function getRewardsByAsset(address asset) external view returns (address[] memory);
}

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
    function extractOutputTokens(address target, bytes calldata data) external view override returns (address[] memory tokens) {
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
        } else if (selector == CLAIM_ALL_REWARDS_SELECTOR) {
            // claimAllRewards(address[] assets, address to)
            // Query reward tokens from the RewardsController for each asset
            (address[] memory assets,) = abi.decode(data[4:], (address[], address));
            return _getRewardTokensForAssets(target, assets);
        } else if (selector == CLAIM_ALL_ON_BEHALF_SELECTOR) {
            // claimAllRewardsOnBehalf(address[] assets, address user, address to)
            // Query reward tokens from the RewardsController for each asset
            (address[] memory assets,,) = abi.decode(data[4:], (address[], address, address));
            return _getRewardTokensForAssets(target, assets);
        }
        revert UnsupportedSelector();
    }

    /**
     * @notice Get all unique reward tokens for a list of assets
     * @param rewardsController The RewardsController address
     * @param assets The list of assets to query
     * @return tokens Array of unique reward token addresses
     * @dev Uses single-pass deduplication for gas efficiency
     */
    function _getRewardTokensForAssets(address rewardsController, address[] memory assets) internal view returns (address[] memory tokens) {
        uint256 assetsLen = assets.length;
        if (assetsLen == 0) return new address[](0);

        // Cache all reward arrays to avoid duplicate external calls
        address[][] memory cachedRewards = new address[][](assetsLen);
        uint256 totalCount = 0;
        for (uint256 i = 0; i < assetsLen; ) {
            cachedRewards[i] = IRewardsController(rewardsController).getRewardsByAsset(assets[i]);
            totalCount += cachedRewards[i].length;
            unchecked { ++i; }
        }

        if (totalCount == 0) return new address[](0);

        // Single-pass deduplication: collect unique tokens directly
        tokens = new address[](totalCount);
        uint256 uniqueIdx = 0;

        for (uint256 i = 0; i < assetsLen; ) {
            address[] memory rewards = cachedRewards[i];
            uint256 rewardsLen = rewards.length;

            for (uint256 j = 0; j < rewardsLen; ) {
                address reward = rewards[j];
                bool isDuplicate = false;

                // Only check against already-added unique tokens
                for (uint256 k = 0; k < uniqueIdx; ) {
                    if (tokens[k] == reward) {
                        isDuplicate = true;
                        break;
                    }
                    unchecked { ++k; }
                }

                if (!isDuplicate) {
                    tokens[uniqueIdx] = reward;
                    unchecked { ++uniqueIdx; }
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }

        // Resize array to actual unique count
        assembly {
            mstore(tokens, uniqueIdx)
        }
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
     * @return opType
     */
    function getOperationType(bytes calldata data) external pure override returns (uint8 opType) {
        bytes4 selector = bytes4(data[:4]);
        if (_isClaimSelector(selector)) {
            return 1; // CLAIM
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
