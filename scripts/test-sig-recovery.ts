import { recoverAddress } from 'viem'
import { keccak256, concat, toHex } from 'viem'

async function main() {
  const userOpHash = '0x06f81c48a0a2195948fd27f9fe2857d90dc70bd4c3e284bdfef73d56796aa0ce'
  const signature = '0x374e1d8cd4e45de06aafc9f1022198e8522075fc1531f15721c43596b93189e70a0e6f8fa0beaede309f432ee521eea8829391b1b3c86d1e22d01d0a2dcf1e6b1c'

  // Add Ethereum Signed Message prefix
  const prefix = toHex('\x19Ethereum Signed Message:\n32')
  const prefixedHash = keccak256(concat([prefix as `0x${string}`, userOpHash as `0x${string}`]))

  console.log('UserOp hash:', userOpHash)
  console.log('Prefixed hash:', prefixedHash)
  console.log('Signature:', signature)

  const recovered = await recoverAddress({
    hash: prefixedHash as `0x${string}`,
    signature: signature as `0x${string}`
  })

  console.log('Recovered address:', recovered)
  console.log('Expected address:', '0x962aCEB4C3C53f09110106D08364A8B40eA54568')
  console.log('Match:', recovered.toLowerCase() === '0x962aCEB4C3C53f09110106D08364A8B40eA54568'.toLowerCase())
}

main().catch(console.error)
