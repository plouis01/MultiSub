package main

import (
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/smartcontractkit/chainlink-common/pkg/capabilities/triggers"
	"github.com/smartcontractkit/chainlink/v2/core/capabilities/evmlogger"
	"github.com/smartcontractkit/chainlink/v2/core/scripts/chaincli/config"
	"github.com/smartcontractkit/chainlink/v2/core/scripts/chaincli/handler"
)

// Config represents the workflow configuration
type Config struct {
	ModuleAddress   string        `json:"moduleAddress"`
	ChainSelector   string        `json:"chainSelector"`
	GasLimit        uint64        `json:"gasLimit"`
	ProxyAddress    string        `json:"proxyAddress"`
	Tokens          []TokenConfig `json:"tokens"`
}

// TokenConfig represents a token configuration
type TokenConfig struct {
	Address          string `json:"address"`
	PriceFeedAddress string `json:"priceFeedAddress"`
	Symbol           string `json:"symbol"`
	Type             string `json:"type"`
}

// WithdrawalData represents decoded withdrawal information
type WithdrawalData struct {
	Amount *big.Int
	Token  common.Address
}

// ABI definitions for common protocols
const (
	// Aave withdraw(address asset, uint256 amount, address to)
	AaveWithdrawSelector = "0x69328dec"

	// Morpho withdraw(uint256 assets, address receiver, address owner)
	MorphoWithdrawSelector = "0xb460af94"

	// Morpho redeem(uint256 shares, address receiver, address owner)
	MorphoRedeemSelector = "0xba087652"
)

// ERC20 ABI for decimals and balance queries
var erc20ABI = `[
	{
		"constant": true,
		"inputs": [],
		"name": "decimals",
		"outputs": [{"name": "", "type": "uint8"}],
		"type": "function"
	},
	{
		"constant": true,
		"inputs": [{"name": "account", "type": "address"}],
		"name": "balanceOf",
		"outputs": [{"name": "", "type": "uint256"}],
		"type": "function"
	}
]`

// Chainlink Price Feed ABI
var priceFeedABI = `[
	{
		"constant": true,
		"inputs": [],
		"name": "latestRoundData",
		"outputs": [
			{"name": "roundId", "type": "uint80"},
			{"name": "answer", "type": "int256"},
			{"name": "startedAt", "type": "uint256"},
			{"name": "updatedAt", "type": "uint256"},
			{"name": "answeredInRound", "type": "uint80"}
		],
		"type": "function"
	},
	{
		"constant": true,
		"inputs": [],
		"name": "decimals",
		"outputs": [{"name": "", "type": "uint8"}],
		"type": "function"
	}
]`

// DeFiInteractorModule ABI
var moduleABI = `[
	{
		"constant": false,
		"inputs": [
			{"name": "subAccount", "type": "address"},
			{"name": "balanceChange", "type": "uint256"}
		],
		"name": "updateSubaccountAllowances",
		"outputs": [],
		"type": "function"
	},
	{
		"constant": true,
		"inputs": [],
		"name": "avatar",
		"outputs": [{"name": "", "type": "address"}],
		"type": "function"
	}
]`

// DecodeWithdrawalAmount decodes the withdrawal amount from protocol calldata
func DecodeWithdrawalAmount(runtime handler.Runtime, txData []byte) (*WithdrawalData, error) {
	if len(txData) < 4 {
		return nil, fmt.Errorf("transaction data too short")
	}

	// Get function selector (first 4 bytes)
	selector := hex.EncodeToString(txData[:4])
	runtime.Log(fmt.Sprintf("Transaction selector: 0x%s", selector))

	// Aave withdraw(address asset, uint256 amount, address to)
	if selector == AaveWithdrawSelector[2:] {
		runtime.Log("Detected Aave withdraw function")

		if len(txData) < 100 {
			return nil, fmt.Errorf("Aave withdraw data too short")
		}

		// Decode parameters
		// Skip selector (4 bytes), then we have:
		// - asset (32 bytes, address padded)
		// - amount (32 bytes, uint256)
		// - to (32 bytes, address padded)

		assetBytes := txData[16:36]  // Skip padding, get address
		amountBytes := txData[36:68]

		asset := common.BytesToAddress(assetBytes)
		amount := new(big.Int).SetBytes(amountBytes)

		runtime.Log(fmt.Sprintf("Aave withdrawal: %s of token %s", amount.String(), asset.Hex()))

		return &WithdrawalData{
			Amount: amount,
			Token:  asset,
		}, nil
	}

	// Morpho withdraw(uint256 assets, address receiver, address owner)
	if selector == MorphoWithdrawSelector[2:] {
		runtime.Log("Detected Morpho withdraw function")

		if len(txData) < 68 {
			return nil, fmt.Errorf("Morpho withdraw data too short")
		}

		// First parameter is assets (uint256)
		amountBytes := txData[4:36]
		amount := new(big.Int).SetBytes(amountBytes)

		runtime.Log(fmt.Sprintf("Morpho withdrawal: %s", amount.String()))

		// TODO: Need vault token mapping to determine which token
		return nil, fmt.Errorf("Morpho vault token mapping not implemented")
	}

	runtime.Log(fmt.Sprintf("Unknown function selector: 0x%s", selector))
	return nil, fmt.Errorf("not a recognized withdrawal function")
}

