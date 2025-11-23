#!/bin/bash

# Setup script for running a local ERC-4337 bundler for Zircuit

set -e

echo "=== ERC-4337 Local Bundler Setup ==="
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    echo "Visit: https://docs.docker.com/get-docker/"
    exit 1
fi

# Option selection
echo "Choose bundler implementation:"
echo "1) Docker-based bundler (Infinitism - Easiest)"
echo "2) Manual setup - Infinitism (TypeScript)"
echo "3) Manual setup - Stackup (Go - Production ready)"
read -p "Enter choice [1-3]: " choice

case $choice in
    1)
        echo ""
        echo "=== Docker-based Bundler Setup ==="
        echo ""

        # Check for .env file
        if [ ! -f "../.env" ]; then
            echo "Creating .env file..."
            cat > ../.env << EOF
# Bundler configuration
BUNDLER_MNEMONIC="test test test test test test test test test test test junk"
BUNDLER_BENEFICIARY=0x0000000000000000000000000000000000000000
BUNDLER_PRIVATE_KEY=
EOF
            echo "Please edit ../.env and set BUNDLER_MNEMONIC or BUNDLER_PRIVATE_KEY"
            echo "The bundler account needs ETH to pay for gas when submitting bundles"
            exit 1
        fi

        echo "Starting bundler with Docker Compose..."
        docker-compose -f bundler-docker-compose.yml up -d

        echo ""
        echo "✓ Bundler started successfully!"
        echo "  Bundler RPC: http://localhost:3000"
        echo "  Logs: docker-compose -f scripts/bundler-docker-compose.yml logs -f"
        echo "  Stop: docker-compose -f scripts/bundler-docker-compose.yml down"
        echo ""
        echo "Update your .env file:"
        echo "  BUNDLER_RPC_URL=http://localhost:3000"
        ;;

    2)
        echo ""
        echo "=== Infinitism Bundler Setup ==="
        echo ""

        if [ ! -d "bundler" ]; then
            echo "Cloning bundler repository..."
            git clone https://github.com/eth-infinitism/bundler.git
            cd bundler
        else
            echo "Bundler directory exists, using existing clone"
            cd bundler
        fi

        echo "Installing dependencies..."
        yarn install

        echo "Building bundler..."
        yarn build

        echo ""
        echo "✓ Bundler built successfully!"
        echo ""
        echo "To run the bundler:"
        echo "  cd scripts/bundler"
        echo "  yarn run bundler \\"
        echo "    --network https://zircuit1-mainnet.p2pify.com/ \\"
        echo "    --entryPoint 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789 \\"
        echo "    --port 3000 \\"
        echo "    --unsafe \\"
        echo "    --mnemonic 'your mnemonic here'"
        echo ""
        echo "Then set in .env: BUNDLER_RPC_URL=http://localhost:3000"
        ;;

    3)
        echo ""
        echo "=== Stackup Bundler Setup ==="
        echo ""

        if [ ! -d "stackup-bundler" ]; then
            echo "Cloning Stackup bundler..."
            git clone https://github.com/stackup-wallet/stackup-bundler.git
            cd stackup-bundler
        else
            echo "Stackup bundler exists, using existing clone"
            cd stackup-bundler
        fi

        echo "Building bundler (requires Go)..."
        if ! command -v go &> /dev/null; then
            echo "Go is not installed. Install from: https://go.dev/dl/"
            exit 1
        fi

        make install

        echo ""
        echo "Creating config.yaml..."
        cat > config.yaml << EOF
erc4337_bundler_eth_client_url: "https://zircuit1-mainnet.p2pify.com/"
erc4337_bundler_private_key: "YOUR_PRIVATE_KEY_HERE"
erc4337_bundler_entry_points: "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789"
erc4337_bundler_port: 4337
erc4337_bundler_max_verification_gas: 1500000
erc4337_bundler_max_batch_gas_limit: 15000000
EOF

        echo ""
        echo "✓ Bundler built successfully!"
        echo ""
        echo "Edit config.yaml and set your private key, then run:"
        echo "  cd scripts/stackup-bundler"
        echo "  ./stackup-bundler start --mode private"
        echo ""
        echo "Then set in .env: BUNDLER_RPC_URL=http://localhost:4337"
        ;;

    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "=== Next Steps ==="
echo "1. Ensure bundler account has ETH for gas"
echo "2. Set BUNDLER_RPC_URL in your .env file"
echo "3. Run your zerolend-paymaster-tx script"
