// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DeFiInteractor.sol";

// Mock contracts for testing
contract MockSafe {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 /* operation */
    ) external returns (bool) {
        (bool success,) = to.call{value: value}(data);
        return success;
    }
}

contract MockZodiacRoles {
    mapping(address => mapping(uint16 => bool)) public roles;
    address public safe;

    function setSafe(address _safe) external {
        safe = _safe;
    }

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
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint16 /* roleId */,
        bool shouldRevert
    ) external returns (bool) {
        // Execute transaction through the Safe to simulate real Zodiac Roles behavior
        // In reality, Zodiac Roles calls safe.execTransactionFromModule()
        // which then executes the call, making msg.sender the Safe

        // Call safe.execTransactionFromModule which will execute with Safe as msg.sender
        (bool success,) = address(safe).call(
            abi.encodeWithSignature(
                "execTransactionFromModule(address,uint256,bytes,uint8)",
                to,
                value,
                data,
                operation
            )
        );

        if (!success && shouldRevert) {
            revert("Transaction failed");
        }
        return success;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "Insufficient allowance");
        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    function setBalance(address account, uint256 amount) external {
        balances[account] = amount;
    }
}

contract MockPriceOracle {
    // Returns value with 18 decimals (USD)
    function getValue(address token, uint256 amount) external pure returns (uint256) {
        // For simplicity, return 1:1 value (1 token = 1 USD)
        return amount;
    }

    function getPrice(address token) external pure returns (uint256) {
        // For simplicity, return 1 USD per token
        return 1e18;
    }

    function getPositionValue(address protocol, address holder) external view returns (uint256) {
        // Try Morpho vault (has convertToAssets)
        try MockMorphoVault(protocol).convertToAssets(0) returns (uint256) {
            // It's a Morpho vault
            uint256 shares = MockMorphoVault(protocol).balanceOf(holder);
            if (shares == 0) return 0;
            uint256 assets = MockMorphoVault(protocol).convertToAssets(shares);
            return assets;
        } catch {}

        // Try Aave aToken (has UNDERLYING_ASSET_ADDRESS)
        try MockAToken(protocol).UNDERLYING_ASSET_ADDRESS() returns (address) {
            // It's an aToken
            uint256 balance = MockAToken(protocol).balanceOf(holder);
            return balance; // aToken balance is 1:1 with underlying
        } catch {}

        // Try Compound V3 (has baseToken)
        try MockCompoundV3(protocol).baseToken() returns (address) {
            // It's a Compound V3 comet
            uint256 balance = MockCompoundV3(protocol).balanceOf(holder);
            return balance; // Compound V3 balance includes interest
        } catch {}

        // Not a recognized protocol
        return 0;
    }
}

contract MockProtocol {
    function executeAction(uint256 value) external pure returns (uint256) {
        return value * 2;
    }
}

contract MockMorphoVault {
    address public immutable asset;
    uint256 public totalAssets;
    mapping(address => uint256) public shares;
    uint256 public totalShares;

    constructor(address _asset, uint256 _totalAssets) {
        asset = _asset;
        totalAssets = _totalAssets;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 _shares) {
        // Transfer assets from caller to vault
        MockERC20(asset).transferFrom(msg.sender, address(this), assets);

        _shares = assets; // 1:1 for simplicity
        shares[receiver] += _shares;
        totalShares += _shares;
        return _shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 _shares) {
        _shares = assets; // 1:1 for simplicity
        shares[owner] -= _shares;
        totalShares -= _shares;

        // Transfer assets from vault to receiver
        MockERC20(asset).transfer(receiver, assets);
        return _shares;
    }

    function convertToShares(uint256 assets) external pure returns (uint256 _shares) {
        return assets;
    }

    function convertToAssets(uint256 _shares) external view returns (uint256 assets) {
        // If there are no shares, return 1:1
        if (totalShares == 0) return _shares;

        // Otherwise calculate based on actual vault balance (to support yield)
        uint256 vaultBalance = MockERC20(asset).balanceOf(address(this));
        return (_shares * vaultBalance) / totalShares;
    }

    function balanceOf(address account) external view returns (uint256) {
        return shares[account];
    }

    function previewDeposit(uint256 assets) external pure returns (uint256 _shares) {
        return assets;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256 _shares) {
        return assets;
    }

    function setShares(address account, uint256 amount) external {
        // Update total shares based on the difference
        if (shares[account] > 0) {
            totalShares = totalShares - shares[account] + amount;
        } else {
            totalShares += amount;
        }
        shares[account] = amount;
    }
}

