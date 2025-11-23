#!/usr/bin/env tsx

import { config } from 'dotenv'
import { createWalletClient, createPublicClient, http, parseEther, type Address } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { zircuit } from 'viem/chains'
import * as fs from 'fs'
import * as path from 'path'

// Load .env from parent directory
import { fileURLToPath } from 'url'
import { dirname } from 'path'
const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
config({ path: path.join(__dirname, '../.env') })

const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY as `0x${string}`
const ZIRCUIT_RPC_URL = process.env.ZIRCUIT_RPC_URL || 'https://zircuit1-mainnet.p2pify.com/'
const ENTRYPOINT_V06 = '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789'
const SAFE_ADDRESS = '0x051fd367fFB62780eBaE62634AD0e18558eD0c48'
const DEFI_MODULE_ADDRESS = '0x2c053b0f63437B51E12523CA02A8Efc8a733CdAd'
const PAYMASTER_SIGNER = '0x962aCEB4C3C53f09110106D08364A8B40eA54568'
const PAYMASTER_OWNER = '0x962aCEB4C3C53f09110106D08364A8B40eA54568'
const MAX_GAS_PER_OPERATION = 1000000n

async function main() {
  const deployer = privateKeyToAccount(DEPLOYER_PRIVATE_KEY)

  const publicClient = createPublicClient({
    chain: zircuit,
    transport: http(ZIRCUIT_RPC_URL)
  })

  const walletClient = createWalletClient({
    account: deployer,
    chain: zircuit,
    transport: http(ZIRCUIT_RPC_URL)
  })

  console.log('=== Deploying New Paymaster ===\n')
  console.log(`Deployer: ${deployer.address}`)
  console.log(`Safe: ${SAFE_ADDRESS}`)
  console.log(`DeFi Module: ${DEFI_MODULE_ADDRESS}`)
  console.log(`EntryPoint: ${ENTRYPOINT_V06}`)
  console.log(`Paymaster Signer: ${PAYMASTER_SIGNER}`)
  console.log(`Paymaster Owner: ${PAYMASTER_OWNER}`)

  // Read compiled contract bytecode
  const artifactsPath = path.join(__dirname, '../out')

  const safeAccountArtifact = JSON.parse(
    fs.readFileSync(path.join(artifactsPath, 'SafeERC4337Account.sol/SafeERC4337Account.json'), 'utf8')
  )

  const paymasterArtifact = JSON.parse(
    fs.readFileSync(path.join(artifactsPath, 'MultiSubPaymaster.sol/MultiSubPaymaster.json'), 'utf8')
  )

  // Deploy SafeERC4337Account
  console.log('\n1. Deploying SafeERC4337Account...')
  const safeAccountBytecode = safeAccountArtifact.bytecode.object
  const safeAccountAbi = safeAccountArtifact.abi

  const safeAccountHash = await walletClient.deployContract({
    abi: safeAccountAbi,
    bytecode: safeAccountBytecode as `0x${string}`,
    args: [SAFE_ADDRESS as Address, ENTRYPOINT_V06 as Address]
  })

  console.log(`  Transaction: ${safeAccountHash}`)
  console.log('  Waiting for confirmation...')

  const safeAccountReceipt = await publicClient.waitForTransactionReceipt({ hash: safeAccountHash })
  const safeAccountAddress = safeAccountReceipt.contractAddress!

  console.log(`  ✓ SafeERC4337Account deployed: ${safeAccountAddress}`)

  // Deploy MultiSubPaymaster
  console.log('\n2. Deploying MultiSubPaymaster...')
  const paymasterBytecode = paymasterArtifact.bytecode.object
  const paymasterAbi = paymasterArtifact.abi

  const paymasterHash = await walletClient.deployContract({
    abi: paymasterAbi,
    bytecode: paymasterBytecode as `0x${string}`,
    args: [
      ENTRYPOINT_V06 as Address,
      DEFI_MODULE_ADDRESS as Address,
      PAYMASTER_SIGNER as Address,
      PAYMASTER_OWNER as Address,
      MAX_GAS_PER_OPERATION
    ]
  })

  console.log(`  Transaction: ${paymasterHash}`)
  console.log('  Waiting for confirmation...')

  const paymasterReceipt = await publicClient.waitForTransactionReceipt({ hash: paymasterHash })
  const paymasterAddress = paymasterReceipt.contractAddress!

  console.log(`  ✓ MultiSubPaymaster deployed: ${paymasterAddress}`)

  // Fund paymaster via EntryPoint
  console.log('\n3. Funding paymaster in EntryPoint...')
  const depositAmount = parseEther('0.01')

  const depositHash = await walletClient.writeContract({
    address: ENTRYPOINT_V06 as Address,
    abi: [{
      inputs: [{ name: 'account', type: 'address' }],
      name: 'depositTo',
      outputs: [],
      stateMutability: 'payable',
      type: 'function'
    }],
    functionName: 'depositTo',
    args: [paymasterAddress],
    value: depositAmount
  })

  console.log(`  Transaction: ${depositHash}`)
  await publicClient.waitForTransactionReceipt({ hash: depositHash })
  console.log(`  ✓ Deposited ${depositAmount} wei to paymaster`)

  // Check balance
  const balance = await publicClient.readContract({
    address: ENTRYPOINT_V06 as Address,
    abi: [{
      inputs: [{ name: 'account', type: 'address' }],
      name: 'balanceOf',
      outputs: [{ name: '', type: 'uint256' }],
      stateMutability: 'view',
      type: 'function'
    }],
    functionName: 'balanceOf',
    args: [paymasterAddress]
  })

  console.log(`  Paymaster balance in EntryPoint: ${balance} wei (${Number(balance) / 1e18} ETH)`)

  console.log('\n=== Deployment Summary ===')
  console.log(`SafeERC4337Account: ${safeAccountAddress}`)
  console.log(`MultiSubPaymaster: ${paymasterAddress}`)
  console.log(`DeFi Module (configured): ${DEFI_MODULE_ADDRESS}`)

  console.log('\n=== Update Your Script ===')
  console.log('Update these values in your .env file:')
  console.log(`SAFE_ERC4337_ACCOUNT=${safeAccountAddress}`)
  console.log(`PAYMASTER_ADDRESS=${paymasterAddress}`)
}

main().catch(console.error)
