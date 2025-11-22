# Safe Withdrawal Monitor - Go Implementation

This is the **Go implementation** of the Safe withdrawal monitoring workflow using Chainlink Runtime Environment (CRE). This version uses the **EVM Log Trigger** capability which is fully supported in the Go SDK.

## Overview

This workflow automatically detects withdrawal transactions from DeFi protocols (Aave, Morpho, etc.) and updates subaccount allowances in real-time.

### How It Works

1. **Event-Driven**: Uses EVM Log Trigger to listen for `ProtocolExecuted` events
2. **Decodes Withdrawals**: Extracts withdrawal amount and token from transaction data
3. **Converts to USD**: Uses Chainlink price feeds for accurate USD valuation
4. **Updates Allowances**: Calls `updateSubaccountAllowances()` on-chain

### Key Advantages Over TypeScript Version

- ✅ **Fully Functional**: EVM Log Trigger is available in Go SDK
- ✅ **Event-Driven**: No polling, instant response to withdrawals
- ✅ **Production Ready**: Can be deployed immediately
- ✅ **Type Safe**: Leverages Go's type system and go-ethereum ABI handling

## Architecture

```
ProtocolExecuted Event
        ↓
[EVM Log Trigger]
        ↓
[OnProtocolExecuted Handler]
        ↓
    Extract nested calldata
        ↓
    Decode withdrawal (Aave/Morpho)
        ↓
    Get token decimals & price
        ↓
    Calculate USD value
        ↓
[updateSubaccountAllowances]
```

## Configuration

Edit `config.json`:

```json
{
  "moduleAddress": "0x...",           // DeFiInteractorModule contract
  "chainSelector": "16015286601757825753", // Ethereum Sepolia
  "gasLimit": 500000,
  "proxyAddress": "0x...",            // Chainlink CRE proxy
  "tokens": [
    {
      "address": "0x...",             // Token contract address
      "priceFeedAddress": "0x...",    // Chainlink price feed
      "symbol": "USDC",
      "type": "erc20"
    }
  ]
}
```

### Chain Selectors

Common chain selectors:
- Ethereum Mainnet: `5009297550715157269`
- Ethereum Sepolia: `16015286601757825753`
- Arbitrum One: `4949039107694359620`
- Base: `15971525489660198786`

## Code Structure

### Main Components

**`main.go`**:
- `OnProtocolExecuted()` - Event handler triggered by log events
- `ExtractProtocolCalldata()` - Extracts nested calldata from `executeOnProtocol`
- `DecodeWithdrawalAmount()` - Decodes Aave/Morpho withdrawal functions
- `GetPriceFromFeed()` - Fetches price from Chainlink oracle
- `CalculateUSDValue()` - Converts token amount to USD with 18 decimals
- `InitWorkflow()` - Sets up EVM log trigger

### Supported Protocols

**Aave** ✅
- Function: `withdraw(address asset, uint256 amount, address to)`
- Selector: `0x69328dec`
- Fully supported

**Morpho** ⚠️
- Functions: `withdraw()`, `redeem()`
- Selectors detected, but requires vault token mapping
- TODO: Add vault registry

## Installation

1. **Install Go** (1.21 or later)
```bash
go version
```

2. **Install dependencies**
```bash
cd safe-update-go
go mod download
```

3. **Update configuration**
```bash
# Edit config.json with your contract addresses
vi config.json
```

## Deployment

### Using Chainlink CRE

```bash
# From the CRE project root
cre workflow deploy ./safe-update-go --config=./safe-update-go/config.json
```

### Testing Locally

```bash
# Simulate the workflow
cre workflow simulate ./safe-update-go --config=./safe-update-go/config.json
```

## Example Flow

### Aave Withdrawal

1. **Subaccount** calls:
   ```solidity
   executeOnProtocol(
     aavePool,
     abi.encodeWithSelector(
       0x69328dec, // withdraw
       usdcAddress,
       1000000000, // 1000 USDC (6 decimals)
       safeAddress
     )
   )
   ```

2. **Module** emits:
   ```solidity
   ProtocolExecuted(subAccount, aavePool, block.timestamp)
   ```

3. **Workflow** (instantly triggered):
   ```
   - Detects event via log trigger
   - Extracts: executeOnProtocol(target, data)
   - Decodes nested data: withdraw(USDC, 1000000000, Safe)
   - Gets USDC decimals: 6
   - Gets USDC price: $1.00 (8 decimals)
   - Calculates: (1000000000 * 100000000 * 10^18) / (10^6 * 10^8) = 1000e18
   - Calls: updateSubaccountAllowances(subAccount, 1000e18)
   ```

4. **Result**:
   ```
   Previous allowance: $500
   New allowance: min($500 + $1000, $5000 total) = $1500
   ```

## Transaction Data Structure

The workflow handles nested transaction data:

