// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeFiInteractorModule} from "../../src/DeFiInteractorModule.sol";
import {MockSafe} from "../mocks/MockSafe.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockProtocol} from "../mocks/MockProtocol.sol";
import {MockParser} from "../mocks/MockParser.sol";

/**
 * @title DeFiInteractorModuleBase
 * @notice Base test contract with shared setup for DeFiInteractorModule tests (Claim-Only)
 */
abstract contract DeFiInteractorModuleBase is Test {
    DeFiInteractorModule public module;
    MockSafe public safe;
    MockERC20 public token;
    MockProtocol public protocol;
    MockParser public parser;

    address public owner;
    address public subAccount1;
    address public subAccount2;
    address public recipient;

    // Selectors for testing (Claim-Only version)
    bytes4 constant CLAIM_SELECTOR = bytes4(keccak256("claim(address)"));

    function setUp() public virtual {
        owner = address(this);
        subAccount1 = makeAddr("subAccount1");
        subAccount2 = makeAddr("subAccount2");
        recipient = makeAddr("recipient");

        // Deploy mock Safe
        address[] memory owners = new address[](1);
        owners[0] = owner;
        safe = new MockSafe(owners, 1);

        // Deploy module (Safe is avatar, THIS is owner for testing)
        module = new DeFiInteractorModule(address(safe), owner);

        // Deploy mock token and protocol
        token = new MockERC20();
        protocol = new MockProtocol();

        // Deploy mock parser (configured for our token)
        parser = new MockParser(address(token));

        // Enable module on Safe
        safe.enableModule(address(module));

        // Transfer tokens to Safe
        token.transfer(address(safe), 100000 * 10**18);

        // Register selectors (only CLAIM allowed in claim-only version)
        module.registerSelector(CLAIM_SELECTOR, DeFiInteractorModule.OperationType.CLAIM);

        // Register parser for protocol
        module.registerParser(address(protocol), address(parser));
    }
}
