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
| **Source Chain** | Where sender deposits (Base) |
| **Destination Chain** | Where receiver gets paid (Stellar) |
| **Sender** | User who initiates payment |
| **Receiver** | Recipient on destination chain |
| **Relayer** | Service that pays on destination, gets repaid on source (aka Solver/Filler) |
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
| **NEW** | Sender deposited, waiting for relayer |
| **FILLING** | Relayer called fill()/slowFill(), processing |
| **FILLED** | Messenger called fillNotify(), relayer paid |
| **EXPIRED** | Deadline passed |
| **REFUNDED** | Sender refunded |

## Functions

| Function | Caller | Description |
|----------|--------|-------------|
| `createIntent()` | Sender | Deposit funds |
| `fill()` | Relayer | Mark as FILLING (fast path) |
| `slowFill()` | Relayer | Mark as FILLING (slow bridge path) |
| `fillNotify()` | Messenger only | Confirm → FILLED, pay relayer |
| `refund()` | Anyone | Refund expired intent |
