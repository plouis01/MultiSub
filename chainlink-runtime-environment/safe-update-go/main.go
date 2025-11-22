//go:build wasip1

package main

import (
	"encoding/hex"
	"fmt"
	"log/slog"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
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
	Amount common.Address
	Token  common.Address
}

// ExecutionResult represents the workflow execution result
type ExecutionResult struct {
	Message string
	Success bool
}

// ABI definitions for common protocols
const (
	// Aave withdraw(address asset, uint256 amount, address to)
	AaveWithdrawSelector = "69328dec"

	// Morpho withdraw(uint256 assets, address receiver, address owner)
	MorphoWithdrawSelector = "b460af94"
)

// ERC20 ABI for decimals
const erc20ABI = `[{"constant":true,"inputs":[],"name":"decimals","outputs":[{"name":"","type":"uint8"}],"type":"function"}]`

// Chainlink Price Feed ABI
const priceFeedABI = `[{"constant":true,"inputs":[],"name":"latestRoundData","outputs":[{"name":"roundId","type":"uint80"},{"name":"answer","type":"int256"},{"name":"startedAt","type":"uint256"},{"name":"updatedAt","type":"uint256"},{"name":"answeredInRound","type":"uint80"}],"type":"function"},{"constant":true,"inputs":[],"name":"decimals","outputs":[{"name":"","type":"uint8"}],"type":"function"}]`

// DeFiInteractorModule ABI
const moduleABI = `[{"constant":false,"inputs":[{"name":"subAccount","type":"address"},{"name":"balanceChange","type":"uint256"}],"name":"updateSubaccountAllowances","outputs":[],"type":"function"}]`

// DecodeWithdrawalAmount decodes the withdrawal amount from protocol calldata
func DecodeWithdrawalAmount(logger *slog.Logger, txData []byte) (*big.Int, common.Address, error) {
	if len(txData) < 4 {
		return nil, common.Address{}, fmt.Errorf("transaction data too short")
	}

	// Get function selector (first 4 bytes)
	selector := hex.EncodeToString(txData[:4])
	logger.Info("Transaction selector", "selector", "0x"+selector)

	// Aave withdraw(address asset, uint256 amount, address to)
	if selector == AaveWithdrawSelector {
		logger.Info("Detected Aave withdraw function")

		if len(txData) < 100 {
			return nil, common.Address{}, fmt.Errorf("Aave withdraw data too short")
		}

		// Decode parameters: asset (32 bytes), amount (32 bytes), to (32 bytes)
		assetBytes := txData[16:36] // Skip padding, get address
		amountBytes := txData[36:68]

		asset := common.BytesToAddress(assetBytes)
		amount := new(big.Int).SetBytes(amountBytes)

		logger.Info("Aave withdrawal", "amount", amount.String(), "token", asset.Hex())

		return amount, asset, nil
	}

	// Morpho withdraw(uint256 assets, address receiver, address owner)
	if selector == MorphoWithdrawSelector {
		logger.Info("Detected Morpho withdraw function")
		return nil, common.Address{}, fmt.Errorf("Morpho vault token mapping not implemented")
	}

	logger.Info("Unknown function selector", "selector", "0x"+selector)
	return nil, common.Address{}, fmt.Errorf("not a recognized withdrawal function")
}

