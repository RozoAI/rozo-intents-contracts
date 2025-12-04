# RozoIntents Terminology

## Supported Chains (Live)

| Chain | Chain ID | Status |
|-------|----------|--------|
| Base | 8453 | Live |
| Stellar | 1500 | Live |

## Supported Tokens

- USDC
- USDT

## Core Terms

| Term | Description |
|------|-------------|
| **Source Chain** | Where user deposits (Base) |
| **Destination Chain** | Where receiver gets paid (Stellar) |
| **Sender** | User who initiates payment |
| **Receiver** | Recipient on destination chain |
| **Relayer** | Service that pays on destination, gets repaid on source |
| **Messenger** | Cross-chain verification (Axelar) |

## Intent Type

| Type | Description |
|------|-------------|
| **EXACT_IN** | Source amount fixed, receiver gets less after fees |
| **EXACT_OUT** | Destination amount fixed, sender pays more |

**Default:** EXACT_IN

## Intent Status

| Status | Description |
|--------|-------------|
| **NEW** | User deposited, waiting for relayer |
| **FILLED** | Messenger confirmed, relayer paid |
| **EXPIRED** | Deadline passed |
| **REFUNDED** | User refunded |

## Functions

| Function | Who Calls | Description |
|----------|-----------|-------------|
| `createIntent` | User | Deposit funds |
| `fillRelay` | Messenger | Confirm fill, pay relayer |
| `slowFillIntent` | User | Bridge via CCTP/Allbridge |
| `refund` | Anyone | Refund expired intent |
| `flush` | Anyone | Sweep extra funds |
