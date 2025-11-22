// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMorphoVault} from "./interfaces/IMorphoVault.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IZodiacRoles} from "./interfaces/IZodiacRoles.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeFiInteractor
 * @notice Contract for executing DeFi operations through Safe+Zodiac with restrictions
 * @dev Sub-accounts interact with this contract which enforces role-based permissions
 */
contract DeFiInteractor {
    /// @notice The Safe multisig that owns the assets
    ISafe public immutable safe;

    /// @notice The Zodiac Roles modifier for access control
    IZodiacRoles public immutable rolesModifier;

    /// @notice Role ID for basic DeFi operations (deposits)
    uint16 public constant DEFI_DEPOSIT_ROLE = 1;

    /// @notice Role ID for withdrawal operations (more restricted)
    uint16 public constant DEFI_WITHDRAW_ROLE = 2;

    /// @notice Per-sub-account allowed addresses: subAccount => target address => allowed
    mapping(address => mapping(address => bool)) public allowedAddresses;

    // ============ Events ============

    event RoleAssigned(address indexed member, uint16 indexed roleId, uint256 timestamp);
    event RoleRevoked(address indexed member, uint16 indexed roleId, uint256 timestamp);

    error Unauthorized();
    error InvalidAddress();
    error TransactionFailed();
    error AddressNotAllowed();

    modifier onlySafe() {
        if (msg.sender != address(safe)) revert Unauthorized();
        _;
    }

    constructor(address _safe, address _rolesModifier) {
        if (_safe == address(0) || _rolesModifier == address(0)) revert InvalidAddress();
        safe = ISafe(_safe);
        rolesModifier = IZodiacRoles(_rolesModifier);
    }

    // ============ Core Functions with Enhanced Security ============

    /**
     * @notice Deposit assets into a SC with role-based restrictions
     * @param target The target address
     * @param assets Amount of assets to deposit
     * @param receiver Address that will receive the shares
     * @return actualShares Amount of shares actually received
     */
    function depositTo(
        address target,
        uint256 assets,
        address receiver,
    ) external returns (uint256 actualShares) {
        // Check role permission
        if (!rolesModifier.hasRole(msg.sender, DEFI_DEPOSIT_ROLE)) revert Unauthorized();

        // Check if address is allowed for this sub-account
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        IMorphoVault morphoVault = IMorphoVault(target);

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

        return 0;
    }

    /**
     * @notice Withdraw assets from a sc with role-based restrictions
     * @param target The target address
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets
     * @param owner Address of the share owner
     * @return actualShares Amount of shares actually burned
     */
    function withdrawFrom(
        address target,
        uint256 assets,
        address receiver,
        address owner,
    ) external returns (uint256 actualShares) {
        // Check role permission
        if (!rolesModifier.hasRole(msg.sender, DEFI_WITHDRAW_ROLE)) revert Unauthorized();

        // Check if address is allowed for this sub-account
        if (!allowedAddresses[msg.sender][target]) revert AddressNotAllowed();

        IMorphoVault morphoVault = IMorphoVault(target);

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
