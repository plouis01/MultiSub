// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Module} from "./base/Module.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ICalldataParser} from "./interfaces/ICalldataParser.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title DeFiInteractorModule (Claim-Only Version)
 * @notice Simplified Zodiac module for claiming rewards from DeFi protocols
 * @dev This version only supports CLAIM operations:
 *      - Subaccounts can only claim rewards from whitelisted protocols
 *      - All claimed tokens go to the Safe (recipient validation enforced)
 */
contract DeFiInteractorModule is Module, ReentrancyGuard, Pausable {
    // ============ Constants ============

    /// @notice Role ID for claim execution
    uint16 public constant CLAIM_ROLE = 1;

    /// @notice ERC20 balanceOf selector
    bytes4 private constant BALANCE_OF_SELECTOR = 0x70a08231;

    // ============ Operation Type Classification ============

    /// @notice Operation types for selector-based classification
    enum OperationType {
        UNKNOWN,    // Must revert - unregistered selector
        CLAIM       // Supported - claim rewards only
    }

    /// @notice Registered operation type for each function selector
    mapping(bytes4 => OperationType) public selectorType;

    /// @notice Parser contract for each protocol
    mapping(address => ICalldataParser) public protocolParsers;

    // ============ Sub-Account Configuration ============

    /// @notice Per-sub-account allowed addresses: subAccount => target => allowed
    mapping(address => mapping(address => bool)) public allowedAddresses;

    /// @notice Sub-account roles: subAccount => role => has role
    mapping(address => mapping(uint16 => bool)) public subAccountRoles;

    /// @notice Role members: role => subAccount[]
    mapping(uint16 => address[]) public subaccounts;

    // ============ Events ============

    event RoleAssigned(address indexed member, uint16 indexed roleId);
    event RoleRevoked(address indexed member, uint16 indexed roleId);

    event AllowedAddressesSet(
        address indexed subAccount,
        address[] targets,
        bool allowed
    );

    /// @notice Emitted on every protocol interaction
    event ProtocolExecution(
        address indexed subAccount,
        address indexed target,
        OperationType opType
    );

    event SelectorRegistered(bytes4 indexed selector, OperationType opType);
    event SelectorUnregistered(bytes4 indexed selector);
    event ParserRegistered(address indexed protocol, address indexed parser);

    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    // ============ Errors ============

    error UnknownSelector(bytes4 selector);
    error UnsupportedOperation(OperationType opType);
    error TransactionFailed();
    error TokenLost();
    error AddressNotAllowed();
    error NoParserRegistered(address target);
    error CannotRegisterUnsupported();
    error InvalidRecipient(address recipient, address expected);
    error CannotBeSubaccount(address account);
    error CannotWhitelistCoreAddress(address account);
    error CannotRegisterParserForCoreAddress(address account);
    error InvalidSelector();
    error InvalidCalldata();

    // ============ Constructor ============

    /**
     * @notice Initialize the DeFi Interactor Module (Claim-Only)
     * @param _avatar The Safe address (avatar)
     * @param _owner The owner address (typically the Safe itself)
     */
    constructor(address _avatar, address _owner)
        Module(_avatar, _owner)
    {}

    // ============ Emergency Controls ============

    /**
     * @notice Pause all claim operations
     * @dev Only callable by owner. Use in case of emergency.
     */
    function pause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @notice Unpause claim operations
     * @dev Only callable by owner.
     */
    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    // ============ Role Management ============

    /**
     * @notice Grant a role to a subaccount
     * @param member The address to grant the role to
     * @param roleId The role identifier (use CLAIM_ROLE for claim permissions)
     */
    function grantRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();
        // Prevent Safe and Module from being subaccounts
        if (member == avatar || member == address(this)) revert CannotBeSubaccount(member);
        if (!subAccountRoles[member][roleId]) {
            subAccountRoles[member][roleId] = true;
            subaccounts[roleId].push(member);
            emit RoleAssigned(member, roleId);
        }
    }

    /**
     * @notice Revoke a role from a subaccount
     * @param member The address to revoke the role from
     * @param roleId The role identifier to revoke
     */
    function revokeRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();
        if (subAccountRoles[member][roleId]) {
            subAccountRoles[member][roleId] = false;
            _removeFromSubaccountArray(roleId, member);
            emit RoleRevoked(member, roleId);
        }
    }

    /**
     * @notice Get all subaccounts with a specific role
     * @param roleId The role identifier to query
     * @return Array of addresses with the specified role
     */
    function getSubaccountsByRole(uint16 roleId) external view returns (address[] memory) {
        return subaccounts[roleId];
    }

    /**
     * @notice Get the count of subaccounts with a specific role
     * @param roleId The role identifier to query
     * @return Number of subaccounts with the specified role
     */
    function getSubaccountCount(uint16 roleId) external view returns (uint256) {
        return subaccounts[roleId].length;
    }

    /**
     * @notice Check if an address has a specific role
     * @param member The address to check
     * @param roleId The role identifier to check for
     * @return True if the member has the role
     */
    function hasRole(address member, uint16 roleId) public view returns (bool) {
        return subAccountRoles[member][roleId];
    }

    // ============ Selector Registry ============

    /**
     * @notice Register a function selector with its operation type
     * @param selector The function selector (first 4 bytes of calldata)
     * @param opType The operation type classification (only CLAIM allowed)
     */
    function registerSelector(bytes4 selector, OperationType opType) external onlyOwner {
        if (selector == bytes4(0)) revert InvalidSelector();
        // Only allow CLAIM in claim-only version
        if (opType != OperationType.CLAIM) {
            revert CannotRegisterUnsupported();
        }
        selectorType[selector] = opType;
        emit SelectorRegistered(selector, opType);
    }

    /**
     * @notice Unregister a function selector
     * @param selector The function selector to unregister
     */
    function unregisterSelector(bytes4 selector) external onlyOwner {
        delete selectorType[selector];
        emit SelectorUnregistered(selector);
    }

    /**
     * @notice Register a parser for a protocol
     * @param protocol The protocol address
     * @param parser The parser contract address (use address(0) to unregister)
     */
    function registerParser(address protocol, address parser) external onlyOwner {
        if (protocol == address(0)) revert InvalidAddress();
        // Prevent registering parser for Safe or Module
        if (protocol == avatar || protocol == address(this)) revert CannotRegisterParserForCoreAddress(protocol);
        protocolParsers[protocol] = ICalldataParser(parser);
        emit ParserRegistered(protocol, parser);
    }

    // ============ Sub-Account Configuration ============

    /**
     * @notice Set allowed target addresses for a subaccount
     * @param subAccount The subaccount to configure
     * @param targets Array of protocol addresses to allow or disallow
     * @param allowed True to allow, false to disallow
     */
    function setAllowedAddresses(
        address subAccount,
        address[] calldata targets,
        bool allowed
    ) external onlyOwner {
        if (subAccount == address(0)) revert InvalidAddress();
        uint256 len = targets.length;
        for (uint256 i = 0; i < len; ) {
            // Prevent whitelisting Safe or Module as targets
            if (targets[i] == avatar || targets[i] == address(this)) revert CannotWhitelistCoreAddress(targets[i]);
            if (targets[i] == address(0)) revert InvalidAddress();
            allowedAddresses[subAccount][targets[i]] = allowed;
            unchecked { ++i; }
        }
        emit AllowedAddressesSet(subAccount, targets, allowed);
    }

    // ============ Main Entry Point ============

    /**
     * @notice Execute a claim operation on a protocol
     * @param target The protocol address to call
     * @param data The calldata to execute (must be at least 4 bytes)
     * @dev Only CLAIM operations are supported
     */
    function executeOnProtocol(
        address target,
        bytes calldata data
    ) external nonReentrant whenNotPaused returns (bytes memory) {
        // Validate calldata has at least a selector
        if (data.length < 4) revert InvalidCalldata();

        // Validate permissions
        if (!hasRole(msg.sender, CLAIM_ROLE)) revert Unauthorized();

        // Validate target is whitelisted
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        // Cache parser to avoid double SLOAD
        ICalldataParser parser = protocolParsers[target];

        // Classify operation
        OperationType opType = _classifyOperation(parser, data);

        // Only allow CLAIM
        if (opType == OperationType.UNKNOWN) {
            revert UnknownSelector(bytes4(data[:4]));
        }
        if (opType != OperationType.CLAIM) {
            revert UnsupportedOperation(opType);
        }

        // Execute the claim
        return _executeClaim(msg.sender, target, data, opType, parser);
    }

    // ============ Operation Classification ============

    /**
     * @notice Classify the operation type from calldata
     * @param parser The parser for the protocol (can be zero address)
     * @param data The calldata to analyze
     * @return opType The operation type
     */
    function _classifyOperation(ICalldataParser parser, bytes calldata data) internal view returns (OperationType) {
        // If parser exists, use it for classification
        if (address(parser) != address(0)) {
            uint8 parserOpType = parser.getOperationType(data);
            if (parserOpType > 0 && parserOpType <= uint8(OperationType.CLAIM)) {
                return OperationType(parserOpType);
            }
        }

        // Fallback to selector-based classification
        bytes4 selector = bytes4(data[:4]);
        return selectorType[selector];
    }

    // ============ Claim Execution ============

    function _executeClaim(
        address subAccount,
        address target,
        bytes calldata data,
        OperationType opType,
        ICalldataParser parser
    ) internal returns (bytes memory) {
        // Parser is required to track output tokens and validate recipient
        if (address(parser) == address(0)) {
            revert NoParserRegistered(target);
        }

        // Validate recipient is the Safe to prevent fund theft
        address recipient = parser.extractRecipient(target, data, avatar);
        if (recipient != avatar) {
            revert InvalidRecipient(recipient, avatar);
        }

        // Get output tokens from parser
        address[] memory tokensOut = parser.extractOutputTokens(target, data);
        uint256[] memory balancesBefore = new uint256[](tokensOut.length);
        uint256 len = tokensOut.length;
        for (uint256 i = 0; i < len; ) {
            if (tokensOut[i] != address(0)) {
                balancesBefore[i] = _getTokenBalance(tokensOut[i]);
            }
            unchecked { ++i; }
        }

        // Execute
        bool success = exec(target, 0, data, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        // Calculate received amounts
        for (uint256 i = 0; i < len; ) {
            if (tokensOut[i] != address(0)) {
                uint256 balanceAfter = _getTokenBalance(tokensOut[i]);
                if (balanceAfter < balancesBefore[i]) revert TokenLost();
            }
            unchecked { ++i; }
        }

        // Emit event
        emit ProtocolExecution(
            subAccount,
            target,
            opType
        );

        return "";
    }

    // ============ Internal Helpers ============

    /// @dev Removes a member from the subaccounts array using swap-and-pop
    function _removeFromSubaccountArray(uint16 roleId, address member) internal {
        address[] storage accounts = subaccounts[roleId];
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; ) {
            if (accounts[i] == member) {
                accounts[i] = accounts[length - 1];
                accounts.pop();
                break;
            }
            unchecked { ++i; }
        }
    }

    /// @dev Gets the token balance of the avatar (Safe)
    function _getTokenBalance(address token) internal view returns (uint256) {
        (bool success, bytes memory returnData) = token.staticcall(
            abi.encodeWithSelector(BALANCE_OF_SELECTOR, avatar)
        );
        if (success && returnData.length >= 32) {
            return abi.decode(returnData, (uint256));
        }
        return 0;
    }
}
