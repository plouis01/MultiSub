// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SmartWallet.sol";

// Mock contracts for testing
contract MockZodiacRoles {
    mapping(address => mapping(uint16 => bool)) public roles;

    function assignRoles(
        address member,
        uint16[] calldata roleIds,
        bool[] calldata memberOf
    ) external {
        for (uint256 i = 0; i < roleIds.length; i++) {
            roles[member][roleIds[i]] = memberOf[i];
        }
    }

    function revokeRoles(address member, uint16[] calldata roleIds) external {
        for (uint256 i = 0; i < roleIds.length; i++) {
            roles[member][roleIds[i]] = false;
        }
    }

    function hasRole(address member, uint16 role) external view returns (bool) {
        return roles[member][role];
    }

    function execTransactionWithRole(
        address /* to */,
        uint256 /* value */,
        bytes calldata /* data */,
        uint8 /* operation */,
        uint16 /* roleId */,
        bool /* shouldRevert */
    ) external pure returns (bool) {
        // Just return success for tests
        return true;
    }
}

contract SmartWalletTest is Test {
    SmartWallet public wallet;
    address public safe;
    MockZodiacRoles public rolesModifier;
    address public subAccount;
    address public protocol;

    event SubAccountAdded(address indexed subAccount);
    event SubAccountRemoved(address indexed subAccount);
    event ProtocolWhitelisted(address indexed protocol);
    event ProtocolRemoved(address indexed protocol);
    event DelegatedTxExecuted(address indexed subAccount, address indexed target, bytes data, bool success, bytes returnData);

    function setUp() public {
        safe = address(0x1);
        rolesModifier = new MockZodiacRoles();
        subAccount = address(0x3);
        protocol = address(0x4);

        vm.prank(safe);
        wallet = new SmartWallet(safe, address(rolesModifier));
    }

    function testConstructor() public view {
        assertEq(wallet.safe(), safe);
        assertEq(wallet.rolesModifier(), address(rolesModifier));
    }

    function testConstructorInvalidAddress() public {
        vm.expectRevert(SmartWallet.InvalidAddress.selector);
        new SmartWallet(address(0), address(rolesModifier));

        vm.expectRevert(SmartWallet.InvalidAddress.selector);
        new SmartWallet(safe, address(0));
    }

    function testAddSubAccount() public {
        vm.prank(safe);
        vm.expectEmit(true, false, false, false);
        emit SubAccountAdded(subAccount);
        wallet.addSubAccount(subAccount);

        assertTrue(wallet.isSubAccount(subAccount));
    }

    function testAddSubAccountUnauthorized() public {
        vm.prank(address(0x999));
        vm.expectRevert(SmartWallet.Unauthorized.selector);
        wallet.addSubAccount(subAccount);
    }

    function testRemoveSubAccount() public {
        vm.startPrank(safe);
        wallet.addSubAccount(subAccount);
        assertTrue(wallet.isSubAccount(subAccount));

        vm.expectEmit(true, false, false, false);
        emit SubAccountRemoved(subAccount);
        wallet.removeSubAccount(subAccount);
        vm.stopPrank();

        assertFalse(wallet.isSubAccount(subAccount));
    }

    function testWhitelistProtocol() public {
        vm.prank(safe);
        vm.expectEmit(true, false, false, false);
        emit ProtocolWhitelisted(protocol);
        wallet.whitelistProtocol(protocol);

        assertTrue(wallet.isWhitelisted(protocol));
    }

    function testWhitelistProtocolUnauthorized() public {
        vm.prank(address(0x999));
        vm.expectRevert(SmartWallet.Unauthorized.selector);
        wallet.whitelistProtocol(protocol);
    }

    function testRemoveProtocol() public {
        vm.startPrank(safe);
        wallet.whitelistProtocol(protocol);
        assertTrue(wallet.isWhitelisted(protocol));

        vm.expectEmit(true, false, false, false);
        emit ProtocolRemoved(protocol);
        wallet.removeProtocol(protocol);
        vm.stopPrank();

        assertFalse(wallet.isWhitelisted(protocol));
    }

    function testExecuteDelegatedTx() public {
        vm.startPrank(safe);
        wallet.addSubAccount(subAccount);
        wallet.whitelistProtocol(protocol);
        vm.stopPrank();

        bytes memory data = abi.encodeWithSignature("someFunction(uint256)", 123);

        vm.prank(subAccount);
        (bool success, ) = wallet.executeDelegatedTx(protocol, data);

        assertTrue(success);
    }

    function testExecuteDelegatedTxNotSubAccount() public {
        vm.prank(safe);
        wallet.whitelistProtocol(protocol);

        bytes memory data = abi.encodeWithSignature("someFunction(uint256)", 123);

        vm.prank(address(0x999));
        vm.expectRevert(SmartWallet.SubAccountNotEnabled.selector);
        wallet.executeDelegatedTx(protocol, data);
    }

    function testExecuteDelegatedTxProtocolNotWhitelisted() public {
        vm.prank(safe);
        wallet.addSubAccount(subAccount);

        bytes memory data = abi.encodeWithSignature("someFunction(uint256)", 123);

        vm.prank(subAccount);
        vm.expectRevert(SmartWallet.ProtocolNotWhitelisted.selector);
        wallet.executeDelegatedTx(protocol, data);
    }
}
