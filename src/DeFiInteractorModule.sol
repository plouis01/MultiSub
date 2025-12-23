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
        OperationType opType,
        address[] tokensOut,
        uint256[] amountsOut
    );

    event SelectorRegistered(bytes4 indexed selector, OperationType opType);
    event SelectorUnregistered(bytes4 indexed selector);
    event ParserRegistered(address indexed protocol, address parser);

    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    // ============ Errors ============

    error UnknownSelector(bytes4 selector);
    error UnsupportedOperation(OperationType opType);
    error TransactionFailed();
    error AddressNotAllowed();
    error NoParserRegistered(address target);
    error CannotRegisterUnknown();
    error CannotRegisterUnsupported();
    error InvalidRecipient(address recipient, address expected);
    error CannotBeSubaccount(address account);
    error CannotWhitelistCoreAddress(address account);
    error CannotRegisterParserForCoreAddress(address account);

    // ============ Constructor ============

    /**
     * @notice Initialize the DeFi Interactor Module (Claim-Only)
     * @param _avatar The Safe address (avatar)
     * @param _owner The owner address (typically the Safe itself)
     */
    constructor(address _avatar, address _owner)
        Module(_avatar, _avatar, _owner)
    {}

    // ============ Emergency Controls ============

    function pause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    // ============ Role Management ============

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

    function revokeRole(address member, uint16 roleId) external onlyOwner {
        if (member == address(0)) revert InvalidAddress();
        if (subAccountRoles[member][roleId]) {
            subAccountRoles[member][roleId] = false;
            _removeFromSubaccountArray(roleId, member);
            emit RoleRevoked(member, roleId);
        }
    }

    function _removeFromSubaccountArray(uint16 roleId, address member) internal {
        address[] storage accounts = subaccounts[roleId];
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; i++) {
            if (accounts[i] == member) {
                accounts[i] = accounts[length - 1];
                accounts.pop();
                break;
            }
        }
    }

    function hasRole(address member, uint16 roleId) public view returns (bool) {
        return subAccountRoles[member][roleId];
    }

    function getSubaccountsByRole(uint16 roleId) external view returns (address[] memory) {
        return subaccounts[roleId];
    }

    function getSubaccountCount(uint16 roleId) external view returns (uint256) {
        return subaccounts[roleId].length;
    }

    // ============ Selector Registry ============

    /**
     * @notice Register a function selector with its operation type
     * @param selector The function selector (first 4 bytes of calldata)
     * @param opType The operation type classification (only CLAIM allowed)
     */
    function registerSelector(bytes4 selector, OperationType opType) external onlyOwner {
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
     * @param parser The parser contract address
     */
    function registerParser(address protocol, address parser) external onlyOwner {
        // Prevent registering parser for Safe or Module
        if (protocol == avatar || protocol == address(this)) revert CannotRegisterParserForCoreAddress(protocol);
        protocolParsers[protocol] = ICalldataParser(parser);
        emit ParserRegistered(protocol, parser);
    }

    // ============ Sub-Account Configuration ============

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
     * @param data The calldata to execute
     * @dev Only CLAIM operations are supported
     */
    function executeOnProtocol(
        address target,
        bytes calldata data
    ) external nonReentrant whenNotPaused returns (bytes memory) {
        // 1. Validate permissions
        if (!hasRole(msg.sender, CLAIM_ROLE)) revert Unauthorized();

        // 2. Validate target is whitelisted
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        // 3. Classify operation
        OperationType opType = _classifyOperation(target, data);

        // 4. Only allow CLAIM
        if (opType == OperationType.UNKNOWN) {
            revert UnknownSelector(bytes4(data[:4]));
        }
        if (opType != OperationType.CLAIM) {
            revert UnsupportedOperation(opType);
        }

        // 5. Execute the claim
        return _executeClaim(msg.sender, target, data, opType);
    }

    // ============ Operation Classification ============

    /**
     * @notice Classify the operation type from calldata
     * @param target The protocol address being called
     * @param data The calldata to analyze
     * @return opType The operation type
     */
    function _classifyOperation(address target, bytes calldata data) internal view returns (OperationType) {
        ICalldataParser parser = protocolParsers[target];

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
        OperationType opType
    ) internal returns (bytes memory) {
        // 1. Parser is required to track output tokens and validate recipient
        ICalldataParser parser = protocolParsers[target];
        if (address(parser) == address(0)) {
            revert NoParserRegistered(target);
        }

        // 2. Validate recipient is the Safe to prevent fund theft
        address recipient = parser.extractRecipient(target, data, avatar);
        if (recipient != avatar) {
            revert InvalidRecipient(recipient, avatar);
        }

        // 3. Get output tokens from parser
        address[] memory tokensOut = parser.extractOutputTokens(target, data);
        uint256[] memory balancesBefore = new uint256[](tokensOut.length);
        uint256 len = tokensOut.length;
        for (uint256 i = 0; i < len; ) {
            if (tokensOut[i] != address(0)) {
                balancesBefore[i] = _getTokenBalance(tokensOut[i]);
            }
            unchecked { ++i; }
        }

        // 4. Execute
        bool success = exec(target, 0, data, ISafe.Operation.Call);
        if (!success) revert TransactionFailed();

        // 5. Calculate received amounts
        uint256[] memory amountsOut = new uint256[](tokensOut.length);
        for (uint256 i = 0; i < len; ) {
            if (tokensOut[i] != address(0)) {
                uint256 balanceAfter = _getTokenBalance(tokensOut[i]);
                amountsOut[i] = balanceAfter >= balancesBefore[i] ? balanceAfter - balancesBefore[i] : 0;
            }
            unchecked { ++i; }
        }

        // 6. Emit event
        emit ProtocolExecution(
            subAccount,
            target,
            opType,
            tokensOut,
            amountsOut
        );

        return "";
    }

    // ============ Internal Helpers ============

    function _getTokenBalance(address token) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", avatar)
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 0;
    }
}
