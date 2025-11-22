// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IMorphoVault} from "./interfaces/IMorphoVault.sol";
import {IAToken} from "./interfaces/IAToken.sol";
import {ICompoundV3} from "./interfaces/ICompoundV3.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Chainlink Aggregator interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title ChainlinkOracleWithPositions
 * @notice Price oracle using Chainlink + protocol position valuation
 * @dev Returns prices in USD with 18 decimals
 * @dev This implementation uses a Chainlink-like interface for price feeds
 */
contract ChainlinkOracleWithPositions is IPriceOracle {

    /// @notice Maximum age of price data (24 hours)
    uint256 public constant MAX_PRICE_AGE = 24 hours;

    /// @notice Mapping of token address to Chainlink price feed
    mapping(address => AggregatorV3Interface) public priceFeeds;

    /// @notice Mapping of protocol address to protocol type
    mapping(address => ProtocolType) public protocolTypes;

    /// @notice Owner address (typically the Safe)
    address public immutable owner;

    enum ProtocolType {
        NONE, // Not a tracked protocol
        MORPHO_VAULT, // ERC4626 Morpho vault
        AAVE_V3, // Aave V3 aToken
        COMPOUND_V3 // Compound V3 cToken
    }

    error Unauthorized();
    error InvalidPriceFeed();
    error StalePrice();
    error InvalidPrice();
    error UnsupportedProtocol();

    event PriceFeedSet(address indexed token, address indexed priceFeed);
    event ProtocolAdded(address indexed protocol, ProtocolType protocolType);
    event ProtocolRemoved(address indexed protocol);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    /**
     * @notice Set the Chainlink price feed for a token
     * @param token The token address
     * @param priceFeed The Chainlink price feed address
     */
    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        if (priceFeed == address(0)) revert InvalidPriceFeed();
        priceFeeds[token] = AggregatorV3Interface(priceFeed);
        emit PriceFeedSet(token, priceFeed);
    }

    /**
     * @notice Register a protocol for position tracking
     * @param protocol The protocol address (e.g., Morpho vault address)
     * @param protocolType The type of protocol (MORPHO_VAULT, AAVE_V3, etc.)
     */
    function addProtocol(address protocol, ProtocolType protocolType) external onlyOwner {
        if (protocol == address(0)) revert InvalidPriceFeed();
        if (protocolType == ProtocolType.NONE) revert UnsupportedProtocol();
        protocolTypes[protocol] = protocolType;
        emit ProtocolAdded(protocol, protocolType);
    }

    /**
     * @notice Remove a protocol from tracking
     * @param protocol The protocol address to remove
     */
    function removeProtocol(address protocol) external onlyOwner {
        delete protocolTypes[protocol];
        emit ProtocolRemoved(protocol);
    }

    /**
     * @notice Get the price of a token in USD (18 decimals)
     * @param token The token address
     * @return price The price in USD with 18 decimals
     */
    function getPrice(address token) public view returns (uint256 price) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        if (address(priceFeed) == address(0)) revert InvalidPriceFeed();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        // Check for stale price
        if (updatedAt == 0 || block.timestamp - updatedAt > MAX_PRICE_AGE) {
            revert StalePrice();
        }

        // Check for invalid round
        if (answeredInRound < roundId) revert StalePrice();

        // Check for negative price
        if (answer <= 0) revert InvalidPrice();

        // Get feed decimals (usually 8 for USD feeds)
        uint8 feedDecimals = priceFeed.decimals();

        // Convert to 18 decimals
        if (feedDecimals < 18) {
            price = uint256(answer) * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            price = uint256(answer) / (10 ** (feedDecimals - 18));
        } else {
            price = uint256(answer);
        }
    }

    /**
     * @notice Get the value of an amount of tokens in USD (18 decimals)
     * @param token The token address
     * @param amount The amount of tokens (in token's decimals)
     * @return value The value in USD with 18 decimals
     */
    function getValue(address token, uint256 amount) external view returns (uint256 value) {
        if (amount == 0) return 0;

        uint256 price = getPrice(token);

        // Get token decimals
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        // Calculate value: normalize amount to 18 decimals, then multiply by price
        // value = (amount * 10^(18 - tokenDecimals)) * price / 10^18
        if (tokenDecimals <= 18) {
            uint256 normalizedAmount = amount * (10 ** (18 - tokenDecimals));
            value = (normalizedAmount * price) / 1e18;
        } else {
            uint256 normalizedAmount = amount / (10 ** (tokenDecimals - 18));
            value = (normalizedAmount * price) / 1e18;
        }
    }

    /**
     * @notice Get the USD value of a protocol position
     * @param protocol The protocol address (e.g., Morpho vault)
     * @param holder The address holding the position
     * @return value The value in USD with 18 decimals
     */
    function getPositionValue(address protocol, address holder) public view returns (uint256 value) {
        ProtocolType protocolType = protocolTypes[protocol];

        if (protocolType == ProtocolType.NONE) {
            return 0; // Not a tracked protocol, return 0 instead of reverting
        }

        if (protocolType == ProtocolType.MORPHO_VAULT) {
            return _getMorphoVaultValue(protocol, holder);
        }

        if (protocolType == ProtocolType.AAVE_V3) {
            return _getAaveV3Value(protocol, holder);
        }

        if (protocolType == ProtocolType.COMPOUND_V3) {
            return _getCompoundV3Value(protocol, holder);
        }

        revert UnsupportedProtocol();
    }

    /**
     * @notice Get value of Morpho vault position (ERC4626)
     * @param vault The Morpho vault address
     * @param holder The address holding the shares
     * @return value The value in USD with 18 decimals
     */
    function _getMorphoVaultValue(address vault, address holder) internal view returns (uint256 value) {
        IMorphoVault morphoVault = IMorphoVault(vault);

        // Get holder's share balance
        uint256 shares = morphoVault.balanceOf(holder);
        if (shares == 0) return 0;

        // Convert shares to underlying asset amount
        uint256 assets = morphoVault.convertToAssets(shares);

        // Get the underlying asset token
        address asset = morphoVault.asset();

        // Get USD value of underlying assets using Chainlink
        return this.getValue(asset, assets);
    }

    /**
     * @notice Get value of Aave V3 position
     * @dev Aave aTokens are 1:1 with underlying + accrued interest
     * @param aToken The Aave aToken address (e.g., aUSDC, aWETH)
     * @param holder The address holding the aTokens
     * @return value The value in USD with 18 decimals
     */
    function _getAaveV3Value(address aToken, address holder) internal view returns (uint256 value) {
        IAToken aaveToken = IAToken(aToken);

        // Get holder's aToken balance (includes accrued interest)
        uint256 balance = aaveToken.balanceOf(holder);
        if (balance == 0) return 0;

        // Get the underlying asset address
        address underlying = aaveToken.UNDERLYING_ASSET_ADDRESS();

        // aTokens are 1:1 with underlying + interest
        // The balance already includes all accrued interest
        return this.getValue(underlying, balance);
    }

    /**
     * @notice Get value of Compound V3 position
     * @dev Compound V3 (Comet) directly tracks base asset balances with interest
     * @param comet The Compound V3 Comet contract address
     * @param holder The address holding the position
     * @return value The value in USD with 18 decimals
     */
    function _getCompoundV3Value(address comet, address holder) internal view returns (uint256 value) {
        ICompoundV3 compoundV3 = ICompoundV3(comet);

        // Get holder's balance (includes principal + accrued interest)
        // Compound V3 uses balanceOf which returns the base token balance with interest
        uint256 balance = compoundV3.balanceOf(holder);
        if (balance == 0) return 0;

        // Get the base token (underlying asset)
        address baseToken = compoundV3.baseToken();

        // Compound V3 balance already includes interest
        return this.getValue(baseToken, balance);
    }
}
