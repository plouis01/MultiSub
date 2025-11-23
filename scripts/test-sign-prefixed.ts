import { privateKeyToAccount } from 'viem/accounts'
import { keccak256, concat, toHex, recoverAddress } from 'viem'
import * as dotenv from 'dotenv'

dotenv.config()

async function main() {
  const SUB_ACCOUNT_PRIVATE_KEY = process.env.SUB_ACCOUNT_PRIVATE_KEY as `0x${string}`
  const subAccount = privateKeyToAccount(SUB_ACCOUNT_PRIVATE_KEY)

  const userOpHash = '0x06f81c48a0a2195948fd27f9fe2857d90dc70bd4c3e284bdfef73d56796aa0ce' as `0x${string}`

  console.log('Sub-account address:', subAccount.address)
  console.log('UserOp hash:', userOpHash)

  // Method 1: Sign raw hash (current approach)
  const sig1 = await subAccount.sign({
    hash: userOpHash
  })
  console.log('\nMethod 1: sign({ hash: userOpHash })')
  console.log('Signature:', sig1)

  // Verify what this recovers to after adding prefix
  const prefix = toHex('\x19Ethereum Signed Message:\n32')
  const prefixedHash = keccak256(concat([prefix, userOpHash]))
  console.log('Prefixed hash:', prefixedHash)

  const recovered1 = await recoverAddress({
    hash: prefixedHash,
    signature: sig1
  })
  console.log('Recovered address:', recovered1)
  console.log('Match:', recovered1.toLowerCase() === subAccount.address.toLowerCase())

  // Method 2: Sign the prefixed hash directly
  console.log('\nMethod 2: sign({ hash: prefixedHash })')
  const sig2 = await subAccount.sign({
    hash: prefixedHash
  })
  console.log('Signature:', sig2)

  const recovered2 = await recoverAddress({
    hash: prefixedHash,
    signature: sig2
  })
  console.log('Recovered address:', recovered2)
  console.log('Match:', recovered2.toLowerCase() === subAccount.address.toLowerCase())
}

main().catch(console.error)
