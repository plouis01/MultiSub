.PHONY: all test clean deploy

# Default target
all: clean install build test

# Install dependencies
install:
	forge install foundry-rs/forge-std

# Build the project
build:
	forge build

# Run tests
test:
	forge test -vv

# Run tests with gas reporting
test-gas:
	forge test --gas-report

# Run tests with coverage
coverage:
	forge coverage

# Clean build artifacts
clean:
	forge clean

# Format code
format:
	forge fmt

# Deploy to Sepolia
deploy-sepolia:
	@echo "Deploying to Sepolia..."
	forge script script/DeploySmartWallet.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		-vvvv

# Setup roles and permissions
setup-roles:
	@echo "Setting up roles..."
	forge script script/SetupRoles.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		-vvvv

# Example interaction with vault
interact:
	@echo "Interacting with vault..."
	forge script script/InteractWithVault.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		-vvvv

# Verify contracts
verify:
	@echo "Verifying contracts..."
	forge verify-contract \
		$(SMART_WALLET_ADDRESS) \
		src/SmartWallet.sol:SmartWallet \
		--chain-id 11155111 \
		--constructor-args $(shell cast abi-encode "constructor(address,address)" $(SAFE_ADDRESS) $(ZODIAC_ROLES_ADDRESS))

# Run local node for testing
anvil:
	anvil

# Help
help:
	@echo "Available commands:"
	@echo "  make install         - Install dependencies"
	@echo "  make build           - Build contracts"
	@echo "  make test            - Run tests"
	@echo "  make test-gas        - Run tests with gas reporting"
	@echo "  make coverage        - Generate coverage report"
	@echo "  make clean           - Clean build artifacts"
	@echo "  make format          - Format code"
	@echo "  make deploy-sepolia  - Deploy to Sepolia testnet"
	@echo "  make setup-roles     - Setup roles and permissions"
	@echo "  make interact        - Interact with vault"
	@echo "  make verify          - Verify contracts on Etherscan"
	@echo "  make anvil           - Run local test node"
