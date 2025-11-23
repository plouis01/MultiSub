#!/usr/bin/env tsx

/**
 * ZeroLend Withdrawal Script with MultiSubPaymaster
 *
 * This script creates and executes a UserOperation to withdraw the full
 * aToken balance from ZeroLend on Zircuit, with gas sponsored by the
 * MultiSubPaymaster.
 *
 * Features:
 * - Fetches the full aToken balance automatically
 * - Constructs ERC-4337 UserOperation for withdrawal
 * - Generates EIP-712 paymaster signature
 * - Submits to bundler for execution
 * - Monitors transaction status
 *
 * Prerequisites:
 * - Sub-account has DEFI_EXECUTE_ROLE in DeFiInteractorModule
 * - Paymaster is funded with ETH
 * - ZeroLend Pool is whitelisted for sub-account
 * - Safe has aToken balance from previous supply operations
 *
 * The script will withdraw ALL available aTokens back to WETH.
 */

import 'dotenv/config'
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  encodeFunctionData,
  encodeAbiParameters,
  parseAbiParameters,
  keccak256,
  concat,
  pad,
  toHex,
  hexToBigInt,
  formatEther,
  type Address,
  type Hex
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { zircuit } from 'viem/chains'

// ============ Configuration ============

const ZIRCUIT_RPC_URL = process.env.ZIRCUIT_RPC_URL || 'https://zircuit1-mainnet.p2pify.com/'
// EntryPoint v0.6 (v0.8 not yet deployed on Zircuit)
const ENTRYPOINT_V06 = '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789'
const BUNDLER_RPC_URL = process.env.BUNDLER_RPC_URL || ZIRCUIT_RPC_URL // Fallback to regular RPC
const USE_INTERNAL_BUNDLER = process.env.USE_INTERNAL_BUNDLER === 'true' // Set to 'true' to act as bundler

// Contract addresses - replace with your deployed contracts
const SAFE_ADDRESS = process.env.SAFE_ADDRESS as Address
const SAFE_ERC4337_ACCOUNT = process.env.SAFE_ERC4337_ACCOUNT as Address
const PAYMASTER_ADDRESS = process.env.PAYMASTER_ADDRESS as Address
const DEFI_MODULE_ADDRESS = process.env.DEFI_MODULE_ADDRESS as Address

// ZeroLend on Zircuit
const ZEROLEND_POOL = '0x2774C8B95CaB474D0d21943d83b9322Fb1cE9cF5' as Address
const WETH_ADDRESS = '0x4200000000000000000000000000000000000006' as Address

// Private keys
const SUB_ACCOUNT_KEY = process.env.SUB_ACCOUNT_PRIVATE_KEY as Hex
const PAYMASTER_SIGNER_KEY = process.env.PAYMASTER_SIGNER_PRIVATE_KEY as Hex
const BUNDLER_PRIVATE_KEY = process.env.BUNDLER_PRIVATE_KEY as Hex | undefined // Only needed if USE_INTERNAL_BUNDLER=true

// ============ ABIs ============

const ZEROLEND_POOL_ABI = [
  {
    inputs: [
      { name: 'asset', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'to', type: 'address' }
    ],
    name: 'withdraw',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [{ name: 'asset', type: 'address' }],
    name: 'getReserveData',
    outputs: [
      {
        components: [
          { name: 'configuration', type: 'uint256' },
          { name: 'liquidityIndex', type: 'uint128' },
          { name: 'currentLiquidityRate', type: 'uint128' },
          { name: 'variableBorrowIndex', type: 'uint128' },
          { name: 'currentVariableBorrowRate', type: 'uint128' },
          { name: 'currentStableBorrowRate', type: 'uint128' },
          { name: 'lastUpdateTimestamp', type: 'uint40' },
          { name: 'id', type: 'uint16' },
          { name: 'aTokenAddress', type: 'address' },
          { name: 'stableDebtTokenAddress', type: 'address' },
          { name: 'variableDebtTokenAddress', type: 'address' },
          { name: 'interestRateStrategyAddress', type: 'address' },
          { name: 'accruedToTreasury', type: 'uint128' },
          { name: 'unbacked', type: 'uint128' },
          { name: 'isolationModeTotalDebt', type: 'uint128' }
        ],
        name: '',
        type: 'tuple'
      }
    ],
    stateMutability: 'view',
    type: 'function'
  }
] as const

