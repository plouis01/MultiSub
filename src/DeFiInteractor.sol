// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMorphoVault} from "./interfaces/IMorphoVault.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IZodiacRoles} from "./interfaces/IZodiacRoles.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DeFiInteractor
 * @notice Contract for executing DeFi operations through Safe+Zodiac with restrictions
 * @dev Sub-accounts interact with this contract which enforces role-based permissions
 */
contract DeFiInteractor is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The Safe multisig that owns the assets
    ISafe public immutable safe;

    /// @notice The Zodiac Roles modifier for access control
    IZodiacRoles public immutable rolesModifier;

    /// @notice Role ID for basic DeFi operations (deposits)
    uint16 public constant DEFI_DEPOSIT_ROLE = 1;

    /// @notice Role ID for withdrawal operations (more restricted)
    uint16 public constant DEFI_WITHDRAW_ROLE = 2;
    /// @notice Price oracle for portfolio valuation
    IPriceOracle public priceOracle;

    /// @notice List of tracked tokens for portfolio valuation
    address[] public trackedTokens;

    /// @notice Mapping to check if token is tracked
    mapping(address => bool) public isTrackedToken;

    /// @notice List of tracked protocols for portfolio valuation
    address[] public trackedProtocols;

    /// @notice Mapping to check if protocol is tracked
    mapping(address => bool) public isTrackedProtocol;

    /// @notice Default maximum percentage of portfolio value loss allowed per window (basis points)
    uint256 public constant DEFAULT_MAX_LOSS_BPS = 500; // 5%

    /// @notice Default maximum percentage of assets a sub-account can deposit (basis points)
    uint256 public constant DEFAULT_MAX_DEPOSIT_BPS = 1000; // 10%

    /// @notice Default maximum percentage of assets a sub-account can withdraw (basis points)
    uint256 public constant DEFAULT_MAX_WITHDRAW_BPS = 500; // 5%

    /// @notice Default time window for cumulative limit tracking (24 hours)
    uint256 public constant DEFAULT_LIMIT_WINDOW_DURATION = 1 days;

    /// @notice Configuration for sub-account limits
    struct SubAccountLimits {
        uint256 maxDepositBps;      // Maximum deposit percentage in basis points
        uint256 maxWithdrawBps;     // Maximum withdrawal percentage in basis points
        uint256 maxLossBps;         // Maximum portfolio value loss in basis points
        uint256 windowDuration;     // Time window duration in seconds
        bool isConfigured;          // Whether limits have been explicitly set
    }

    /// @notice Per-sub-account limit configuration
    mapping(address => SubAccountLimits) public subAccountLimits;

    /// @notice Portfolio value at start of execution window: subAccount => value
    mapping(address => uint256) public executionWindowPortfolioValue;

    /// @notice Window start time for executions: subAccount => timestamp
    mapping(address => uint256) public executionWindowStart;

    /// @notice Cumulative value lost in current window: subAccount => amount
    mapping(address => uint256) public valueLostInWindow;

    /// @notice Per-sub-account allowed addresses: subAccount => target address => allowed
    mapping(address => mapping(address => bool)) public allowedAddresses;

    /// @notice Cumulative deposits in current window: subAccount => target address => amount
    mapping(address => mapping(address => uint256)) public depositedInWindow;

    /// @notice Cumulative withdrawals in current window: subAccount => target address => amount
    mapping(address => mapping(address => uint256)) public withdrawnInWindow;

    /// @notice Window start time for deposits: subAccount => target address => timestamp
    mapping(address => mapping(address => uint256)) public depositWindowStart;

    /// @notice Window start time for withdrawals: subAccount => target address => timestamp
    mapping(address => mapping(address => uint256)) public withdrawWindowStart;

    /// @notice Safe's balance at start of deposit window: subAccount => sd address => balance
    mapping(address => mapping(address => uint256)) public depositWindowBalance;

    /// @notice Safe's shares at start of withdraw window: subAccount => target address => shares
    mapping(address => mapping(address => uint256)) public withdrawWindowShares;

    /// @notice Cumulative transfers in current window: subAccount => token address => amount
    mapping(address => mapping(address => uint256)) public transferredInWindow;

    /// @notice Window start time for transfers: subAccount => token address => timestamp
    mapping(address => mapping(address => uint256)) public transferWindowStart;

    /// @notice Safe's balance at start of transfer window: subAccount => token address => balance
    mapping(address => mapping(address => uint256)) public transferWindowBalance;

    // ============ Events ============

    event DepositExecuted(
        address indexed subAccount,
        address indexed target,
        uint256 assets,
        uint256 actualSharesReceived,
        uint256 safeBalanceBefore,
        uint256 safeBalanceAfter,
        uint256 cumulativeInWindow,
        uint256 percentageOfBalance,
        uint256 timestamp
    );

    event WithdrawExecuted(
        address indexed subAccount,
        address indexed target,
        uint256 assets,
        uint256 actualSharesBurned,
        uint256 safeSharesBefore,
        uint256 safeSharesAfter,
        uint256 cumulativeInWindow,
        uint256 percentageOfPosition,
        uint256 timestamp
    );

    event RoleAssigned(address indexed member, uint16 indexed roleId, uint256 timestamp);
    event RoleRevoked(address indexed member, uint16 indexed roleId, uint256 timestamp);
    event DepositWindowReset(address indexed subAccount, address indexed target, uint256 newWindowStart);
    event WithdrawWindowReset(address indexed subAccount, address indexed target, uint256 newWindowStart);
    event SubAccountLimitsSet(
        address indexed subAccount,
        uint256 maxDepositBps,
        uint256 maxWithdrawBps,
        uint256 maxLossBps,
        uint256 windowDuration,
        uint256 timestamp
    );

    event ProtocolExecuted(
        address indexed subAccount,
        address indexed target,
        uint256 portfolioValueBefore,
        uint256 portfolioValueAfter,
        uint256 valueLost,
        uint256 cumulativeLossInWindow,
        uint256 timestamp
    );

    event ExecutionWindowReset(
        address indexed subAccount,
        uint256 newWindowStart,
        uint256 portfolioValue
    );

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event TrackedTokenAdded(address indexed token);
    event TrackedTokenRemoved(address indexed token);
    event TrackedProtocolAdded(address indexed protocol);
    event TrackedProtocolRemoved(address indexed protocol);

    event AllowedAddressesSet(
        address indexed subAccount,
        address[] targets,
        bool allowed,
        uint256 timestamp
    );

    event TransferExecuted(
        address indexed subAccount,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint256 safeBalanceBefore,
        uint256 safeBalanceAfter,
        uint256 cumulativeInWindow,
        uint256 percentageOfBalance,
        uint256 timestamp
    );

    event TransferWindowReset(address indexed subAccount, address indexed token, uint256 newWindowStart);

    event EmergencyPaused(address indexed by, uint256 timestamp);
    event EmergencyUnpaused(address indexed by, uint256 timestamp);

    event UnusualActivity(
        address indexed subAccount,
        string activityType,
        uint256 value,
        uint256 threshold,
        uint256 timestamp
    );

    event ApprovalExecuted(
        address indexed subAccount,
        address indexed token,
        address indexed protocol,
        uint256 amount,
        uint256 timestamp
    );

    error Unauthorized();
    error InvalidAddress();
    error ExceedsDepositLimit();
    error ExceedsWithdrawLimit();
    error TransactionFailed();
    error ApprovalFailed();
    error InsufficientSharesReceived();
    error InsufficientAssetsReceived();
    error ExceedsAbsoluteMaximum();
    error OperationNotScheduled();
    error OperationTooEarly();
    error OperationExpired();
    error OperationAlreadyExecuted();
    error InvalidLimitConfiguration();
    error AddressNotAllowed();
    error ExceedsMaxLoss();
    error OracleNotSet();
    error NoTrackedTokens();
    error ApprovalNotAllowed();
    error ApprovalExceedsLimit();
    error ExceedsTransferLimit();

    modifier onlySafe() {
        if (msg.sender != address(safe)) revert Unauthorized();
        _;
    }

    constructor(address _safe, address _rolesModifier) {
        if (_safe == address(0) || _rolesModifier == address(0)) revert InvalidAddress();
        safe = ISafe(_safe);
        rolesModifier = IZodiacRoles(_rolesModifier);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all operations (only Safe can call)
     */
    function pause() external onlySafe {
        _pause();
        emit EmergencyPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Unpause all operations (only Safe can call)
     */
    function unpause() external onlySafe {
        _unpause();
        emit EmergencyUnpaused(msg.sender, block.timestamp);
    }

    // ============ Oracle & Token Management ============

    /**
     * @notice Set the price oracle (only Safe can call)
     * @param _oracle The price oracle address
     */
    function setOracle(address _oracle) external onlySafe {
        if (_oracle == address(0)) revert InvalidAddress();
        address oldOracle = address(priceOracle);
        priceOracle = IPriceOracle(_oracle);
        emit OracleUpdated(oldOracle, _oracle);
    }

    /**
     * @notice Add a token to track for portfolio valuation (only Safe can call)
     * @param token The token address to track
     */
    function addTrackedToken(address token) external onlySafe {
        if (token == address(0)) revert InvalidAddress();
        if (!isTrackedToken[token]) {
            trackedTokens.push(token);
            isTrackedToken[token] = true;
            emit TrackedTokenAdded(token);
        }
    }

    /**
     * @notice Remove a token from tracking (only Safe can call)
     * @param token The token address to remove
     */
    function removeTrackedToken(address token) external onlySafe {
        if (isTrackedToken[token]) {
            isTrackedToken[token] = false;
            // Remove from array
            for (uint256 i = 0; i < trackedTokens.length; i++) {
                if (trackedTokens[i] == token) {
                    trackedTokens[i] = trackedTokens[trackedTokens.length - 1];
                    trackedTokens.pop();
                    break;
                }
            }
            emit TrackedTokenRemoved(token);
        }
    }

    /**
     * @notice Add a protocol to track for portfolio valuation (only Safe can call)
     * @param protocol The protocol address to track (e.g., Morpho vault address)
     */
    function addTrackedProtocol(address protocol) external onlySafe {
        if (protocol == address(0)) revert InvalidAddress();
        if (!isTrackedProtocol[protocol]) {
            trackedProtocols.push(protocol);
            isTrackedProtocol[protocol] = true;
            emit TrackedProtocolAdded(protocol);
        }
    }

    /**
     * @notice Remove a protocol from tracking (only Safe can call)
     * @param protocol The protocol address to remove
     */
    function removeTrackedProtocol(address protocol) external onlySafe {
        if (isTrackedProtocol[protocol]) {
            isTrackedProtocol[protocol] = false;
            // Remove from array
            for (uint256 i = 0; i < trackedProtocols.length; i++) {
                if (trackedProtocols[i] == protocol) {
                    trackedProtocols[i] = trackedProtocols[trackedProtocols.length - 1];
                    trackedProtocols.pop();
                    break;
                }
            }
            emit TrackedProtocolRemoved(protocol);
        }
    }

    /**
     * @notice Calculate the total portfolio value of the Safe
     * @return totalValue The total value in USD (18 decimals)
     */
    function getPortfolioValue() public view returns (uint256 totalValue) {
        if (address(priceOracle) == address(0)) revert OracleNotSet();
        if (trackedTokens.length == 0 && trackedProtocols.length == 0) revert NoTrackedTokens();

        // Value from token balances (USDC, WETH, etc.)
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            address token = trackedTokens[i];
            uint256 balance = IERC20(token).balanceOf(address(safe));
            if (balance > 0) {
                totalValue += priceOracle.getValue(token, balance);
            }
        }

        // Value from protocol positions (Morpho vaults, Aave, etc.)
        for (uint256 i = 0; i < trackedProtocols.length; i++) {
            address protocol = trackedProtocols[i];
            totalValue += priceOracle.getPositionValue(protocol, address(safe));
        }
    }

    /**
     * @notice Get the number of tracked tokens
     * @return count The number of tracked tokens
     */
    function getTrackedTokenCount() external view returns (uint256) {
        return trackedTokens.length;
    }

    /**
     * @notice Get the number of tracked protocols
     * @return count The number of tracked protocols
     */
    function getTrackedProtocolCount() external view returns (uint256) {
        return trackedProtocols.length;
    }

    // ============ Sub-Account Configuration ============

    /**
     * @notice Set custom limits for a sub-account (only Safe can call)
     * @param subAccount The sub-account address to configure
     * @param maxDepositBps Maximum deposit percentage in basis points (max 10000)
     * @param maxWithdrawBps Maximum withdrawal percentage in basis points (max 10000)
     * @param maxLossBps Maximum portfolio loss percentage in basis points (max 10000)
     * @param windowDuration Time window duration in seconds (min 1 hour)
     */
    function setSubAccountLimits(
        address subAccount,
        uint256 maxDepositBps,
        uint256 maxWithdrawBps,
        uint256 maxLossBps,
        uint256 windowDuration
    ) external onlySafe {
        if (subAccount == address(0)) revert InvalidAddress();
        // Validate limits: BPS cannot exceed 100%, window must be at least 1 hour
        if (maxDepositBps > 10000 || maxWithdrawBps > 10000 || maxLossBps > 10000 || windowDuration < 1 hours) {
            revert InvalidLimitConfiguration();
        }

        subAccountLimits[subAccount] = SubAccountLimits({
            maxDepositBps: maxDepositBps,
            maxWithdrawBps: maxWithdrawBps,
            maxLossBps: maxLossBps,
            windowDuration: windowDuration,
            isConfigured: true
        });

        emit SubAccountLimitsSet(
            subAccount,
            maxDepositBps,
            maxWithdrawBps,
            maxLossBps,
            windowDuration,
            block.timestamp
        );
    }

    /**
     * @notice Get the effective limits for a sub-account
     * @param subAccount The sub-account address
     * @return maxDepositBps The maximum deposit percentage in basis points
     * @return maxWithdrawBps The maximum withdrawal percentage in basis points
     * @return maxLossBps The maximum portfolio loss percentage in basis points
     * @return windowDuration The time window duration in seconds
     */
    function getSubAccountLimits(address subAccount) public view returns (
        uint256 maxDepositBps,
        uint256 maxWithdrawBps,
        uint256 maxLossBps,
        uint256 windowDuration
    ) {
        SubAccountLimits memory limits = subAccountLimits[subAccount];
        if (limits.isConfigured) {
            return (limits.maxDepositBps, limits.maxWithdrawBps, limits.maxLossBps, limits.windowDuration);
        }
        // Return defaults if not configured
        return (DEFAULT_MAX_DEPOSIT_BPS, DEFAULT_MAX_WITHDRAW_BPS, DEFAULT_MAX_LOSS_BPS, DEFAULT_LIMIT_WINDOW_DURATION);
    }

    /**
     * @notice Set allowed addresses for a sub-account (only Safe can call)
     * @param subAccount The sub-account address to configure
     * @param targets Array of target addresses to allow/disallow
     * @param allowed Whether to allow or disallow these addresses
     */
    function setAllowedAddresses(
        address subAccount,
        address[] calldata targets,
        bool allowed
    ) external onlySafe {
        if (subAccount == address(0)) revert InvalidAddress();

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) revert InvalidAddress();
            allowedAddresses[subAccount][targets[i]] = allowed;
        }

        emit AllowedAddressesSet(subAccount, targets, allowed, block.timestamp);
    }

    // ============ Core Functions with Enhanced Security ============

    /**
     * @notice Deposit assets into a SC with role-based restrictions
     * @param target The target address
     * @param assets Amount of assets to deposit
     * @param receiver Address that will receive the shares
     * @param minShares Minimum shares to receive
     * @return actualShares Amount of shares actually received
     */
    function depositTo(
        address target,
        uint256 assets,
        address receiver,
        uint256 minShares
    ) external nonReentrant whenNotPaused returns (uint256 actualShares) {
        // Check role permission
        if (!rolesModifier.hasRole(msg.sender, DEFI_DEPOSIT_ROLE)) revert Unauthorized();

        // Check if address is allowed for this sub-account
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        IMorphoVault morphoVault = IMorphoVault(target);
        address asset = morphoVault.asset();
        IERC20 token = IERC20(asset);

        uint256 safeBalanceBefore = token.balanceOf(address(safe));

        // Get sub-account specific limits
        (uint256 maxDepositBps, , , uint256 windowDuration) = getSubAccountLimits(msg.sender);

        // Reset window if expired or first time
        if (block.timestamp >= depositWindowStart[msg.sender][target] + windowDuration ||
            depositWindowStart[msg.sender][target] == 0) {
            depositedInWindow[msg.sender][target] = 0;
            depositWindowStart[msg.sender][target] = block.timestamp;
            depositWindowBalance[msg.sender][target] = safeBalanceBefore;
            emit DepositWindowReset(msg.sender, target, block.timestamp);
        }

        // Calculate cumulative limit based on balance at window start
        uint256 windowBalance = depositWindowBalance[msg.sender][target];
        uint256 cumulativeDeposit = depositedInWindow[msg.sender][target] + assets;
        uint256 maxDeposit = Math.mulDiv(windowBalance, maxDepositBps, 10000, Math.Rounding.Floor);

        if (cumulativeDeposit > maxDeposit) revert ExceedsDepositLimit();

        // Calculate percentage for monitoring
        uint256 percentageOfBalance = Math.mulDiv(assets, 10000, safeBalanceBefore, Math.Rounding.Floor);

        // Alert on unusual activity (>8% in single transaction)
        if (percentageOfBalance > 800) {
            emit UnusualActivity(
                msg.sender,
                "Large deposit percentage",
                percentageOfBalance,
                800,
                block.timestamp
            );
        }

        uint256 sharesBefore = morphoVault.balanceOf(receiver);

        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector,
            target,
            assets
        );

        uint256 allowanceBefore = token.allowance(address(safe), target);

        // Execute approval through Zodiac Roles -> Safe
        bool approveSuccess = rolesModifier.execTransactionWithRole(
            asset,
            0,
            approveData,
            0,
            DEFI_DEPOSIT_ROLE,
            true
        );

        if (!approveSuccess) revert TransactionFailed();

        uint256 allowanceAfter = token.allowance(address(safe), target);
        if (allowanceAfter < allowanceBefore + assets) revert ApprovalFailed();

        // Execute deposit
        bytes memory depositData = abi.encodeWithSelector(
            IMorphoVault.deposit.selector,
            assets,
            receiver
        );

        // Execute deposit through Zodiac Roles -> Safe
        bool depositSuccess = rolesModifier.execTransactionWithRole(
            target,
            0,
            depositData,
            0,
            DEFI_DEPOSIT_ROLE,
            true
        );

        if (!depositSuccess) revert TransactionFailed();

        // Verify actual shares received
        uint256 sharesAfter = morphoVault.balanceOf(receiver);
        actualShares = sharesAfter - sharesBefore;

        if (actualShares < minShares) revert InsufficientSharesReceived();

        // Update cumulative tracking
        depositedInWindow[msg.sender][target] = cumulativeDeposit;

        // Get balance after for monitoring
        uint256 safeBalanceAfter = token.balanceOf(address(safe));

        // Comprehensive monitoring event
        emit DepositExecuted(
            msg.sender,
            target,
            assets,
            actualShares,
            safeBalanceBefore,
            safeBalanceAfter,
            cumulativeDeposit,
            percentageOfBalance,
            block.timestamp
        );

        return actualShares;
    }

    /**
     * @notice Withdraw assets from a sc with role-based restrictions
     * @param target The target address
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets
     * @param owner Address of the share owner
     * @param maxShares Maximum shares to burn
     * @return actualShares Amount of shares actually burned
     */
    function withdrawFrom(
        address target,
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxShares
    ) external nonReentrant whenNotPaused returns (uint256 actualShares) {
        // Check role permission
        if (!rolesModifier.hasRole(msg.sender, DEFI_WITHDRAW_ROLE)) revert Unauthorized();

        // Check if address is allowed for this sub-account
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        IMorphoVault morphoVault = IMorphoVault(target);
        uint256 safeSharesBefore = morphoVault.balanceOf(address(safe));
        uint256 safeAssetValue = morphoVault.convertToAssets(safeSharesBefore);

        // Get sub-account specific limits
        (, uint256 maxWithdrawBps, , uint256 windowDuration) = getSubAccountLimits(msg.sender);

        // Reset window if expired or first time
        if (block.timestamp >= withdrawWindowStart[msg.sender][target] + windowDuration ||
            withdrawWindowStart[msg.sender][target] == 0) {
            withdrawnInWindow[msg.sender][target] = 0;
            withdrawWindowStart[msg.sender][target] = block.timestamp;
            withdrawWindowShares[msg.sender][target] = safeAssetValue;
            emit WithdrawWindowReset(msg.sender, target, block.timestamp);
        }

        // Calculate cumulative limit based on shares at window start
        uint256 windowAssetValue = withdrawWindowShares[msg.sender][target];
        uint256 cumulativeWithdraw = withdrawnInWindow[msg.sender][target] + assets;
        uint256 maxWithdraw = Math.mulDiv(windowAssetValue, maxWithdrawBps, 10000, Math.Rounding.Floor);

        if (cumulativeWithdraw > maxWithdraw) revert ExceedsWithdrawLimit();

        // Calculate percentage for monitoring
        uint256 percentageOfPosition = Math.mulDiv(assets, 10000, safeAssetValue, Math.Rounding.Floor);

        // Alert on unusual activity (>4% in single transaction)
        if (percentageOfPosition > 400) {
            emit UnusualActivity(
                msg.sender,
                "Large withdrawal percentage",
                percentageOfPosition,
                400,
                block.timestamp
            );
        }

        address asset = morphoVault.asset();
        IERC20 token = IERC20(asset);
        uint256 assetsBefore = token.balanceOf(receiver);
        uint256 sharesBefore = morphoVault.balanceOf(owner);

        // Execute withdrawal
        bytes memory data = abi.encodeWithSelector(
            IMorphoVault.withdraw.selector,
            assets,
            receiver,
            owner
        );

        bool success = rolesModifier.execTransactionWithRole(
            target,
            0,
            data,
            0,
            DEFI_WITHDRAW_ROLE,
            true
        );

        if (!success) revert TransactionFailed();

        return 0;
    }

    // ============ Role Management ============

    /**
     * @notice Grant a role to a sub-account (only Safe can do this)
     * @param member The address to grant the role to
     * @param roleId The role ID to grant
     */
    function grantRole(address member, uint16 roleId) external onlySafe {
        if (member == address(0)) revert InvalidAddress();

        uint16[] memory roleIds = new uint16[](1);
        roleIds[0] = roleId;

        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        rolesModifier.assignRoles(member, roleIds, memberOf);

        emit RoleAssigned(member, roleId, block.timestamp);
    }

    /**
     * @notice Revoke a role from a sub-account (only Safe can do this)
     * @param member The address to revoke the role from
     * @param roleId The role ID to revoke
     */
    function revokeRole(address member, uint16 roleId) external onlySafe {
        if (member == address(0)) revert InvalidAddress();

        uint16[] memory roleIds = new uint16[](1);
        roleIds[0] = roleId;

        rolesModifier.revokeRoles(member, roleIds);

        emit RoleRevoked(member, roleId, block.timestamp);
    }

    /**
     * @notice Check if an address has a specific role
     * @param member The address to check
     * @param roleId The role ID to check
     * @return bool Whether the address has the role
     */
    function hasRole(address member, uint16 roleId) external view returns (bool) {
        return rolesModifier.hasRole(member, roleId);
    }
}