// ExtractProtocolCalldata extracts the nested protocol calldata from executeOnProtocol transaction
func ExtractProtocolCalldata(runtime handler.Runtime, txData []byte) ([]byte, error) {
	// executeOnProtocol(address target, bytes data)
	// Selector: 4 bytes
	// target: 32 bytes (address padded)
	// bytes offset: 32 bytes
	// bytes length: 32 bytes
	// bytes data: variable length

	if len(txData) < 132 {
		return nil, fmt.Errorf("transaction data too short for executeOnProtocol")
	}

	runtime.Log(fmt.Sprintf("Full transaction data length: %d", len(txData)))

	// Skip selector (4) + address (32) + offset (32) = 68 bytes
	dataLengthOffset := 68
	dataLengthBytes := txData[dataLengthOffset : dataLengthOffset+32]
	dataLength := new(big.Int).SetBytes(dataLengthBytes).Uint64()

	runtime.Log(fmt.Sprintf("Nested calldata length: %d", dataLength))

	// Extract the nested calldata
	dataOffset := dataLengthOffset + 32
	if uint64(len(txData)) < uint64(dataOffset)+dataLength {
		return nil, fmt.Errorf("transaction data shorter than expected nested calldata")
	}

	protocolCalldata := txData[dataOffset : uint64(dataOffset)+dataLength]

	runtime.Log(fmt.Sprintf("Extracted protocol calldata: 0x%s", hex.EncodeToString(protocolCalldata)))

	return protocolCalldata, nil
}

// GetTokenDecimals gets the decimals for a token
func GetTokenDecimals(runtime handler.Runtime, evmClient handler.EVMClient, tokenAddress common.Address) (uint8, error) {
	parsedABI, err := abi.JSON(strings.NewReader(erc20ABI))
	if err != nil {
		return 0, fmt.Errorf("failed to parse ERC20 ABI: %w", err)
	}

	callData, err := parsedABI.Pack("decimals")
	if err != nil {
		return 0, fmt.Errorf("failed to pack decimals call: %w", err)
	}

	result, err := evmClient.CallContract(runtime, tokenAddress, callData)
	if err != nil {
		return 0, fmt.Errorf("failed to call decimals: %w", err)
	}

	var decimals uint8
	err = parsedABI.UnpackIntoInterface(&decimals, "decimals", result)
	if err != nil {
		return 0, fmt.Errorf("failed to unpack decimals: %w", err)
	}

	return decimals, nil
}

// GetPriceFromFeed gets the price and decimals from a Chainlink price feed
func GetPriceFromFeed(runtime handler.Runtime, evmClient handler.EVMClient, priceFeedAddress common.Address) (*big.Int, uint8, error) {
	parsedABI, err := abi.JSON(strings.NewReader(priceFeedABI))
	if err != nil {
		return nil, 0, fmt.Errorf("failed to parse price feed ABI: %w", err)
	}

	// Get latest round data
	callData, err := parsedABI.Pack("latestRoundData")
	if err != nil {
		return nil, 0, fmt.Errorf("failed to pack latestRoundData call: %w", err)
	}

	result, err := evmClient.CallContract(runtime, priceFeedAddress, callData)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to call latestRoundData: %w", err)
	}

	var roundData struct {
		RoundId         *big.Int
		Answer          *big.Int
		StartedAt       *big.Int
		UpdatedAt       *big.Int
		AnsweredInRound *big.Int
	}

	err = parsedABI.UnpackIntoInterface(&roundData, "latestRoundData", result)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to unpack latestRoundData: %w", err)
	}

	// Get decimals
	decimalsCallData, err := parsedABI.Pack("decimals")
	if err != nil {
		return nil, 0, fmt.Errorf("failed to pack decimals call: %w", err)
	}

	decimalsResult, err := evmClient.CallContract(runtime, priceFeedAddress, decimalsCallData)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to call decimals: %w", err)
	}

	var decimals uint8
	err = parsedABI.UnpackIntoInterface(&decimals, "decimals", decimalsResult)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to unpack decimals: %w", err)
	}

	return roundData.Answer, decimals, nil
}

// CalculateUSDValue converts a token amount to USD value with 18 decimals
func CalculateUSDValue(amount *big.Int, tokenDecimals uint8, price *big.Int, priceDecimals uint8) *big.Int {
	// Formula: (amount * price * 10^18) / (10^tokenDecimals * 10^priceDecimals)

	result := new(big.Int).Mul(amount, price)
	result.Mul(result, big.NewInt(1e18))

	divisor := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(tokenDecimals+priceDecimals)), nil)
	result.Div(result, divisor)

	return result
}

