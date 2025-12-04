# RozoIntents Terminology

This document defines the standard terminology used across RozoIntents contracts and APIs.

## Chain Terminology

| Term | Description | Example |
|------|-------------|---------|
| **Source Chain** | The blockchain where user deposits funds | Base (8453) |
| **Destination Chain** | The blockchain where receiver gets paid | Stellar (1500) |
| **Source Chain ID** | Numeric identifier of source chain | `8453` |
| **Destination Chain ID** | Numeric identifier of destination chain | `1500` |

**Supported Chains:**

| Chain | Chain ID |
|-------|----------|
| Ethereum | 1 |
| Optimism | 10 |
| BSC | 56 |
| Polygon | 137 |
| Base | 8453 |
| Arbitrum | 42161 |
| Solana | 900 | *(non-EVM)* |
| Stellar | 1500 | *(non-EVM)* |

## Token Terminology

| Term | Description | Example |
|------|-------------|---------|
| **Source Token** | Token deposited by sender on source chain | USDC on Base |
| **Destination Token** | Token received by receiver on destination chain | USDC on Stellar |
| **Token Symbol** | Human-readable token identifier | `USDC`, `USDT` |
| **Token Address** | Contract address of the token | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |

**Supported Tokens:**
- USDC
- USDT


## Amount Terminology

| Term | Description |
|------|-------------|
| **Source Amount** | Amount deposited on source chain |
| **Destination Amount** | Amount to be received on destination chain |
| **Fee** | Protocol/relayer fee deducted from transfer |

## Intent Type

| Type | Description | Who pays fee? |
|------|-------------|---------------|
| **EXACT_IN** | Source amount is fixed, destination amount = source - fee | Receiver (gets less) |
| **EXACT_OUT** | Destination amount is fixed, source amount = destination + fee | Sender (pays more) |

**Default:** `EXACT_IN`

**Naming Convention:**
| Context | Format | Example |
|---------|--------|---------|
| Solidity Contract | UPPER_SNAKE_CASE enum | `IntentType.EXACT_IN` |

### exactIn Example
```
User wants to send 100 USDC
Fee: 0.03% = 0.03 USDC

Source Amount:      100 USDC (fixed, user deposits this)
Fee:                0.03 USDC
Destination Amount: 99.97 USDC (receiver gets this)
```

### exactOut Example
```
User wants receiver to get exactly 100 USDC
Fee: 0.03%

Destination Amount: 100 USDC (fixed, receiver gets this)
Fee:                0.03 USDC
Source Amount:      100.03 USDC (user must deposit this)
```

## Address Terminology

| Term | Description | Format |
|------|-------------|--------|
| **Sender Address** | User's wallet address on source chain | `0x...` (EVM) |
| **Receiver Address** | Recipient's wallet address on destination chain | `0x...` or `G...` (Stellar) |
| **Refund Address** | Where to return funds if intent fails/expires | `0x...` (EVM) |
| **Receiver Memo** | Optional memo for Stellar/Solana destinations | String |

## Intent Status

| Status | Description |
|--------|-------------|
| **NEW** | User deposited, waiting for relayer |
| **PROCESSING** | Relayer locked intent (multi-relayer mode) |
| **PROCESSED** | Fulfilled and claimed by relayer |
| **EXPIRED** | Deadline passed without fulfillment |
| **REFUNDED** | User received refund |


## Participant Terminology

| Term | Description |
|------|-------------|
| **Sender** | User who initiates the payment |
| **Receiver** | Recipient who gets paid on destination chain |
| **Relayer** | Service that fulfills intents (bridges funds) |
| **Validator** | Service that verifies destination payments |
| **Primary Validator** | Main validator (must sign all fulfillments) |
| **Secondary Validator** | Backup validators (any one can co-sign) |

## Contract vs API Field Mapping

### RozoIntent Struct (Intent Definition)

| Contract Field | API Field | Notes |
|----------------|-----------|-------|
| `destinationChainId` | `destination.chainId` | Numeric chain ID |
| `receiver` | `destination.receiverAddress` | bytes32 for cross-chain compatibility |
| `destinationToken` | `destination.tokenAddress` | bytes32 for non-EVM chains |
| `amount` | `source.amount` or `destination.amount` | Depends on intentType (see below) |
| `intentType` | `type` | EXACT_IN or EXACT_OUT |
| `refundAddress` | (optional, defaults to sender) | User can specify custom refund address |
| `nonce` | `orderId` | Unique identifier |
| `deadline` | (calculated) | Default 24h from creation |

**Amount field by intentType:**
- `EXACT_IN`: `amount` = `source.amount` (in source token decimals)
- `EXACT_OUT`: `amount` = `destination.amount` (in destination token decimals)

### IntentStorage (On-chain, After Deposit)

These fields are NOT in RozoIntent - they are stored separately after deposit:

| Storage Field | Source | Notes |
|---------------|--------|-------|
| `sender` | msg.sender or derived | Who deposited (unknown until deposit) |
| `sourceToken` | Function parameter | What token was deposited (user can send any token) |
| `sourceAmount` | Actual balance | How much was deposited |
| `refundAddress` | Copied from RozoIntent | For refund lookup |
| `deadline` | Copied from RozoIntent | For expiry check |
| `processor` | Relayer address | Who fulfilled (v2: who locked) |
| `fulfillmentTxHash` | Validator signed | Destination transaction hash |