// ExtractProtocolCalldata extracts the nested protocol calldata from executeOnProtocol transaction
func ExtractProtocolCalldata(logger *slog.Logger, txData []byte) ([]byte, error) {
	if len(txData) < 132 {
		return nil, fmt.Errorf("transaction data too short for executeOnProtocol")
	}

	logger.Info("Full transaction data", "length", len(txData))

	// Skip selector (4) + address (32) + offset (32) = 68 bytes
	dataLengthOffset := 68
	dataLengthBytes := txData[dataLengthOffset : dataLengthOffset+32]
	dataLength := new(big.Int).SetBytes(dataLengthBytes).Uint64()

	logger.Info("Nested calldata", "length", dataLength)

	// Extract the nested calldata
	dataOffset := dataLengthOffset + 32
	if uint64(len(txData)) < uint64(dataOffset)+dataLength {
		return nil, fmt.Errorf("transaction data shorter than expected nested calldata")
	}

	protocolCalldata := txData[dataOffset : uint64(dataOffset)+dataLength]
	logger.Info("Extracted protocol calldata", "data", "0x"+hex.EncodeToString(protocolCalldata))

	return protocolCalldata, nil
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
func OnProtocolExecuted(config *Config, runtime cre.Runtime, payload *evm.Log) (*ExecutionResult, error) {
	logger := runtime.Logger()
	logger.Info("ProtocolExecuted event received")

	// Parse chain selector
	chainSelector := new(big.Int)
	chainSelector.SetString(config.ChainSelector, 10)

	// Create EVM client
	evmClient := &evm.Client{
		ChainSelector: chainSelector.Uint64(),
	}

	// Get event topics
	if len(payload.Topics) < 3 {
		return nil, fmt.Errorf("invalid event log format")
	}

	// Extract subAccount and target from indexed parameters
	subAccount := common.BytesToAddress(payload.Topics[1])
	target := common.BytesToAddress(payload.Topics[2])

	logger.Info("Processing transaction", "subAccount", subAccount.Hex(), "target", target.Hex())

	// Get transaction by hash to retrieve input data
	txHashBytes := payload.TxHash
	txHashReq := &evm.GetTransactionByHashRequest{
		Hash: txHashBytes,
	}

	txPromise := evmClient.GetTransactionByHash(runtime, txHashReq)
	tx, err := txPromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to get transaction: %w", err)
	}

	if len(tx.Transaction.Data) == 0 {
		return &ExecutionResult{Message: "No transaction data", Success: true}, nil
	}

	logger.Info("Transaction data", "length", len(tx.Transaction.Data))

	// Extract the nested protocol calldata
	protocolCalldata, err := ExtractProtocolCalldata(logger, tx.Transaction.Data)
	if err != nil {
		return nil, fmt.Errorf("failed to extract protocol calldata: %w", err)
	}

	// Try to decode withdrawal
	withdrawalAmount, withdrawalToken, err := DecodeWithdrawalAmount(logger, protocolCalldata)
	if err != nil {
		logger.Info("Not a recognized withdrawal", "error", err.Error())
		return &ExecutionResult{Message: "Not a withdrawal", Success: true}, nil
	}

	logger.Info("Detected withdrawal", "amount", withdrawalAmount.String(), "token", withdrawalToken.Hex())

	// Find token in config
	var tokenConfig *TokenConfig
	for i := range config.Tokens {
		if strings.EqualFold(config.Tokens[i].Address, withdrawalToken.Hex()) {
			tokenConfig = &config.Tokens[i]
			break
		}
	}

	if tokenConfig == nil {
		return nil, fmt.Errorf("token %s not in config", withdrawalToken.Hex())
	}

	// Get token decimals
	parsedERC20ABI, err := abi.JSON(strings.NewReader(erc20ABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse ERC20 ABI: %w", err)
	}

	decimalsCallData, err := parsedERC20ABI.Pack("decimals")
	if err != nil {
		return nil, fmt.Errorf("failed to pack decimals call: %w", err)
	}

	tokenAddr := common.HexToAddress(tokenConfig.Address)
	decimalsReq := &evm.CallContractRequest{
		Call: &evm.CallMsg{
			To:   tokenAddr.Bytes(),
			Data: decimalsCallData,
		},
	}

	decimalsPromise := evmClient.CallContract(runtime, decimalsReq)
	decimalsResult, err := decimalsPromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to get token decimals: %w", err)
	}

	var tokenDecimals uint8
	err = parsedERC20ABI.UnpackIntoInterface(&tokenDecimals, "decimals", decimalsResult.Data)
	if err != nil {
		return nil, fmt.Errorf("failed to unpack decimals: %w", err)
	}

	logger.Info("Token decimals", "decimals", tokenDecimals)

	// Get price from Chainlink
	parsedPriceFeedABI, err := abi.JSON(strings.NewReader(priceFeedABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse price feed ABI: %w", err)
	}

	latestRoundDataCallData, err := parsedPriceFeedABI.Pack("latestRoundData")
	if err != nil {
		return nil, fmt.Errorf("failed to pack latestRoundData call: %w", err)
	}

	priceFeedAddr := common.HexToAddress(tokenConfig.PriceFeedAddress)
	priceReq := &evm.CallContractRequest{
		Call: &evm.CallMsg{
			To:   priceFeedAddr.Bytes(),
			Data: latestRoundDataCallData,
		},
	}

	pricePromise := evmClient.CallContract(runtime, priceReq)
	priceResult, err := pricePromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to get price: %w", err)
	}

	var roundData struct {
		RoundId         *big.Int
		Answer          *big.Int
		StartedAt       *big.Int
		UpdatedAt       *big.Int
		AnsweredInRound *big.Int
	}

	err = parsedPriceFeedABI.UnpackIntoInterface(&roundData, "latestRoundData", priceResult.Data)
	if err != nil {
		return nil, fmt.Errorf("failed to unpack latestRoundData: %w", err)
	}

	// Get price decimals
	priceDecimalsCallData, err := parsedPriceFeedABI.Pack("decimals")
	if err != nil {
		return nil, fmt.Errorf("failed to pack decimals call: %w", err)
	}

	priceDecimalsReq := &evm.CallContractRequest{
		Call: &evm.CallMsg{
			To:   priceFeedAddr.Bytes(),
			Data: priceDecimalsCallData,
		},
	}

	priceDecimalsPromise := evmClient.CallContract(runtime, priceDecimalsReq)
	priceDecimalsResult, err := priceDecimalsPromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to get price decimals: %w", err)
	}

	var priceDecimals uint8
	err = parsedPriceFeedABI.UnpackIntoInterface(&priceDecimals, "decimals", priceDecimalsResult.Data)
	if err != nil {
		return nil, fmt.Errorf("failed to unpack price decimals: %w", err)
	}

	logger.Info("Price data", "price", roundData.Answer.String(), "decimals", priceDecimals)

	// Calculate USD value
	balanceChange := CalculateUSDValue(withdrawalAmount, tokenDecimals, roundData.Answer, priceDecimals)
	logger.Info("Withdrawal value in USD", "value", balanceChange.String())

	// Call updateSubaccountAllowances
	parsedModuleABI, err := abi.JSON(strings.NewReader(moduleABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse module ABI: %w", err)
	}

	callData, err := parsedModuleABI.Pack("updateSubaccountAllowances", subAccount, balanceChange)
	if err != nil {
		return nil, fmt.Errorf("failed to pack updateSubaccountAllowances call: %w", err)
	}

	logger.Info("Calling updateSubaccountAllowances", "subAccount", subAccount.Hex(), "balanceChange", balanceChange.String())

	// Create report for the transaction
	proxyAddr := common.HexToAddress(config.ProxyAddress)

	reportPromise := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: callData,
	})

	reportData, err := reportPromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to await report: %w", err)
	}

	// Submit transaction via WriteReport
	writeReq := &evm.WriteCreReportRequest{
		Receiver: proxyAddr.Bytes(),
		Report:   reportData,
		GasConfig: &evm.GasConfig{
			GasLimit: config.GasLimit,
		},
	}

	writePromise := evmClient.WriteReport(runtime, writeReq)
	writeResult, err := writePromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to send transaction: %w", err)
	}

	txHash := hex.EncodeToString(writeResult.TxHash)
	logger.Info("Successfully updated allowances", "subAccount", subAccount.Hex(), "txHash", "0x"+txHash)

	return &ExecutionResult{
		Message: fmt.Sprintf("Success: Updated allowances for %s, amount: %s, txHash: 0x%s",
			subAccount.Hex(), balanceChange.String(), txHash),
		Success: true,
	}, nil
}

// InitWorkflow initializes the workflow with EVM log trigger
func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	// Parse chain selector
	chainSelector := new(big.Int)
	chainSelector.SetString(config.ChainSelector, 10)

	// Create EVM log trigger for ProtocolExecuted events
	// ProtocolExecuted(address indexed subAccount, address indexed target, uint256 timestamp)
	eventSignature := crypto.Keccak256Hash([]byte("ProtocolExecuted(address,address,uint256)"))
	moduleAddr := common.HexToAddress(config.ModuleAddress)

	logTrigger := evm.LogTrigger(chainSelector.Uint64(), &evm.FilterLogTriggerRequest{
		Addresses: [][]byte{moduleAddr.Bytes()},
		Topics: []*evm.TopicValues{
			{Values: [][]byte{eventSignature.Bytes()}},
			{Values: [][]byte{}}, // subAccount (any)
			{Values: [][]byte{}}, // target (any)
			{Values: [][]byte{}}, // timestamp (not indexed, but we need 4 topic slots)
		},
	})

	return cre.Workflow[*Config]{
		cre.Handler(logTrigger, OnProtocolExecuted),
	}, nil
}

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
}