const DEFI_MODULE_ABI = [
  {
    inputs: [
      { name: 'target', type: 'address' },
      { name: 'data', type: 'bytes' }
    ],
    name: 'executeOnProtocol',
    outputs: [{ name: 'result', type: 'bytes' }],
    stateMutability: 'nonpayable',
    type: 'function'
  }
] as const

const ERC20_ABI = [
  {
    inputs: [{ name: 'account', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const

const SAFE_ERC4337_ABI = [
  {
    inputs: [
      { name: 'dest', type: 'address[]' },
      { name: 'value', type: 'uint256[]' },
      { name: 'func', type: 'bytes[]' }
    ],
    name: 'executeBatch',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  }
] as const

const ENTRYPOINT_ABI = [
  {
    inputs: [{ name: 'sender', type: 'address' }],
    name: 'getNonce',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const

const ENTRYPOINT_HANDLE_OPS_ABI = [
  {
    inputs: [
      {
        components: [
          { name: 'sender', type: 'address' },
          { name: 'nonce', type: 'uint256' },
          { name: 'initCode', type: 'bytes' },
          { name: 'callData', type: 'bytes' },
          { name: 'accountGasLimits', type: 'bytes32' },
          { name: 'preVerificationGas', type: 'uint256' },
          { name: 'gasFees', type: 'bytes32' },
          { name: 'paymasterAndData', type: 'bytes' },
          { name: 'signature', type: 'bytes' }
        ],
        name: 'ops',
        type: 'tuple[]'
      },
      { name: 'beneficiary', type: 'address' }
    ],
    name: 'handleOps',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  }
] as const

// ============ Types ============

interface PackedUserOperation {
  sender: Address
  nonce: bigint
  initCode: Hex
  callData: Hex
  accountGasLimits: Hex // Pack of verificationGasLimit and callGasLimit
  preVerificationGas: bigint
  gasFees: Hex // Pack of maxPriorityFeePerGas and maxFeePerGas
  paymasterAndData: Hex
  signature: Hex
}

// ============ Helper Functions ============

/**
 * Pack gas limits into accountGasLimits
 */
function packAccountGasLimits(verificationGasLimit: bigint, callGasLimit: bigint): Hex {
  const verificationGas = pad(toHex(verificationGasLimit), { size: 16 })
  const callGas = pad(toHex(callGasLimit), { size: 16 })
  return concat([verificationGas, callGas])
}

/**
 * Pack fee per gas into gasFees
 */
function packGasFees(maxPriorityFeePerGas: bigint, maxFeePerGas: bigint): Hex {
  const priorityFee = pad(toHex(maxPriorityFeePerGas), { size: 16 })
  const maxFee = pad(toHex(maxFeePerGas), { size: 16 })
  return concat([priorityFee, maxFee])
}

/**
 * Get user operation hash for EntryPoint v0.6
 */
function getUserOpHash(
  userOp: PackedUserOperation,
  entryPoint: Address,
  chainId: number
): Hex {
  const packedData = encodeAbiParameters(
    parseAbiParameters('address, uint256, bytes32, bytes32, bytes32, uint256, bytes32, bytes32'),
    [
      userOp.sender,
      userOp.nonce,
      keccak256(userOp.initCode),
      keccak256(userOp.callData),
      userOp.accountGasLimits,
      userOp.preVerificationGas,
      userOp.gasFees,
      keccak256(userOp.paymasterAndData)
    ]
  )

  const userOpHash = keccak256(packedData)

  const entryPointData = encodeAbiParameters(
    parseAbiParameters('bytes32, address, uint256'),
    [userOpHash, entryPoint, BigInt(chainId)]
  )

  return keccak256(entryPointData)
}

/**
 * Generate EIP-712 signature for paymaster
 */
async function generatePaymasterSignature(
  userOp: PackedUserOperation,
  validAfter: number,
  validUntil: number,
  paymasterSignerKey: Hex
): Promise<{ signature: Hex; validAfter: number; validUntil: number }> {
  const account = privateKeyToAccount(paymasterSignerKey)

  // EIP-712 domain
  const domain = {
    name: 'MultiSubPaymaster',
    version: '1',
    chainId: zircuit.id,
    verifyingContract: PAYMASTER_ADDRESS
  }

  // EIP-712 types
  const types = {
    PaymasterData: [
      { name: 'sender', type: 'address' },
      { name: 'nonce', type: 'uint256' },
      { name: 'initCode', type: 'bytes32' },
      { name: 'callData', type: 'bytes32' },
      { name: 'accountGasLimits', type: 'bytes32' },
      { name: 'preVerificationGas', type: 'uint256' },
      { name: 'gasFees', type: 'bytes32' },
      { name: 'validAfter', type: 'uint48' },
      { name: 'validUntil', type: 'uint48' }
    ]
  }

  // Message to sign
  const message = {
    sender: userOp.sender,
    nonce: userOp.nonce,
    initCode: keccak256(userOp.initCode),
    callData: keccak256(userOp.callData),
    accountGasLimits: userOp.accountGasLimits,
    preVerificationGas: userOp.preVerificationGas,
    gasFees: userOp.gasFees,
    validAfter: BigInt(validAfter),
    validUntil: BigInt(validUntil)
  }

  // Sign using EIP-712
  const signature = await account.signTypedData({
    domain,
    types,
    primaryType: 'PaymasterData',
    message
  })

  return {
    signature,
    validAfter,
    validUntil
  }
}

/**
 * Pack paymaster and data
 */
function packPaymasterAndData(
  paymaster: Address,
  validAfter: number,
  validUntil: number,
  signature: Hex
): Hex {
  const validAfterHex = pad(toHex(validAfter), { size: 6 })
  const validUntilHex = pad(toHex(validUntil), { size: 6 })
  return concat([paymaster, validAfterHex, validUntilHex, signature])
}

// ============ Main Script ============

async function main() {
  console.log('🚀 ZeroLend Withdrawal Transaction with MultiSubPaymaster')
  console.log('=' .repeat(60))

  // Validate environment variables
  if (!SAFE_ADDRESS || !SAFE_ERC4337_ACCOUNT || !PAYMASTER_ADDRESS || !DEFI_MODULE_ADDRESS) {
    throw new Error('Missing required environment variables. Check your .env file.')
  }

  if (!SUB_ACCOUNT_KEY || !PAYMASTER_SIGNER_KEY) {
    throw new Error('Missing private keys. Check your .env file.')
  }

  // Setup clients
  const publicClient = createPublicClient({
    chain: zircuit,
    transport: http(ZIRCUIT_RPC_URL)
  })

  const subAccount = privateKeyToAccount(SUB_ACCOUNT_KEY)
  const paymasterSigner = privateKeyToAccount(PAYMASTER_SIGNER_KEY)

  console.log('\n📋 Configuration:')
  console.log(`  Safe: ${SAFE_ADDRESS}`)
  console.log(`  Safe ERC4337 Account: ${SAFE_ERC4337_ACCOUNT}`)
  console.log(`  Paymaster: ${PAYMASTER_ADDRESS}`)
  console.log(`  DeFi Module: ${DEFI_MODULE_ADDRESS}`)
  console.log(`  Sub-account: ${subAccount.address}`)
  console.log(`  Paymaster Signer: ${paymasterSigner.address}`)
  console.log(`  ZeroLend Pool: ${ZEROLEND_POOL}`)
  console.log(`  WETH: ${WETH_ADDRESS}`)

  // Step 1: Get aToken address
  console.log('\n📊 Step 1: Fetching aToken address...')
  const reserveData = await publicClient.readContract({
    address: ZEROLEND_POOL,
    abi: ZEROLEND_POOL_ABI,
    functionName: 'getReserveData',
    args: [WETH_ADDRESS]
  })

  const aTokenAddress = reserveData.aTokenAddress as Address
  console.log(`  aToken address: ${aTokenAddress}`)

  // Step 2: Check aToken balance
  console.log('\n💰 Step 2: Checking aToken balance...')
  const aTokenBalance = await publicClient.readContract({
    address: aTokenAddress,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: [SAFE_ADDRESS]
  }) as bigint

  console.log(`  Safe aToken balance: ${formatEther(aTokenBalance)} aWETH`)

  if (aTokenBalance === 0n) {
    console.log('\n❌ No aTokens to withdraw!')
    console.log('Please supply WETH to ZeroLend first.')
    return
  }

  // Use max uint256 to withdraw all
  const WITHDRAW_AMOUNT = BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')
  console.log('  Withdrawing: ALL (using type(uint256).max)')

  // Step 3: Build the withdraw call
  console.log('\n🔨 Step 3: Building withdraw transaction...')

  const withdrawCallData = encodeFunctionData({
    abi: ZEROLEND_POOL_ABI,
    functionName: 'withdraw',
    args: [WETH_ADDRESS, WITHDRAW_AMOUNT, SAFE_ADDRESS]
  })

  console.log(`  Withdraw calldata: ${withdrawCallData.slice(0, 66)}...`)

  // Step 4: Wrap in DeFi Module call
  const moduleCallData = encodeFunctionData({
    abi: DEFI_MODULE_ABI,
    functionName: 'executeOnProtocol',
    args: [ZEROLEND_POOL, withdrawCallData]
  })

  console.log(`  Module calldata: ${moduleCallData.slice(0, 66)}...`)

  // Step 5: Wrap in Safe executeBatch call
  const safeCallData = encodeFunctionData({
    abi: SAFE_ERC4337_ABI,
    functionName: 'executeBatch',
    args: [
      [DEFI_MODULE_ADDRESS], // dest
      [0n], // value
      [moduleCallData] // func
    ]
  })

  console.log(`  Safe calldata: ${safeCallData.slice(0, 66)}...`)

  // Step 6: Get nonce from EntryPoint
  console.log('\n🔢 Step 4: Getting nonce from EntryPoint...')
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT_V06 as Address,
    abi: ENTRYPOINT_ABI,
    functionName: 'getNonce',
    args: [SAFE_ERC4337_ACCOUNT]
  }) as bigint

  console.log(`  Nonce: ${nonce}`)

  // Step 7: Build UserOperation
  console.log('\n📝 Step 5: Building UserOperation...')

  // Gas parameters (adjust based on your needs)
  const verificationGasLimit = 200000n
  const callGasLimit = 500000n
  const preVerificationGas = 100000n
  const maxPriorityFeePerGas = 1000000n // 0.001 gwei
  const maxFeePerGas = 1000000n // 0.001 gwei

  const userOp: PackedUserOperation = {
    sender: SAFE_ERC4337_ACCOUNT,
    nonce,
    initCode: '0x' as Hex,
    callData: safeCallData,
    accountGasLimits: packAccountGasLimits(verificationGasLimit, callGasLimit),
    preVerificationGas,
    gasFees: packGasFees(maxPriorityFeePerGas, maxFeePerGas),
    paymasterAndData: '0x' as Hex, // Will be filled after signature
    signature: '0x' as Hex // Will be filled later
  }

  console.log('  UserOp created')
  console.log(`  Sender: ${userOp.sender}`)
  console.log(`  Nonce: ${userOp.nonce}`)
  console.log(`  Verification Gas: ${verificationGasLimit}`)
  console.log(`  Call Gas: ${callGasLimit}`)

  // Step 8: Generate paymaster signature
  console.log('\n✍️  Step 6: Generating paymaster signature...')
  const validAfter = Math.floor(Date.now() / 1000) - 60 // 1 minute ago
  const validUntil = Math.floor(Date.now() / 1000) + 3600 // 1 hour from now

  const paymasterSig = await generatePaymasterSignature(
    userOp,
    validAfter,
    validUntil,
    PAYMASTER_SIGNER_KEY
  )

  console.log(`  Paymaster signature generated`)
  console.log(`  Valid from: ${new Date(validAfter * 1000).toISOString()}`)
  console.log(`  Valid until: ${new Date(validUntil * 1000).toISOString()}`)

  // Step 9: Pack paymaster and data
  userOp.paymasterAndData = packPaymasterAndData(
    PAYMASTER_ADDRESS,
    paymasterSig.validAfter,
    paymasterSig.validUntil,
    paymasterSig.signature
  )

  console.log(`  Paymaster data packed: ${userOp.paymasterAndData.slice(0, 66)}...`)

  // Step 10: Sign UserOperation
  console.log('\n✍️  Step 7: Signing UserOperation...')
  const userOpHash = getUserOpHash(userOp, ENTRYPOINT_V06 as Address, zircuit.id)
  console.log(`  UserOp hash: ${userOpHash}`)

  const userOpSignature = await subAccount.signMessage({
    message: { raw: userOpHash }
  })

  userOp.signature = userOpSignature
  console.log(`  UserOp signed: ${userOpSignature.slice(0, 66)}...`)

  // Step 11: Submit UserOperation
  if (USE_INTERNAL_BUNDLER) {
    // Act as bundler - submit directly to EntryPoint
    console.log('\n=== Step 8: Acting as Internal Bundler ===')

    if (!BUNDLER_PRIVATE_KEY) {
      console.error('Error: BUNDLER_PRIVATE_KEY is required when USE_INTERNAL_BUNDLER=true')
      process.exit(1)
    }

    const bundlerAccount = privateKeyToAccount(BUNDLER_PRIVATE_KEY)
    console.log(`  Bundler account: ${bundlerAccount.address}`)

    // Check bundler has ETH
    const bundlerBalance = await publicClient.getBalance({ address: bundlerAccount.address })
    console.log(`  Bundler ETH balance: ${formatEther(bundlerBalance)} ETH`)

    if (bundlerBalance < parseEther('0.001')) {
      console.error('⚠️  Warning: Bundler has low ETH balance. Transaction may fail.')
    }

    const bundlerWallet = createWalletClient({
      account: bundlerAccount,
      chain: zircuit,
      transport: http(ZIRCUIT_RPC_URL)
    })

    try {
      console.log('  Submitting bundle to EntryPoint...')
      const hash = await bundlerWallet.writeContract({
        address: ENTRYPOINT_V06 as Address,
        abi: ENTRYPOINT_HANDLE_OPS_ABI,
        functionName: 'handleOps',
        args: [
          [{
            sender: userOp.sender,
            nonce: userOp.nonce,
            initCode: userOp.initCode,
            callData: userOp.callData,
            accountGasLimits: userOp.accountGasLimits,
            preVerificationGas: userOp.preVerificationGas,
            gasFees: userOp.gasFees,
            paymasterAndData: userOp.paymasterAndData,
            signature: userOp.signature
          }],
          bundlerAccount.address // Beneficiary receives refunds
        ]
      })

      console.log(`  ✓ Bundle transaction submitted: ${hash}`)
      console.log(`  Waiting for confirmation...`)

      const receipt = await publicClient.waitForTransactionReceipt({ hash })

      if (receipt.status === 'success') {
        console.log(`\n✅ Transaction confirmed!`)
        console.log(`  Transaction hash: ${receipt.transactionHash}`)
        console.log(`  Block: ${receipt.blockNumber}`)
        console.log(`  Gas used: ${receipt.gasUsed}`)

        // Check updated balances
        console.log('\n💰 Step 9: Checking updated balances...')

        const newATokenBalance = await publicClient.readContract({
          address: aTokenAddress,
          abi: ERC20_ABI,
          functionName: 'balanceOf',
          args: [SAFE_ADDRESS]
        }) as bigint

        const wethBalance = await publicClient.readContract({
          address: WETH_ADDRESS,
          abi: ERC20_ABI,
          functionName: 'balanceOf',
          args: [SAFE_ADDRESS]
        }) as bigint

        console.log(`  Safe aToken balance: ${formatEther(newATokenBalance)} aWETH (was ${formatEther(aTokenBalance)})`)
        console.log(`  Safe WETH balance: ${formatEther(wethBalance)} WETH`)
        console.log(`  Withdrawn: ${formatEther(aTokenBalance - newATokenBalance)} WETH`)

        console.log('\n🎉 Withdrawal complete!')
      } else {
        console.error(`\n❌ Transaction failed!`)
        process.exit(1)
      }
    } catch (error) {
      console.error('\n❌ Error submitting bundle:', error)
      throw error
    }
  } else {
    // Use external bundler
    console.log('\n📤 Step 8: Submitting to bundler...')
    console.log(`  Bundler URL: ${BUNDLER_RPC_URL}`)

    try {
      // Submit UserOperation
      const response = await fetch(BUNDLER_RPC_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_sendUserOperation',
        params: [
          {
            sender: userOp.sender,
            nonce: `0x${userOp.nonce.toString(16)}`,
            initCode: userOp.initCode,
            callData: userOp.callData,
            accountGasLimits: userOp.accountGasLimits,
            preVerificationGas: `0x${userOp.preVerificationGas.toString(16)}`,
            gasFees: userOp.gasFees,
            paymasterAndData: userOp.paymasterAndData,
            signature: userOp.signature
          },
          ENTRYPOINT_V06
        ]
      })
    })

    const result = await response.json()

    if (result.error) {
      console.log('\n❌ Bundler error:')
      console.log(JSON.stringify(result.error, null, 2))
      throw new Error(`Bundler error: ${result.error.message}`)
    }

    const userOpHash = result.result
    console.log(`\n✅ UserOperation submitted!`)
    console.log(`  UserOp hash: ${userOpHash}`)

    // Step 12: Monitor receipt
    console.log('\n⏳ Step 9: Waiting for UserOperation receipt...')
    let receipt = null
    let attempts = 0
    const maxAttempts = 60

    while (!receipt && attempts < maxAttempts) {
      attempts++
      await new Promise(resolve => setTimeout(resolve, 2000)) // Wait 2 seconds

      const receiptResponse = await fetch(BUNDLER_RPC_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'eth_getUserOperationReceipt',
          params: [userOpHash]
        })
      })

      const receiptResult = await receiptResponse.json()
      if (receiptResult.result) {
        receipt = receiptResult.result
      } else {
        process.stdout.write('.')
      }
    }

    if (!receipt) {
      console.log('\n⚠️  Receipt not found after maximum attempts')
      console.log('Transaction may still be pending. Check bundler manually.')
      return
    }

    console.log('\n\n✅ Transaction confirmed!')
    console.log(`  Transaction hash: ${receipt.receipt.transactionHash}`)
    console.log(`  Block: ${receipt.receipt.blockNumber}`)
    console.log(`  Gas used: ${receipt.actualGasUsed}`)
    console.log(`  Success: ${receipt.success}`)

    // Step 13: Check updated balances
    console.log('\n💰 Step 10: Checking updated balances...')

    const newATokenBalance = await publicClient.readContract({
      address: aTokenAddress,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [SAFE_ADDRESS]
    }) as bigint

    const wethBalance = await publicClient.readContract({
      address: WETH_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [SAFE_ADDRESS]
    }) as bigint

    console.log(`  Safe aToken balance: ${formatEther(newATokenBalance)} aWETH (was ${formatEther(aTokenBalance)})`)
    console.log(`  Safe WETH balance: ${formatEther(wethBalance)} WETH`)
    console.log(`  Withdrawn: ${formatEther(aTokenBalance - newATokenBalance)} WETH`)

    console.log('\n🎉 Withdrawal complete!')

    } catch (error) {
      console.log('\n❌ Error:')
      if (error instanceof Error) {
        console.log(error.message)

        if (error.message.includes('bundler')) {
          console.log('\n💡 Note: Zircuit may not have ERC-4337 bundler support yet.')
          console.log('Consider using a third-party bundler service like Pimlico or Stackup.')
        }
      } else {
        console.log(error)
      }
      throw error
    }
  } // End of external bundler else block
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