// OnProtocolExecuted is the handler for ProtocolExecuted events
func OnProtocolExecuted(runtime handler.Runtime, payload triggers.TriggerEvent) (string, error) {
	runtime.Log("ProtocolExecuted event received")

	// Get event log
	log := payload.Log
	tx := payload.Transaction

	if len(log.Topics) < 3 {
		return "", fmt.Errorf("invalid event log format")
	}

	// Extract subAccount and target from indexed parameters
	subAccount := common.BytesToAddress(log.Topics[1].Bytes())
	target := common.BytesToAddress(log.Topics[2].Bytes())

	runtime.Log(fmt.Sprintf("Processing transaction for subAccount=%s, target=%s", subAccount.Hex(), target.Hex()))

	// Get transaction data
	if tx.Data == nil || len(tx.Data) == 0 {
		return "No transaction data", nil
	}

	runtime.Log(fmt.Sprintf("Transaction data length: %d", len(tx.Data)))

	// Extract the nested protocol calldata
	protocolCalldata, err := ExtractProtocolCalldata(runtime, tx.Data)
	if err != nil {
		return "", fmt.Errorf("failed to extract protocol calldata: %w", err)
	}

	// Try to decode withdrawal
	withdrawal, err := DecodeWithdrawalAmount(runtime, protocolCalldata)
	if err != nil {
		runtime.Log(fmt.Sprintf("Not a recognized withdrawal: %v", err))
		return "Not a withdrawal", nil
	}

	runtime.Log(fmt.Sprintf("Detected withdrawal: %s of token %s", withdrawal.Amount.String(), withdrawal.Token.Hex()))

	// Get config
	cfg := runtime.Config().(Config)

	// Find token in config
	var tokenConfig *TokenConfig
	for _, t := range cfg.Tokens {
		if strings.EqualFold(t.Address, withdrawal.Token.Hex()) {
			tokenConfig = &t
			break
		}
	}

	if tokenConfig == nil {
		return "", fmt.Errorf("token %s not in config", withdrawal.Token.Hex())
	}

	// Get EVM client
	evmClient := runtime.EVMClient()

	// Get token decimals
	tokenDecimals, err := GetTokenDecimals(runtime, evmClient, withdrawal.Token)
	if err != nil {
		return "", fmt.Errorf("failed to get token decimals: %w", err)
	}

	runtime.Log(fmt.Sprintf("Token decimals: %d", tokenDecimals))

	// Get price from Chainlink
	priceFeedAddr := common.HexToAddress(tokenConfig.PriceFeedAddress)
	price, priceDecimals, err := GetPriceFromFeed(runtime, evmClient, priceFeedAddr)
	if err != nil {
		return "", fmt.Errorf("failed to get price: %w", err)
	}

	runtime.Log(fmt.Sprintf("Price: %s, Price decimals: %d", price.String(), priceDecimals))

	// Calculate USD value
	balanceChange := CalculateUSDValue(withdrawal.Amount, tokenDecimals, price, priceDecimals)

	runtime.Log(fmt.Sprintf("Withdrawal value in USD: %s", balanceChange.String()))

	// Call updateSubaccountAllowances
	parsedABI, err := abi.JSON(strings.NewReader(moduleABI))
	if err != nil {
		return "", fmt.Errorf("failed to parse module ABI: %w", err)
	}

	callData, err := parsedABI.Pack("updateSubaccountAllowances", subAccount, balanceChange)
	if err != nil {
		return "", fmt.Errorf("failed to pack updateSubaccountAllowances call: %w", err)
	}

	runtime.Log(fmt.Sprintf("Calling updateSubaccountAllowances for %s with balanceChange=%s", subAccount.Hex(), balanceChange.String()))

	// Submit transaction via runtime report
	moduleAddr := common.HexToAddress(cfg.ModuleAddress)
	proxyAddr := common.HexToAddress(cfg.ProxyAddress)

	txHash, err := evmClient.SendTransaction(runtime, proxyAddr, moduleAddr, callData, cfg.GasLimit)
	if err != nil {
		return "", fmt.Errorf("failed to send transaction: %w", err)
	}

	runtime.Log(fmt.Sprintf("Successfully updated allowances for %s. TxHash: %s", subAccount.Hex(), txHash.Hex()))

	return fmt.Sprintf("Success: Updated allowances for %s, amount: %s", subAccount.Hex(), balanceChange.String()), nil
}

// InitWorkflow initializes the workflow with EVM log trigger
func InitWorkflow(cfg Config) ([]handler.Handler, error) {
	// Create EVM log trigger for ProtocolExecuted events
	// ProtocolExecuted(address indexed subAccount, address indexed target, uint256 timestamp)
	eventSignature := crypto.Keccak256Hash([]byte("ProtocolExecuted(address,address,uint256)"))

	logTrigger := evmlogger.NewEVMLogTrigger(evmlogger.Config{
		ChainSelector: cfg.ChainSelector,
		Addresses:     []common.Address{common.HexToAddress(cfg.ModuleAddress)},
		Topics:        []common.Hash{eventSignature},
	})

	return []handler.Handler{
		handler.NewHandler(logTrigger, OnProtocolExecuted),
	}, nil
}

func main() {
	// This would be called by the Chainlink CRE runtime
	// The actual runner setup is handled by the Chainlink framework
	fmt.Println("Safe Update Go Workflow - use Chainlink CRE to run this workflow")
}
