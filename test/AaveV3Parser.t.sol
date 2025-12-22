// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AaveV3Parser} from "../src/parsers/AaveV3Parser.sol";

/**
 * @title AaveV3ParserTest
 * @notice Tests for the Aave V3 RewardsController parser (Claim-Only Version)
 */
contract AaveV3ParserTest is Test {
    AaveV3Parser public parser;

    // Test addresses
    address constant REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USER = address(0x1234);
    address constant REWARD_TOKEN = address(0xAAAA);

    function setUp() public {
        parser = new AaveV3Parser();
    }

    // ============ Selector Tests ============

    function testSelectors() public view {
        assertEq(parser.CLAIM_REWARDS_SELECTOR(), bytes4(0x236300dc), "ClaimRewards selector mismatch");
        assertEq(parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR(), bytes4(0x33028b99), "ClaimRewardsOnBehalf selector mismatch");
        assertEq(parser.CLAIM_ALL_REWARDS_SELECTOR(), bytes4(0xbb492bf5), "ClaimAllRewards selector mismatch");
        assertEq(parser.CLAIM_ALL_ON_BEHALF_SELECTOR(), bytes4(0x9ff55db9), "ClaimAllOnBehalf selector mismatch");
    }

    function testSupportsSelector() public view {
        // Claim operations
        assertTrue(parser.supportsSelector(parser.CLAIM_REWARDS_SELECTOR()), "Should support claimRewards");
        assertTrue(parser.supportsSelector(parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR()), "Should support claimRewardsOnBehalf");
        assertTrue(parser.supportsSelector(parser.CLAIM_ALL_REWARDS_SELECTOR()), "Should support claimAllRewards");
        assertTrue(parser.supportsSelector(parser.CLAIM_ALL_ON_BEHALF_SELECTOR()), "Should support claimAllOnBehalf");

        // Pool operations NOT supported in claim-only version
        assertFalse(parser.supportsSelector(bytes4(0x617ba037)), "Should NOT support supply");
        assertFalse(parser.supportsSelector(bytes4(0x69328dec)), "Should NOT support withdraw");
        assertFalse(parser.supportsSelector(bytes4(0xa415bcad)), "Should NOT support borrow");
        assertFalse(parser.supportsSelector(bytes4(0x573ade81)), "Should NOT support repay");

        // Unknown selector
        assertFalse(parser.supportsSelector(bytes4(0xdeadbeef)), "Should not support unknown");
    }

    // ============ Claim Rewards Tests ============

    function testClaimRewardsNoInputTokens() public view {
        // claimRewards(address[] assets, uint256 amount, address to, address reward)
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_SELECTOR(),
            assets,
            1000e18,
            USER,
            REWARD_TOKEN
        );

        address[] memory tokens = parser.extractInputTokens(REWARDS_CONTROLLER, data);
        assertEq(tokens.length, 0, "Claim should have no input tokens");
    }

    function testClaimRewardsNoInputAmounts() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_SELECTOR(),
            assets,
            1000e18,
            USER,
            REWARD_TOKEN
        );

        uint256[] memory amounts = parser.extractInputAmounts(REWARDS_CONTROLLER, data);
        assertEq(amounts.length, 0, "Claim should have no input amounts");
    }

    function testClaimRewardsExtractOutputTokens() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_SELECTOR(),
            assets,
            1000e18,
            USER,
            REWARD_TOKEN
        );

        address[] memory tokens = parser.extractOutputTokens(REWARDS_CONTROLLER, data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], REWARD_TOKEN, "Output token should be reward token");
    }

    function testClaimRewardsExtractRecipient() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_SELECTOR(),
            assets,
            1000e18,
            USER,
            REWARD_TOKEN
        );

        address recipient = parser.extractRecipient(REWARDS_CONTROLLER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER");
    }

    function testClaimRewardsOnBehalfExtractOutputTokens() public view {
        // claimRewardsOnBehalf(address[] assets, uint256 amount, address user, address to, address reward)
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR(),
            assets,
            1000e18,
            USER,
            USER,
            REWARD_TOKEN
        );

        address[] memory tokens = parser.extractOutputTokens(REWARDS_CONTROLLER, data);
        assertEq(tokens.length, 1, "Should have 1 output token");
        assertEq(tokens[0], REWARD_TOKEN, "Output token should be reward token");
    }

    function testClaimRewardsOnBehalfExtractRecipient() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        address recipientAddr = address(0x5678);

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR(),
            assets,
            1000e18,
            USER,
            recipientAddr,
            REWARD_TOKEN
        );

        address recipient = parser.extractRecipient(REWARDS_CONTROLLER, data, address(0));
        assertEq(recipient, recipientAddr, "Recipient should be the 'to' address");
    }

    function testClaimAllRewardsReturnsEmptyArray() public view {
        // claimAllRewards(address[] assets, address to)
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = WETH;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_ALL_REWARDS_SELECTOR(),
            assets,
            USER
        );

        address[] memory tokens = parser.extractOutputTokens(REWARDS_CONTROLLER, data);
        assertEq(tokens.length, 0, "ClaimAllRewards should return empty array (unknown tokens)");
    }

    function testClaimAllRewardsExtractRecipient() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_ALL_REWARDS_SELECTOR(),
            assets,
            USER
        );

        address recipient = parser.extractRecipient(REWARDS_CONTROLLER, data, address(0));
        assertEq(recipient, USER, "Recipient should be USER");
    }

    function testClaimAllOnBehalfReturnsEmptyArray() public view {
        // claimAllRewardsOnBehalf(address[] assets, address user, address to)
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_ALL_ON_BEHALF_SELECTOR(),
            assets,
            USER,
            USER
        );

        address[] memory tokens = parser.extractOutputTokens(REWARDS_CONTROLLER, data);
        assertEq(tokens.length, 0, "ClaimAllOnBehalf should return empty array");
    }

    function testClaimAllOnBehalfExtractRecipient() public view {
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        address recipientAddr = address(0x9999);

        bytes memory data = abi.encodeWithSelector(
            parser.CLAIM_ALL_ON_BEHALF_SELECTOR(),
            assets,
            USER,
            recipientAddr
        );

        address recipient = parser.extractRecipient(REWARDS_CONTROLLER, data, address(0));
        assertEq(recipient, recipientAddr, "Recipient should be the 'to' address");
    }

    // ============ Operation Type Tests ============

    function testGetOperationType() public view {
        bytes memory claimRewardsData = abi.encodeWithSelector(parser.CLAIM_REWARDS_SELECTOR());
        bytes memory claimOnBehalfData = abi.encodeWithSelector(parser.CLAIM_REWARDS_ON_BEHALF_SELECTOR());
        bytes memory claimAllData = abi.encodeWithSelector(parser.CLAIM_ALL_REWARDS_SELECTOR());
        bytes memory claimAllOnBehalfData = abi.encodeWithSelector(parser.CLAIM_ALL_ON_BEHALF_SELECTOR());
        bytes memory unknownData = abi.encodeWithSelector(bytes4(0xdeadbeef));

        // CLAIM operations
        assertEq(parser.getOperationType(claimRewardsData), 4, "ClaimRewards should be CLAIM (4)");
        assertEq(parser.getOperationType(claimOnBehalfData), 4, "ClaimRewardsOnBehalf should be CLAIM (4)");
        assertEq(parser.getOperationType(claimAllData), 4, "ClaimAllRewards should be CLAIM (4)");
        assertEq(parser.getOperationType(claimAllOnBehalfData), 4, "ClaimAllOnBehalf should be CLAIM (4)");

        // Unknown
        assertEq(parser.getOperationType(unknownData), 0, "Unknown should return 0");
    }

    // ============ Revert Tests ============

    function testUnsupportedSelectorReverts() public {
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(100));

        vm.expectRevert(AaveV3Parser.UnsupportedSelector.selector);
        parser.extractInputTokens(REWARDS_CONTROLLER, badData);

        vm.expectRevert(AaveV3Parser.UnsupportedSelector.selector);
        parser.extractInputAmounts(REWARDS_CONTROLLER, badData);

        vm.expectRevert(AaveV3Parser.UnsupportedSelector.selector);
        parser.extractOutputTokens(REWARDS_CONTROLLER, badData);

        vm.expectRevert(AaveV3Parser.UnsupportedSelector.selector);
        parser.extractRecipient(REWARDS_CONTROLLER, badData, address(0));
    }
}