```
executeOnProtocol calldata:
┌─────────────────────────────────────┐
│ Selector: 4 bytes                   │ executeOnProtocol selector
├─────────────────────────────────────┤
│ Target: 32 bytes                    │ Protocol address (e.g., Aave)
├─────────────────────────────────────┤
│ Data offset: 32 bytes               │ Offset to bytes data
├─────────────────────────────────────┤
│ Data length: 32 bytes               │ Length of bytes data
├─────────────────────────────────────┤
│ Nested calldata:                    │
│ ┌─────────────────────────────────┐ │
│ │ Selector: 4 bytes               │ │ withdraw selector (0x69328dec)
│ ├─────────────────────────────────┤ │
│ │ Asset: 32 bytes                 │ │ Token address
│ ├─────────────────────────────────┤ │
│ │ Amount: 32 bytes                │ │ Withdrawal amount
│ ├─────────────────────────────────┤ │
│ │ To: 32 bytes                    │ │ Recipient (Safe)
│ └─────────────────────────────────┘ │
└─────────────────────────────────────┘
```

## Functions

### `ExtractProtocolCalldata`
Extracts the nested calldata from `executeOnProtocol` transaction.

```go
// Input: Full executeOnProtocol transaction data
// Output: Just the protocol calldata (e.g., Aave withdraw call)
protocolCalldata, err := ExtractProtocolCalldata(runtime, tx.Data)
```

### `DecodeWithdrawalAmount`
Identifies and decodes withdrawal functions.

```go
// Returns: WithdrawalData{Amount, Token} or error
withdrawal, err := DecodeWithdrawalAmount(runtime, protocolCalldata)
```

### `CalculateUSDValue`
Converts token amount to USD with 18 decimals.

```go
// Formula: (amount * price * 10^18) / (10^(tokenDecimals + priceDecimals))
usdValue := CalculateUSDValue(amount, tokenDecimals, price, priceDecimals)
```

## Development

### Adding New Protocols

To support a new protocol (e.g., Compound):

1. Add the function selector:
```go
const CompoundRedeemSelector = "0xdb006a75"
```

2. Add decoding logic in `DecodeWithdrawalAmount`:
```go
if selector == CompoundRedeemSelector[2:] {
    runtime.Log("Detected Compound redeem function")
    // Decode parameters
    amount := new(big.Int).SetBytes(txData[4:36])
    // ...
    return &WithdrawalData{Amount: amount, Token: cTokenAsset}, nil
}
```

3. Update config with token mapping if needed

### Testing

```go
go test ./...
```

## Troubleshooting

### Common Issues

**"Invalid event log format"**
- Check that the event signature matches exactly
- Verify indexed parameters are in correct order

**"Transaction data too short"**
- Ensure the full transaction data is being passed
- Check that it's not just the event log data

**"Token not in config"**
- Add the withdrawn token to `config.json`
- Include price feed address for that token

**"Failed to get price"**
- Verify price feed address is correct
- Check that price feed is for the correct network
- Ensure price feed is active and updated

## Monitoring

The workflow logs detailed information:

```
ProtocolExecuted event received
Processing transaction for subAccount=0x..., target=0x...
Transaction selector: 0x69328dec
Detected Aave withdraw function
Aave withdrawal: 1000000000 of token 0x...
Token decimals: 6
Price: 100000000, Price decimals: 8
Withdrawal value in USD: 1000000000000000000000
Calling updateSubaccountAllowances for 0x... with balanceChange=1000000000000000000000
Successfully updated allowances for 0x.... TxHash: 0x...
```

## Security Considerations

1. **Function Selector Validation**: Only recognizes known withdrawal functions
2. **Token Whitelist**: Only processes tokens in configuration
3. **Price Feed Validation**: Uses trusted Chainlink oracles
4. **Gas Limits**: Configurable to prevent excessive costs
5. **Proxy Pattern**: Transactions go through authorized Chainlink proxy

## Future Improvements

1. **Morpho Integration**: Add vault token registry for Morpho support
2. **More Protocols**: Add Compound, Spark, Yearn, etc.
3. **Batch Processing**: Handle multiple withdrawals in one transaction
4. **Event Deduplication**: Handle blockchain reorganizations
5. **Metrics**: Add Prometheus metrics for monitoring
6. **Alerting**: Add webhooks for large withdrawals

## Comparison with TypeScript Version

| Feature | Go (this version) | TypeScript |
|---------|------------------|------------|
| EVM Log Trigger | ✅ Fully supported | ❌ Not available yet |
| Event-driven | ✅ Real-time | ❌ Would need polling |
| Production ready | ✅ Yes | ⚠️ Waiting for SDK |
| Deployment | ✅ Now | ⏳ Future |
| Type safety | ✅ Go + ABI | ✅ TypeScript + Viem |

## Support

For issues or questions:
- Chainlink CRE Documentation: https://docs.chain.link/cre
- Go SDK: https://github.com/smartcontractkit/chainlink
- This repo: File an issue

## License

MIT
