#!/usr/bin/env tsx

import 'dotenv/config'
import { createWalletClient, createPublicClient, http, parseEther, type Address } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { zircuit } from 'viem/chains'

const PAYMASTER_SIGNER_PRIVATE_KEY = process.env.PAYMASTER_SIGNER_PRIVATE_KEY as `0x${string}`
const ZIRCUIT_RPC_URL = process.env.ZIRCUIT_RPC_URL || 'https://zircuit1-mainnet.p2pify.com/'
const ENTRYPOINT_V06 = '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789'
const PAYMASTER_ADDRESS = '0x19aC2530943ea198F3E8b37891b42074e8D4DDd1'

async function main() {
  const paymasterSigner = privateKeyToAccount(PAYMASTER_SIGNER_PRIVATE_KEY)

  const publicClient = createPublicClient({
    chain: zircuit,
    transport: http(ZIRCUIT_RPC_URL)
  })

  const walletClient = createWalletClient({
    account: paymasterSigner,
    chain: zircuit,
    transport: http(ZIRCUIT_RPC_URL)
  })

  console.log('=== Funding Paymaster in EntryPoint ===\n')
  console.log(`Paymaster: ${PAYMASTER_ADDRESS}`)
  console.log(`EntryPoint: ${ENTRYPOINT_V06}`)
  console.log(`Funding from: ${paymasterSigner.address}`)

  // Check current balance
  const currentBalance = await publicClient.readContract({
    address: ENTRYPOINT_V06 as Address,
    abi: [{
      inputs: [{ name: 'account', type: 'address' }],
      name: 'balanceOf',
      outputs: [{ name: '', type: 'uint256' }],
      stateMutability: 'view',
      type: 'function'
    }],
    functionName: 'balanceOf',
    args: [PAYMASTER_ADDRESS as Address]
  })

  console.log(`\nCurrent balance: ${currentBalance} wei (${Number(currentBalance) / 1e18} ETH)`)

  // Deposit 0.01 ETH
  const depositAmount = parseEther('0.01')
  console.log(`\nDepositing: ${depositAmount} wei (0.01 ETH)`)

  const hash = await walletClient.writeContract({
    address: ENTRYPOINT_V06 as Address,
    abi: [{
      inputs: [{ name: 'account', type: 'address' }],
      name: 'depositTo',
      outputs: [],
      stateMutability: 'payable',
      type: 'function'
    }],
    functionName: 'depositTo',
    args: [PAYMASTER_ADDRESS as Address],
    value: depositAmount
  })

  console.log(`\nTransaction hash: ${hash}`)
  console.log('Waiting for confirmation...')

  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  console.log(`✓ Transaction confirmed in block ${receipt.blockNumber}`)

  // Check new balance
  const newBalance = await publicClient.readContract({
    address: ENTRYPOINT_V06 as Address,
    abi: [{
      inputs: [{ name: 'account', type: 'address' }],
      name: 'balanceOf',
      outputs: [{ name: '', type: 'uint256' }],
      stateMutability: 'view',
      type: 'function'
    }],
    functionName: 'balanceOf',
    args: [PAYMASTER_ADDRESS as Address]
  })

  console.log(`\nNew balance: ${newBalance} wei (${Number(newBalance) / 1e18} ETH)`)
  console.log(`Difference: ${newBalance - currentBalance} wei`)
}

main().catch(console.error)