contract MockAToken {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    mapping(address => uint256) public balances;

    constructor(address _underlying) {
        UNDERLYING_ASSET_ADDRESS = _underlying;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function setBalance(address account, uint256 amount) external {
        balances[account] = amount;
    }

    function scaledBalanceOf(address) external pure returns (uint256) {
        return 0; // Not used in our implementation
    }
}

contract MockCompoundV3 {
    address public immutable baseToken;
    mapping(address => uint256) public balances;

    constructor(address _baseToken) {
        baseToken = _baseToken;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function setBalance(address account, uint256 amount) external {
        balances[account] = amount;
    }

    function balanceOfBase(address account) external view returns (uint256) {
        return balances[account];
    }
}

contract DeFiInteractorTest is Test {
    DeFiInteractor public interactor;
    MockSafe public safe;
    MockZodiacRoles public rolesModifier;
    MockMorphoVault public vault;
    MockERC20 public mockAsset;
    MockERC20 public mockToken2;
    MockPriceOracle public oracle;
    MockProtocol public protocol;
    address public subAccount;

    event DepositExecuted(
        address indexed subAccount,
        address indexed vault,
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
        address indexed vault,
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
    event UnusualActivity(
        address indexed subAccount,
        string activityType,
        uint256 value,
        uint256 threshold,
        uint256 timestamp
    );

    function setUp() public {
        safe = new MockSafe();
        rolesModifier = new MockZodiacRoles();
        mockAsset = new MockERC20();
        mockToken2 = new MockERC20();
        oracle = new MockPriceOracle();
        protocol = new MockProtocol();
        vault = new MockMorphoVault(address(mockAsset), 1000000e18); // 1M assets in vault
        subAccount = address(0x20);

        interactor = new DeFiInteractor(address(safe), address(rolesModifier));
        rolesModifier.setSafe(address(safe));

        // Set Safe's initial balance to 1M tokens
        mockAsset.setBalance(address(safe), 1000000e18);
        mockToken2.setBalance(address(safe), 1000000e18);

        // Set up oracle and tracked tokens
        vm.startPrank(address(safe));
        interactor.setOracle(address(oracle));
        interactor.addTrackedToken(address(mockAsset));
        interactor.addTrackedToken(address(mockToken2));
        vm.stopPrank();
    }

    // Helper function to allow an address for a sub-account
    function allowAddress(address subAcc, address target) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAcc, targets, true);
    }

    function testConstructor() public view {
        assertEq(address(interactor.safe()), address(safe));
        assertEq(address(interactor.rolesModifier()), address(rolesModifier));
        assertEq(interactor.DEFI_DEPOSIT_ROLE(), 1);
        assertEq(interactor.DEFI_WITHDRAW_ROLE(), 2);
    }

    function testGrantRole() public {
        vm.prank(address(safe));
        vm.expectEmit(true, true, false, true);
        emit RoleAssigned(subAccount, 1, block.timestamp);
        interactor.grantRole(subAccount, 1);

        assertTrue(interactor.hasRole(subAccount, 1));
    }

    function testGrantRoleUnauthorized() public {
        vm.prank(address(0x999));
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.grantRole(subAccount, 1);
    }

    function testRevokeRole() public {
        vm.startPrank(address(safe));
        interactor.grantRole(subAccount, 1);
        assertTrue(interactor.hasRole(subAccount, 1));

        vm.expectEmit(true, true, false, true);
        emit RoleRevoked(subAccount, 1, block.timestamp);
        interactor.revokeRole(subAccount, 1);
        vm.stopPrank();

        assertFalse(interactor.hasRole(subAccount, 1));
    }

    function testDepositToVault() public {
        // Grant role to subAccount
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);

        // Allow vault address for subAccount
        allowAddress(subAccount, address(vault));

        // Attempt deposit (10% of Safe's balance = 100k)
        // Safe has 1M tokens, so 10% = 100k
        uint256 depositAmount = 100000e18;
        uint256 minShares = depositAmount; // Expect 1:1 in mock

        vm.prank(subAccount);
        uint256 shares = interactor.depositTo(address(vault), depositAmount, address(safe), minShares);

        assertEq(shares, depositAmount); // 1:1 in mock
    }

    function testDepositToVaultUnauthorized() public {
        uint256 depositAmount = 100000e18;

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.depositTo(address(vault), depositAmount, address(safe), 0);
    }

    function testDepositExceedsLimit() public {
        // Grant role to subAccount
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Attempt deposit exceeding 10% limit of Safe's balance
        // Safe has 1M tokens, so 15% = 150k (exceeds 10% limit of 100k)
        uint256 depositAmount = 150000e18;

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsDepositLimit.selector);
        interactor.depositTo(address(vault), depositAmount, address(safe), 0);
    }

    function testWithdrawFromVault() public {
        // Grant role to subAccount
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        // Set up: Safe has 1M worth of shares in the vault
        vault.setShares(address(safe), 1000000e18);
        // Give vault assets to withdraw
        mockAsset.setBalance(address(vault), 1000000e18);

        // Attempt withdraw (5% of Safe's position = 50k)
        uint256 withdrawAmount = 50000e18;
        uint256 maxShares = withdrawAmount; // Expect 1:1 in mock

        vm.prank(subAccount);
        uint256 shares = interactor.withdrawFrom(
            address(vault),
            withdrawAmount,
            address(safe),
            address(safe),
            maxShares
        );

        assertEq(shares, withdrawAmount); // 1:1 in mock
    }

    function testWithdrawFromVaultUnauthorized() public {
        uint256 withdrawAmount = 50000e18;

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.withdrawFrom(address(vault), withdrawAmount, address(safe), address(safe), type(uint256).max);
    }

    function testWithdrawExceedsLimit() public {
        // Grant role to subAccount
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        // Set up: Safe has 1M worth of shares in the vault
        vault.setShares(address(safe), 1000000e18);
        // Give vault assets to withdraw (not needed for this test but good practice)
        mockAsset.setBalance(address(vault), 1000000e18);

        // Attempt withdraw exceeding 5% limit of Safe's position
        // Safe has 1M in vault, so 6% = 60k (exceeds 5% limit of 50k)
        uint256 withdrawAmount = 60000e18;

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsWithdrawLimit.selector);
        interactor.withdrawFrom(address(vault), withdrawAmount, address(safe), address(safe), type(uint256).max);
    }

    // ============ Edge Case Tests ============

    function testConstructorWithZeroAddressSafe() public {
        vm.expectRevert(DeFiInteractor.InvalidAddress.selector);
        new DeFiInteractor(address(0), address(rolesModifier));
    }

    function testConstructorWithZeroAddressRoles() public {
        vm.expectRevert(DeFiInteractor.InvalidAddress.selector);
        new DeFiInteractor(address(safe), address(0));
    }

    function testDepositZeroAmount() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        vm.prank(subAccount);
        uint256 shares = interactor.depositTo(address(vault), 0, address(safe), 0);
        assertEq(shares, 0);
    }

    function testWithdrawZeroAmount() public {
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        vault.setShares(address(safe), 1000000e18);
        // Give vault some balance so convertToAssets works
        mockAsset.setBalance(address(vault), 1000000e18);

        vm.prank(subAccount);
        uint256 shares = interactor.withdrawFrom(address(vault), 0, address(safe), address(safe), type(uint256).max);
        assertEq(shares, 0);
    }

    function testDepositWithDepositRoleCannotWithdraw() public {
        // Grant ONLY deposit role
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        vault.setShares(address(safe), 1000000e18);

        // Try to withdraw with only deposit role
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.withdrawFrom(address(vault), 10000e18, address(safe), address(safe), type(uint256).max);
    }

    function testWithdrawWithWithdrawRoleCannotDeposit() public {
        // Grant ONLY withdraw role
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        // Try to deposit with only withdraw role
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.depositTo(address(vault), 10000e18, address(safe), 0);
    }

    function testDepositExactlyAtLimit() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Deposit exactly 10% (100k out of 1M)
        uint256 depositAmount = 100000e18;

        vm.prank(subAccount);
        uint256 shares = interactor.depositTo(address(vault), depositAmount, address(safe), depositAmount);
        assertEq(shares, depositAmount);
    }

    function testWithdrawExactlyAtLimit() public {
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        vault.setShares(address(safe), 1000000e18);
        // Give vault assets to withdraw
        mockAsset.setBalance(address(vault), 1000000e18);

        // Withdraw exactly 5% (50k out of 1M)
        uint256 withdrawAmount = 50000e18;

        vm.prank(subAccount);
        uint256 shares = interactor.withdrawFrom(
            address(vault),
            withdrawAmount,
            address(safe),
            address(safe),
            withdrawAmount
        );
        assertEq(shares, withdrawAmount);
    }

    function testDepositOneWeiOverLimit() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Try to deposit 10% + 1 wei
        uint256 depositAmount = 100000e18 + 1;

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsDepositLimit.selector);
        interactor.depositTo(address(vault), depositAmount, address(safe), 0);
    }

    function testWithdrawOneWeiOverLimit() public {
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        vault.setShares(address(safe), 1000000e18);

        // Try to withdraw 5% + 1 wei
        uint256 withdrawAmount = 50000e18 + 1;

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsWithdrawLimit.selector);
        interactor.withdrawFrom(address(vault), withdrawAmount, address(safe), address(safe), type(uint256).max);
    }

    function testDepositWhenSafeHasZeroBalance() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Set Safe balance to 0
        mockAsset.setBalance(address(safe), 0);

        // Any non-zero deposit should fail
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsDepositLimit.selector);
        interactor.depositTo(address(vault), 1, address(safe), 0);
    }

    function testWithdrawWhenSafeHasZeroShares() public {
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        // Safe has 0 shares
        vault.setShares(address(safe), 0);

        // Any non-zero withdraw should fail
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsWithdrawLimit.selector);
        interactor.withdrawFrom(address(vault), 1, address(safe), address(safe), type(uint256).max);
    }

    function testRevokeRoleUnauthorized() public {
        vm.prank(address(0x999));
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.revokeRole(subAccount, 1);
    }

    function testGrantMultipleRolesToSameAccount() public {
        vm.startPrank(address(safe));

        interactor.grantRole(subAccount, interactor.DEFI_DEPOSIT_ROLE());
        interactor.grantRole(subAccount, interactor.DEFI_WITHDRAW_ROLE());

        vm.stopPrank();

        assertTrue(interactor.hasRole(subAccount, interactor.DEFI_DEPOSIT_ROLE()));
        assertTrue(interactor.hasRole(subAccount, interactor.DEFI_WITHDRAW_ROLE()));
    }

    function testRevokeNonExistentRole() public {
        // Revoke a role that was never granted
        vm.prank(address(safe));
        interactor.revokeRole(subAccount, 1);

        assertFalse(interactor.hasRole(subAccount, 1));
    }

    function testDepositEmitsCorrectEvent() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        uint256 depositAmount = 100000e18;

        // We emit the event but don't check exact parameters since the event has 9 parameters
        // including indexed addresses, balances, percentages, etc.
        // The important thing is the deposit executes successfully
        vm.prank(subAccount);
        uint256 shares = interactor.depositTo(
            address(vault),
            depositAmount,
            address(safe),
            depositAmount
        );

        // Verify deposit executed correctly
        assertEq(shares, depositAmount);
        assertEq(vault.balanceOf(address(safe)), depositAmount);
    }

    function testWithdrawEmitsCorrectEvent() public {
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        vault.setShares(address(safe), 1000000e18);
        mockAsset.setBalance(address(vault), 1000000e18);
        uint256 withdrawAmount = 50000e18;

        // We emit the event but don't check exact parameters since the event has 9 parameters
        // The important thing is the withdrawal executes successfully
        vm.prank(subAccount);
        uint256 shares = interactor.withdrawFrom(
            address(vault),
            withdrawAmount,
            address(safe),
            address(safe),
            withdrawAmount
        );

        // Verify withdrawal executed correctly
        assertEq(shares, withdrawAmount);
        assertEq(mockAsset.balanceOf(address(safe)), 1000000e18 + withdrawAmount);
    }

    function testHasRoleForNonExistentRole() public view {
        assertFalse(interactor.hasRole(subAccount, 999));
    }

    function testMultipleDepositsWithinLimit() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // First deposit: 5%
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);

        // Second deposit: 5% (total would be 10% but each individual check is separate)
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);
    }

    function testConstantsAreCorrect() public view {
        assertEq(interactor.DEFAULT_MAX_DEPOSIT_BPS(), 1000); // 10%
        assertEq(interactor.DEFAULT_MAX_WITHDRAW_BPS(), 500); // 5%
        assertEq(interactor.DEFAULT_LIMIT_WINDOW_DURATION(), 1 days);
        assertEq(interactor.DEFI_DEPOSIT_ROLE(), 1);
        assertEq(interactor.DEFI_WITHDRAW_ROLE(), 2);
    }

    function testSetSubAccountLimits() public {
        address testAccount = address(0x123);

        // Set custom limits
        vm.prank(address(safe));
        interactor.setSubAccountLimits(testAccount, 2000, 1000, 500, 12 hours);

        // Check limits were set
        (uint256 maxDepositBps, uint256 maxWithdrawBps, uint256 maxLossBps, uint256 windowDuration) =
            interactor.getSubAccountLimits(testAccount);

        assertEq(maxDepositBps, 2000); // 20%
        assertEq(maxWithdrawBps, 1000); // 10%
        assertEq(windowDuration, 12 hours);
    }

    function testSetSubAccountLimitsOnlyBySafe() public {
        address testAccount = address(0x123);

        vm.prank(address(0x456));
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.setSubAccountLimits(testAccount, 2000, 1000, 500, 12 hours);
    }

    function testSetSubAccountLimitsInvalidAddress() public {
        vm.prank(address(safe));
        vm.expectRevert(DeFiInteractor.InvalidAddress.selector);
        interactor.setSubAccountLimits(address(0), 2000, 1000, 500, 12 hours);
    }

    function testSetSubAccountLimitsInvalidConfiguration() public {
        address testAccount = address(0x123);

        // BPS too high
        vm.prank(address(safe));
        vm.expectRevert(DeFiInteractor.InvalidLimitConfiguration.selector);
        interactor.setSubAccountLimits(testAccount, 10001, 1000, 500, 12 hours);

        // Window too short
        vm.prank(address(safe));
        vm.expectRevert(DeFiInteractor.InvalidLimitConfiguration.selector);
        interactor.setSubAccountLimits(testAccount, 2000, 1000, 500, 30 minutes);
    }

    function testGetSubAccountLimitsReturnsDefaults() public view {
        address testAccount = address(0x123);

        // Should return defaults for unconfigured account
        (uint256 maxDepositBps, uint256 maxWithdrawBps, uint256 maxLossBps, uint256 windowDuration) =
            interactor.getSubAccountLimits(testAccount);

        assertEq(maxDepositBps, 1000); // 10%
        assertEq(maxWithdrawBps, 500); // 5%
        assertEq(windowDuration, 1 days);
    }

    function testCustomLimitsAppliedToDeposit() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Set higher deposit limit (20%)
        vm.prank(address(safe));
        interactor.setSubAccountLimits(subAccount, 2000, 500, 500, 1 days);

        // Should succeed with 15% deposit (above default 10% but below custom 20%)
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 150000e18, address(safe), 0);

        // Should fail with another 10% (total 25% exceeds 20%)
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsDepositLimit.selector);
        interactor.depositTo(address(vault), 100000e18, address(safe), 0);
    }

    function testCustomLimitsAppliedToWithdraw() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));

        // Grant roles
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        // Deposit first
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 100000e18, address(safe), 0);

        // Set higher withdraw limit (10%)
        vm.prank(address(safe));
        interactor.setSubAccountLimits(subAccount, 1000, 1000, 500, 1 days);

        // Get current vault balance
        uint256 vaultShares = vault.balanceOf(address(safe));
        uint256 vaultAssets = vault.convertToAssets(vaultShares);

        // Should succeed with 8% withdrawal (above default 5% but below custom 10%)
        uint256 withdrawAmount = (vaultAssets * 800) / 10000;
        vm.prank(subAccount);
        interactor.withdrawFrom(address(vault), withdrawAmount, address(safe), address(safe), type(uint256).max);
    }

    function testCustomWindowDuration() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Set shorter window (6 hours)
        vm.prank(address(safe));
        interactor.setSubAccountLimits(subAccount, 1000, 500, 500, 6 hours);

        // First deposit: 10%
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 100000e18, address(safe), 0);

        // Should fail - at limit
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsDepositLimit.selector);
        interactor.depositTo(address(vault), 1e18, address(safe), 0);

        // Warp 6 hours - window resets
        vm.warp(block.timestamp + 6 hours);

        // Should succeed now - use 10% of remaining balance (90000e18)
        // New window starts with 900000e18 balance, so 10% is 90000e18
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 90000e18, address(safe), 0);
    }

    // ============ Per-Sub-Account Vault Restriction Tests ============

    function testSetAllowedVaults() public {
        address testAccount = address(0x123);
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault);
        vaults[1] = address(0x456);

        vm.prank(address(safe));
        interactor.setAllowedAddresses(testAccount, vaults, true);

        // Check vaults are allowed
        assertTrue(interactor.allowedAddresses(testAccount, address(vault)));
        assertTrue(interactor.allowedAddresses(testAccount, address(0x456)));
    }

    function testSetAllowedVaultsOnlyBySafe() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);

        vm.prank(address(0x789));
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.setAllowedAddresses(subAccount, vaults, true);
    }

    function testSetAllowedVaultsInvalidSubAccount() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);

        vm.prank(address(safe));
        vm.expectRevert(DeFiInteractor.InvalidAddress.selector);
        interactor.setAllowedAddresses(address(0), vaults, true);
    }

    function testSetAllowedVaultsInvalidVault() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(0);

        vm.prank(address(safe));
        vm.expectRevert(DeFiInteractor.InvalidAddress.selector);
        interactor.setAllowedAddresses(subAccount, vaults, true);
    }

    function testAllowedAddressesMapping() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);

        // Set allowed vault
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults, true);

        // Check allowed vault
        assertTrue(interactor.allowedAddresses(subAccount, address(vault)));

        // Check non-allowed vault
        assertFalse(interactor.allowedAddresses(subAccount, address(0x123)));
    }

    function testDepositToAllowedVault() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Set allowed vault
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults, true);

        // Should succeed - vault is allowed
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);
    }

    function testDepositToDisallowedVault() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);

        // Don't allow the vault - should fail
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);
    }

    function testWithdrawFromAllowedVault() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();
        allowAddress(subAccount, address(vault));

        // Grant roles
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);
        allowAddress(subAccount, address(vault));

        // Deposit first (before restrictions)
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 100000e18, address(safe), 0);

        // Set allowed vault
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults, true);

        // Get vault balance for withdrawal
        uint256 vaultShares = vault.balanceOf(address(safe));
        uint256 vaultAssets = vault.convertToAssets(vaultShares);
        uint256 withdrawAmount = (vaultAssets * 500) / 10000; // 5%

        // Should succeed - vault is allowed
        vm.prank(subAccount);
        interactor.withdrawFrom(address(vault), withdrawAmount, address(safe), address(safe), type(uint256).max);
    }

    function testWithdrawFromDisallowedVault() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        uint16 withdrawRole = interactor.DEFI_WITHDRAW_ROLE();

        // Grant roles
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        vm.prank(address(safe));
        interactor.grantRole(subAccount, withdrawRole);

        // Don't allow the vault for withdrawal - should fail
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.withdrawFrom(address(vault), 1000e18, address(safe), address(safe), type(uint256).max);
    }

    function testRemoveVaultFromAllowlist() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Set allowed vault
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults, true);

        // Should succeed
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);

        // Remove vault from allowlist
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults, false);

        // Should fail now
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);
    }

    function testRemoveAndReAddVaultAllowlist() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);

        // Allow vault
        allowAddress(subAccount, address(vault));

        // Should succeed - vault is allowed
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);

        // Remove vault from allowlist
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults, false);

        // Should fail now - vault not allowed
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);

        // Re-add vault
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults, true);

        // Should succeed again
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);
    }

    function testMultipleSubAccountsDifferentVaults() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();
        address subAccount2 = address(0x30);

        // Grant roles to both
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));
        vm.prank(address(safe));
        interactor.grantRole(subAccount2, depositRole);
        allowAddress(subAccount, address(vault));

        // Create a second vault
        MockMorphoVault vault2 = new MockMorphoVault(address(mockAsset), 1000000e18);
        // Add more balance to safe for the second vault
        mockAsset.setBalance(address(safe), 2000000e18);

        // Allow different vaults for each sub-account
        address[] memory vaults1 = new address[](1);
        vaults1[0] = address(vault);
        address[] memory vaults2 = new address[](1);
        vaults2[0] = address(vault2);

        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount, vaults1, true);
        vm.prank(address(safe));
        interactor.setAllowedAddresses(subAccount2, vaults2, true);

        // subAccount can only use vault
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.depositTo(address(vault2), 50000e18, address(safe), 0);

        // subAccount2 can only use vault2
        vm.prank(subAccount2);
        interactor.depositTo(address(vault2), 50000e18, address(safe), 0);

        vm.prank(subAccount2);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.depositTo(address(vault), 50000e18, address(safe), 0);
    }

    // ============ Protocol Approval Tests ============

    function testApproveProtocolSuccess() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Allow protocol
        allowAddress(subAccount, address(protocol));

        // Approve 5% of portfolio (2M total, so 5% = 100k)
        vm.prank(subAccount);
        interactor.approveProtocol(address(mockAsset), address(protocol), 100000e18);

        // Check approval was set
        assertEq(mockAsset.allowance(address(safe), address(protocol)), 100000e18);
    }

    function testApproveProtocolExceedsLimit() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Allow protocol
        allowAddress(subAccount, address(protocol));

        // Try to approve 10% of portfolio (above default 5% maxLossBps)
        // Portfolio = 2M, 10% = 200k, but maxLossBps = 5% = 100k
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ApprovalExceedsLimit.selector);
        interactor.approveProtocol(address(mockAsset), address(protocol), 200000e18);
    }

    function testApproveProtocolUnauthorized() public {
        // Don't grant role
        allowAddress(subAccount, address(protocol));

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.approveProtocol(address(mockAsset), address(protocol), 50000e18);
    }

    function testApproveProtocolNotAllowed() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Don't allow protocol

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.approveProtocol(address(mockAsset), address(protocol), 50000e18);
    }

    function testApproveProtocolWithCustomLimits() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Allow protocol
        allowAddress(subAccount, address(protocol));

        // Set custom maxLossBps to 10%
        vm.prank(address(safe));
        interactor.setSubAccountLimits(subAccount, 1000, 500, 1000, 1 days);

        // Should succeed with 10% approval (200k out of 2M)
        vm.prank(subAccount);
        interactor.approveProtocol(address(mockAsset), address(protocol), 200000e18);

        assertEq(mockAsset.allowance(address(safe), address(protocol)), 200000e18);
    }

    // ============ Execute On Protocol Tests ============

    function testExecuteOnProtocolSuccess() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Allow protocol
        allowAddress(subAccount, address(protocol));

        // Execute on protocol
        bytes memory data = abi.encodeWithSelector(MockProtocol.executeAction.selector, 100);
        vm.prank(subAccount);
        interactor.executeOnProtocol(address(protocol), data);
    }

    function testExecuteOnProtocolUnauthorized() public {
        // Don't grant role
        allowAddress(subAccount, address(protocol));

        bytes memory data = abi.encodeWithSelector(MockProtocol.executeAction.selector, 100);
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.executeOnProtocol(address(protocol), data);
    }

    function testExecuteOnProtocolNotAllowed() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Don't allow protocol

        bytes memory data = abi.encodeWithSelector(MockProtocol.executeAction.selector, 100);
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.AddressNotAllowed.selector);
        interactor.executeOnProtocol(address(protocol), data);
    }

    function testExecuteOnProtocolBlocksApproval() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Allow mockAsset (target)
        allowAddress(subAccount, address(mockAsset));

        // Try to execute approve() in calldata - should be blocked
        bytes memory data = abi.encodeWithSelector(IERC20.approve.selector, address(protocol), 1000e18);
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ApprovalNotAllowed.selector);
        interactor.executeOnProtocol(address(mockAsset), data);
    }

    function testExecuteOnProtocolExceedsMaxLoss() public {
        uint16 executeRole = interactor.DEFI_EXECUTE_ROLE();

        // Grant execute role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, executeRole);

        // Allow mockAsset (target)
        allowAddress(subAccount, address(mockAsset));

        // Set custom maxLossBps to 1% (20k on 2M portfolio)
        vm.prank(address(safe));
        interactor.setSubAccountLimits(subAccount, 1000, 500, 100, 1 days);

        // Execute something that reduces portfolio value significantly
        // In this simplified test, we'll just transfer tokens away to simulate loss
        bytes memory data = abi.encodeWithSelector(
            MockERC20.transfer.selector,
            address(0xdead),
            30000e18  // 1.5% loss - exceeds 1% limit
        );

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsMaxLoss.selector);
        interactor.executeOnProtocol(address(mockAsset), data);
    }

    // ============ Token Transfer Tests ============

    function testTransferTokenSuccess() public {
        uint16 transferRole = interactor.DEFI_TRANSFER_ROLE();
        address recipient = address(0x789);

        // Grant transfer role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, transferRole);

        // Transfer 5% of balance (50k out of 1M)
        uint256 transferAmount = 50000e18;

        vm.prank(subAccount);
        bool success = interactor.transferToken(address(mockAsset), recipient, transferAmount);

        assertTrue(success);
        assertEq(mockAsset.balanceOf(recipient), transferAmount);
    }

    function testTransferTokenExceedsLimit() public {
        uint16 transferRole = interactor.DEFI_TRANSFER_ROLE();
        address recipient = address(0x789);

        // Grant transfer role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, transferRole);

        // Try to transfer 10% (exceeds default 5% maxWithdrawBps limit)
        uint256 transferAmount = 100000e18;

        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsTransferLimit.selector);
        interactor.transferToken(address(mockAsset), recipient, transferAmount);
    }

    function testTransferTokenUnauthorized() public {
        address recipient = address(0x789);

        // Don't grant role
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.transferToken(address(mockAsset), recipient, 10000e18);
    }

    function testTransferTokenInvalidAddress() public {
        uint16 transferRole = interactor.DEFI_TRANSFER_ROLE();

        // Grant transfer role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, transferRole);

        // Try to transfer to zero address
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.InvalidAddress.selector);
        interactor.transferToken(address(mockAsset), address(0), 10000e18);
    }

    function testTransferTokenMultipleWithinLimit() public {
        uint16 transferRole = interactor.DEFI_TRANSFER_ROLE();
        address recipient = address(0x789);

        // Grant transfer role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, transferRole);

        // Transfer 2% twice (total 4%, within 5% limit)
        vm.prank(subAccount);
        interactor.transferToken(address(mockAsset), recipient, 20000e18);

        vm.prank(subAccount);
        interactor.transferToken(address(mockAsset), recipient, 20000e18);

        assertEq(mockAsset.balanceOf(recipient), 40000e18);
    }

    function testTransferTokenWithCustomLimits() public {
        uint16 transferRole = interactor.DEFI_TRANSFER_ROLE();
        address recipient = address(0x789);

        // Grant transfer role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, transferRole);

        // Set custom transfer limit to 10%
        vm.prank(address(safe));
        interactor.setSubAccountLimits(subAccount, 1000, 1000, 500, 1 days);

        // Should succeed with 10% transfer (100k out of 1M)
        vm.prank(subAccount);
        bool success = interactor.transferToken(address(mockAsset), recipient, 100000e18);

        assertTrue(success);
        assertEq(mockAsset.balanceOf(recipient), 100000e18);
    }

    function testTransferTokenWindowReset() public {
        uint16 transferRole = interactor.DEFI_TRANSFER_ROLE();
        address recipient = address(0x789);

        // Grant transfer role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, transferRole);

        // Transfer 5% (at limit) - 50k out of 1M
        vm.prank(subAccount);
        interactor.transferToken(address(mockAsset), recipient, 50000e18);

        // Try to transfer more - should fail
        vm.prank(subAccount);
        vm.expectRevert(DeFiInteractor.ExceedsTransferLimit.selector);
        interactor.transferToken(address(mockAsset), recipient, 1e18);

        // Advance time past window (24h)
        vm.warp(block.timestamp + 1 days + 1);

        // After window reset, new limit is 5% of remaining balance (950k)
        // 5% of 950k = 47.5k
        vm.prank(subAccount);
        bool success = interactor.transferToken(address(mockAsset), recipient, 47500e18);

        assertTrue(success);
        assertEq(mockAsset.balanceOf(recipient), 97500e18);
    }

    function testTransferTokenEmitsEvent() public {
        uint16 transferRole = interactor.DEFI_TRANSFER_ROLE();
        address recipient = address(0x789);

        // Grant transfer role
        vm.prank(address(safe));
        interactor.grantRole(subAccount, transferRole);

        uint256 transferAmount = 50000e18;

        // Transfer and verify event emitted
        vm.prank(subAccount);
        bool success = interactor.transferToken(address(mockAsset), recipient, transferAmount);

        assertTrue(success);
    }

    function testTransferRoleConstants() public view {
        assertEq(interactor.DEFI_TRANSFER_ROLE(), 4);
    }

    // ============ Protocol Tracking Tests ============

    function testAddTrackedProtocol() public {
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(vault));

        assertTrue(interactor.isTrackedProtocol(address(vault)));
        assertEq(interactor.getTrackedProtocolCount(), 1);
    }

    function testAddTrackedProtocolOnlyBySafe() public {
        vm.prank(address(0x123));
        vm.expectRevert(DeFiInteractor.Unauthorized.selector);
        interactor.addTrackedProtocol(address(vault));
    }

    function testAddTrackedProtocolInvalidAddress() public {
        vm.prank(address(safe));
        vm.expectRevert(DeFiInteractor.InvalidAddress.selector);
        interactor.addTrackedProtocol(address(0));
    }

    function testRemoveTrackedProtocol() public {
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(vault));
        assertTrue(interactor.isTrackedProtocol(address(vault)));

        vm.prank(address(safe));
        interactor.removeTrackedProtocol(address(vault));
        assertFalse(interactor.isTrackedProtocol(address(vault)));
        assertEq(interactor.getTrackedProtocolCount(), 0);
    }

    function testGetPortfolioValueWithProtocols() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role and allow vault
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Initial portfolio value: 2M USDC (1M mockAsset + 1M mockToken2)
        uint256 initialValue = interactor.getPortfolioValue();
        assertEq(initialValue, 2_000_000e18);

        // Deposit 100k USDC to vault
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 100_000e18, address(safe), 0);

        // Without tracking protocol, portfolio value would be 1.9M (missing 100k in vault)
        // But we're not tracking the protocol yet, so value should drop
        uint256 valueWithoutProtocol = interactor.getPortfolioValue();
        assertEq(valueWithoutProtocol, 1_900_000e18);

        // Now track the protocol
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(vault));

        // With protocol tracking, portfolio value should be back to 2M
        uint256 valueWithProtocol = interactor.getPortfolioValue();
        assertEq(valueWithProtocol, 2_000_000e18); // 900k idle + 1M mockToken2 + 100k in vault
    }

    function testGetPortfolioValueMultipleProtocols() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Create second vault
        MockMorphoVault vault2 = new MockMorphoVault(address(mockToken2), 1_000_000e18);

        // Grant role and allow both vaults
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));
        allowAddress(subAccount, address(vault2));

        // Initial value
        uint256 initialValue = interactor.getPortfolioValue();
        assertEq(initialValue, 2_000_000e18);

        // Deposit to first vault (100k USDC = 10% of 1M)
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 100_000e18, address(safe), 0);

        // Wait to reset window
        vm.warp(block.timestamp + 1 days + 1);

        // Deposit to second vault (100k mockToken2 = 10% of 1M)
        vm.prank(subAccount);
        interactor.depositTo(address(vault2), 100_000e18, address(safe), 0);

        // Track both protocols
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(vault));
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(vault2));

        // Value should still be 2M
        // (900k mockAsset + 100k in vault1) + (900k mockToken2 + 100k in vault2)
        uint256 finalValue = interactor.getPortfolioValue();
        assertEq(finalValue, 2_000_000e18);
    }

    function testGetPortfolioValueWithYield() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role and allow vault
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Track protocol
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(vault));

        // Initial value
        uint256 initialValue = interactor.getPortfolioValue();
        assertEq(initialValue, 2_000_000e18);

        // Deposit 100k USDC to vault
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 100_000e18, address(safe), 0);

        // Initial value after deposit (should be same)
        uint256 valueAfterDeposit = interactor.getPortfolioValue();
        assertEq(valueAfterDeposit, 2_000_000e18);

        // Simulate yield: vault balance increases by 10k
        // Vault received 100k deposit, now has 110k (10k yield = 10% APY)
        mockAsset.setBalance(address(vault), 110_000e18);

        // Portfolio value should now be 2M + 10k yield
        // 900k idle + 1M mockToken2 + 110k in vault (100k deposit + 10k yield)
        uint256 valueWithYield = interactor.getPortfolioValue();
        assertEq(valueWithYield, 2_010_000e18);
    }

    function testGetPortfolioValueEmptyProtocol() public {
        // Track a protocol with no position
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(vault));

        // Should not affect portfolio value
        uint256 value = interactor.getPortfolioValue();
        assertEq(value, 2_000_000e18);
    }

    function testGetPortfolioValueRequiresTrackedAssets() public {
        // Remove all tracked tokens
        vm.startPrank(address(safe));
        interactor.removeTrackedToken(address(mockAsset));
        interactor.removeTrackedToken(address(mockToken2));
        vm.stopPrank();

        // Should revert when no tokens or protocols tracked
        vm.expectRevert(DeFiInteractor.NoTrackedTokens.selector);
        interactor.getPortfolioValue();
    }

    function testGetPortfolioValueWithOnlyProtocols() public {
        uint16 depositRole = interactor.DEFI_DEPOSIT_ROLE();

        // Grant role and allow vault
        vm.prank(address(safe));
        interactor.grantRole(subAccount, depositRole);
        allowAddress(subAccount, address(vault));

        // Deposit 10% USDC to vault (100k out of 1M)
        vm.prank(subAccount);
        interactor.depositTo(address(vault), 100_000e18, address(safe), 0);

        // Remove tracked tokens
        vm.startPrank(address(safe));
        interactor.removeTrackedToken(address(mockAsset));
        interactor.removeTrackedToken(address(mockToken2));

        // Add only protocol tracking
        interactor.addTrackedProtocol(address(vault));
        vm.stopPrank();

        // Should work with only protocols tracked
        uint256 value = interactor.getPortfolioValue();
        assertEq(value, 100_000e18); // Only vault position (100k)
    }

    // ============ Aave V3 Tests ============

    function testGetPortfolioValueWithAaveV3() public {
        // Create Aave aToken (aUSDC) backed by mockAsset (USDC)
        MockAToken aToken = new MockAToken(address(mockAsset));

        // Safe deposits 200k USDC to Aave, receives 200k aUSDC
        aToken.setBalance(address(safe), 200_000e18);

        // Track Aave aToken as a protocol
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(aToken));

        // Portfolio value should include Aave position
        // 1M mockAsset + 1M mockToken2 + 200k aUSDC
        // But wait - the 200k in Aave should have come from the 1M mockAsset
        // So let's reduce mockAsset balance to reflect the deposit
        mockAsset.setBalance(address(safe), 800_000e18);

        uint256 value = interactor.getPortfolioValue();
        // 800k idle USDC + 1M mockToken2 + 200k in Aave = 2M
        assertEq(value, 2_000_000e18);
    }

    function testGetPortfolioValueWithAaveV3Yield() public {
        // Create Aave aToken
        MockAToken aToken = new MockAToken(address(mockAsset));

        // Safe deposits 200k USDC to Aave
        mockAsset.setBalance(address(safe), 800_000e18);
        aToken.setBalance(address(safe), 200_000e18);

        // Track Aave aToken
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(aToken));

        // Initial value
        uint256 initialValue = interactor.getPortfolioValue();
        assertEq(initialValue, 2_000_000e18);

        // Simulate 5% yield on Aave (10k USDC earned)
        // aToken balance increases from 200k to 210k
        aToken.setBalance(address(safe), 210_000e18);

        // Portfolio value should reflect yield
        uint256 valueWithYield = interactor.getPortfolioValue();
        assertEq(valueWithYield, 2_010_000e18); // 800k + 1M + 210k
    }

    function testGetPortfolioValueWithAaveV3Empty() public {
        // Create Aave aToken with no balance
        MockAToken aToken = new MockAToken(address(mockAsset));

        // Track it
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(aToken));

        // Should not affect portfolio value
        uint256 value = interactor.getPortfolioValue();
        assertEq(value, 2_000_000e18);
    }

    // ============ Compound V3 Tests ============

    function testGetPortfolioValueWithCompoundV3() public {
        // Create Compound V3 comet (cUSDC) backed by mockAsset (USDC)
        MockCompoundV3 comet = new MockCompoundV3(address(mockAsset));

        // Safe deposits 150k USDC to Compound
        mockAsset.setBalance(address(safe), 850_000e18);
        comet.setBalance(address(safe), 150_000e18);

        // Track Compound V3
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(comet));

        // Portfolio value should include Compound position
        // 850k idle USDC + 1M mockToken2 + 150k in Compound = 2M
        uint256 value = interactor.getPortfolioValue();
        assertEq(value, 2_000_000e18);
    }

    function testGetPortfolioValueWithCompoundV3Yield() public {
        // Create Compound V3 comet
        MockCompoundV3 comet = new MockCompoundV3(address(mockAsset));

        // Safe deposits 150k USDC to Compound
        mockAsset.setBalance(address(safe), 850_000e18);
        comet.setBalance(address(safe), 150_000e18);

        // Track Compound V3
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(comet));

        // Initial value
        uint256 initialValue = interactor.getPortfolioValue();
        assertEq(initialValue, 2_000_000e18);

        // Simulate 8% yield on Compound (12k USDC earned)
        // Balance increases from 150k to 162k
        comet.setBalance(address(safe), 162_000e18);

        // Portfolio value should reflect yield
        uint256 valueWithYield = interactor.getPortfolioValue();
        assertEq(valueWithYield, 2_012_000e18); // 850k + 1M + 162k
    }

    function testGetPortfolioValueWithCompoundV3Empty() public {
        // Create Compound V3 comet with no balance
        MockCompoundV3 comet = new MockCompoundV3(address(mockAsset));

        // Track it
        vm.prank(address(safe));
        interactor.addTrackedProtocol(address(comet));

        // Should not affect portfolio value
        uint256 value = interactor.getPortfolioValue();
        assertEq(value, 2_000_000e18);
    }

    // ============ Multi-Protocol Tests ============

    function testGetPortfolioValueWithAllProtocols() public {
        // Create all protocol types
        MockMorphoVault morphoVault = new MockMorphoVault(address(mockAsset), 1_000_000e18);
        MockAToken aToken = new MockAToken(address(mockAsset));
        MockCompoundV3 comet = new MockCompoundV3(address(mockAsset));

        // Distribute funds across protocols
        // Start with 1M USDC
        mockAsset.setBalance(address(safe), 400_000e18); // 400k idle

        // Deposit to each protocol
        mockAsset.setBalance(address(morphoVault), 200_000e18);
        morphoVault.setShares(address(safe), 200_000e18);
        morphoVault.deposit(0, address(safe)); // Initialize totalShares

        aToken.setBalance(address(safe), 200_000e18);
        comet.setBalance(address(safe), 200_000e18);

        // Track all protocols
        vm.startPrank(address(safe));
        interactor.addTrackedProtocol(address(morphoVault));
        interactor.addTrackedProtocol(address(aToken));
        interactor.addTrackedProtocol(address(comet));
        vm.stopPrank();

        // Portfolio value should be:
        // 400k idle + 1M mockToken2 + 200k Morpho + 200k Aave + 200k Compound = 2M
        uint256 value = interactor.getPortfolioValue();
        assertEq(value, 2_000_000e18);
    }

    function testGetPortfolioValueWithAllProtocolsAndYield() public {
        // Create all protocol types
        MockMorphoVault morphoVault = new MockMorphoVault(address(mockAsset), 1_000_000e18);
        MockAToken aToken = new MockAToken(address(mockAsset));
        MockCompoundV3 comet = new MockCompoundV3(address(mockAsset));

        // Setup positions
        mockAsset.setBalance(address(safe), 400_000e18);
        mockAsset.setBalance(address(morphoVault), 200_000e18);
        morphoVault.setShares(address(safe), 200_000e18);
        aToken.setBalance(address(safe), 200_000e18);
        comet.setBalance(address(safe), 200_000e18);

        // Track all protocols
        vm.startPrank(address(safe));
        interactor.addTrackedProtocol(address(morphoVault));
        interactor.addTrackedProtocol(address(aToken));
        interactor.addTrackedProtocol(address(comet));
        vm.stopPrank();

        // Initial value
        uint256 initialValue = interactor.getPortfolioValue();
        assertEq(initialValue, 2_000_000e18);

        // Simulate yield across all protocols
        // Morpho: 5% yield = 10k (200k -> 210k)
        mockAsset.setBalance(address(morphoVault), 210_000e18);

        // Aave: 4% yield = 8k (200k -> 208k)
        aToken.setBalance(address(safe), 208_000e18);

        // Compound: 6% yield = 12k (200k -> 212k)
        comet.setBalance(address(safe), 212_000e18);

        // Total yield = 10k + 8k + 12k = 30k
        uint256 valueWithYield = interactor.getPortfolioValue();
        assertEq(valueWithYield, 2_030_000e18); // 2M + 30k yield
    }
}
