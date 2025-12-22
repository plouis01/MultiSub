// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeFiInteractorModule} from "../src/DeFiInteractorModule.sol";
import {Module} from "../src/base/Module.sol";
import {MockProtocol} from "./mocks/MockProtocol.sol";
import {DeFiInteractorModuleBase} from "./base/DeFiInteractorModuleBase.t.sol";

/**
 * @title DeFiInteractorModuleTest
 * @notice Tests for the claim-only DeFiInteractorModule
 */
contract DeFiInteractorModuleTest is DeFiInteractorModuleBase {

    function test_Constructor() public view {
        assertEq(module.avatar(), address(safe));
        assertEq(module.owner(), owner);
    }

    // ============ Role Management Tests ============

    function test_GrantRole() public {
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        assertTrue(module.hasRole(subAccount1, module.CLAIM_ROLE()));
    }

    function test_GrantRole_RevertsIfNotOwner() public {
        uint16 claimRole = module.CLAIM_ROLE();
        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.grantRole(subAccount2, claimRole);
    }

    function test_GrantRole_RevertsIfZeroAddress() public {
        uint16 claimRole = module.CLAIM_ROLE();
        vm.expectRevert(Module.InvalidAddress.selector);
        module.grantRole(address(0), claimRole);
    }

    function test_GrantRole_RevertsIfSafe() public {
        uint16 claimRole = module.CLAIM_ROLE();
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.CannotBeSubaccount.selector, address(safe)));
        module.grantRole(address(safe), claimRole);
    }

    function test_GrantRole_RevertsIfModule() public {
        uint16 claimRole = module.CLAIM_ROLE();
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.CannotBeSubaccount.selector, address(module)));
        module.grantRole(address(module), claimRole);
    }

    function test_RevokeRole() public {
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        module.revokeRole(subAccount1, module.CLAIM_ROLE());
        assertFalse(module.hasRole(subAccount1, module.CLAIM_ROLE()));
    }

    function test_GetSubaccountsByRole() public {
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        module.grantRole(subAccount2, module.CLAIM_ROLE());

        address[] memory subaccounts = module.getSubaccountsByRole(module.CLAIM_ROLE());
        assertEq(subaccounts.length, 2);
    }

    function test_SubaccountCount() public {
        assertEq(module.getSubaccountCount(module.CLAIM_ROLE()), 0);

        module.grantRole(subAccount1, module.CLAIM_ROLE());
        assertEq(module.getSubaccountCount(module.CLAIM_ROLE()), 1);

        module.grantRole(subAccount2, module.CLAIM_ROLE());
        assertEq(module.getSubaccountCount(module.CLAIM_ROLE()), 2);

        module.revokeRole(subAccount1, module.CLAIM_ROLE());
        assertEq(module.getSubaccountCount(module.CLAIM_ROLE()), 1);
    }

    // ============ Selector Registry Tests ============

    function test_RegisterSelector_Claim() public {
        bytes4 newSelector = bytes4(keccak256("newClaim()"));
        module.registerSelector(newSelector, DeFiInteractorModule.OperationType.CLAIM);
        assertEq(uint8(module.selectorType(newSelector)), uint8(DeFiInteractorModule.OperationType.CLAIM));
    }

    function test_RegisterSelector_RevertsForUnknown() public {
        bytes4 newSelector = bytes4(keccak256("newFunc()"));
        vm.expectRevert(DeFiInteractorModule.CannotRegisterUnknown.selector);
        module.registerSelector(newSelector, DeFiInteractorModule.OperationType.UNKNOWN);
    }

    function test_UnregisterSelector() public {
        module.unregisterSelector(CLAIM_SELECTOR);
        assertEq(uint8(module.selectorType(CLAIM_SELECTOR)), uint8(DeFiInteractorModule.OperationType.UNKNOWN));
    }

    // ============ Parser Registry Tests ============

    function test_RegisterParser() public {
        address newProtocol = makeAddr("newProtocol");
        address newParser = makeAddr("newParser");
        module.registerParser(newProtocol, newParser);
        assertEq(address(module.protocolParsers(newProtocol)), newParser);
    }

    function test_RegisterParser_RevertsForSafe() public {
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.CannotRegisterParserForCoreAddress.selector, address(safe)));
        module.registerParser(address(safe), address(parser));
    }

    function test_RegisterParser_RevertsForModule() public {
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.CannotRegisterParserForCoreAddress.selector, address(module)));
        module.registerParser(address(module), address(parser));
    }

    // ============ Allowed Addresses Tests ============

    function test_SetAllowedAddresses() public {
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);
        assertTrue(module.allowedAddresses(subAccount1, address(protocol)));
    }

    function test_SetAllowedAddresses_Multiple() public {
        address[] memory targets = new address[](2);
        targets[0] = address(protocol);
        targets[1] = address(token);
        module.setAllowedAddresses(subAccount1, targets, true);
        assertTrue(module.allowedAddresses(subAccount1, address(protocol)));
        assertTrue(module.allowedAddresses(subAccount1, address(token)));
    }

    function test_SetAllowedAddresses_RevokeAccess() public {
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);
        assertTrue(module.allowedAddresses(subAccount1, address(protocol)));

        module.setAllowedAddresses(subAccount1, targets, false);
        assertFalse(module.allowedAddresses(subAccount1, address(protocol)));
    }

    function test_SetAllowedAddresses_RevertsForSafe() public {
        address[] memory targets = new address[](1);
        targets[0] = address(safe);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.CannotWhitelistCoreAddress.selector, address(safe)));
        module.setAllowedAddresses(subAccount1, targets, true);
    }

    function test_SetAllowedAddresses_RevertsForModule() public {
        address[] memory targets = new address[](1);
        targets[0] = address(module);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.CannotWhitelistCoreAddress.selector, address(module)));
        module.setAllowedAddresses(subAccount1, targets, true);
    }

    function test_SetAllowedAddresses_RevertsForZeroAddress() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0);
        vm.expectRevert(Module.InvalidAddress.selector);
        module.setAllowedAddresses(subAccount1, targets, true);
    }

    // ============ Execute Claim Tests ============

    function test_ExecuteOnProtocol_Claim() public {
        // Setup
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        // Build claim calldata
        bytes memory data = abi.encodeWithSignature("claim(address)", address(safe));

        // Execute as subAccount1
        vm.prank(subAccount1);
        module.executeOnProtocol(address(protocol), data);
    }

    function test_ExecuteOnProtocol_EmitsEvent() public {
        // Setup
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        // Build claim calldata
        bytes memory data = abi.encodeWithSignature("claim(address)", address(safe));

        // Expect event
        vm.expectEmit(true, true, false, false);
        address[] memory tokensOut = new address[](1);
        tokensOut[0] = address(token);
        uint256[] memory amountsOut = new uint256[](1);
        amountsOut[0] = 0;
        emit DeFiInteractorModule.ProtocolExecution(
            subAccount1,
            address(protocol),
            DeFiInteractorModule.OperationType.CLAIM,
            tokensOut,
            amountsOut
        );

        vm.prank(subAccount1);
        module.executeOnProtocol(address(protocol), data);
    }

    function test_ExecuteOnProtocol_RevertsIfNoRole() public {
        bytes memory data = abi.encodeWithSignature("claim(address)", address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.executeOnProtocol(address(protocol), data);
    }

    function test_ExecuteOnProtocol_RevertsIfNotWhitelisted() public {
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        // Don't whitelist the protocol

        bytes memory data = abi.encodeWithSignature("claim(address)", address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(DeFiInteractorModule.AddressNotAllowed.selector);
        module.executeOnProtocol(address(protocol), data);
    }

    function test_ExecuteOnProtocol_RevertsIfWrongRecipient() public {
        // Setup
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        // Build claim calldata with wrong recipient
        bytes memory data = abi.encodeWithSignature("claim(address)", subAccount1);

        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.InvalidRecipient.selector, subAccount1, address(safe)));
        module.executeOnProtocol(address(protocol), data);
    }

    function test_ExecuteOnProtocol_RevertsIfNoParser() public {
        // Setup a new protocol without parser
        MockProtocol newProtocol = new MockProtocol();
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(newProtocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        bytes memory data = abi.encodeWithSignature("claim(address)", address(safe));

        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.NoParserRegistered.selector, address(newProtocol)));
        module.executeOnProtocol(address(newProtocol), data);
    }

    function test_ExecuteOnProtocol_RevertsIfUnknownSelector() public {
        // Setup
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        // Use an unknown selector
        bytes memory data = abi.encodeWithSignature("unknownFunction()");

        vm.prank(subAccount1);
        vm.expectRevert(abi.encodeWithSelector(DeFiInteractorModule.UnknownSelector.selector, bytes4(keccak256("unknownFunction()"))));
        module.executeOnProtocol(address(protocol), data);
    }

    // ============ Emergency Controls Tests ============

    function test_Pause() public {
        module.pause();
        assertTrue(module.paused());
    }

    function test_Unpause() public {
        module.pause();
        module.unpause();
        assertFalse(module.paused());
    }

    function test_ExecuteOnProtocol_RevertsWhenPaused() public {
        module.grantRole(subAccount1, module.CLAIM_ROLE());
        address[] memory targets = new address[](1);
        targets[0] = address(protocol);
        module.setAllowedAddresses(subAccount1, targets, true);

        module.pause();

        bytes memory data = abi.encodeWithSignature("claim(address)", address(safe));

        vm.prank(subAccount1);
        vm.expectRevert();
        module.executeOnProtocol(address(protocol), data);
    }

    function test_Pause_RevertsIfNotOwner() public {
        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.pause();
    }

    function test_Unpause_RevertsIfNotOwner() public {
        module.pause();
        vm.prank(subAccount1);
        vm.expectRevert(Module.Unauthorized.selector);
        module.unpause();
    }

    // ============ Module Enabled Tests ============

    function test_ModuleEnabled() public view {
        assertTrue(safe.isModuleEnabled(address(module)));
    }
}
