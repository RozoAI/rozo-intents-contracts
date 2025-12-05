# RozoIntents Terminology

## Supported Chains (Bidirectional)

| Chain | Chain ID | 
|-------|----------|
| Base | 8453 |
| Stellar | 1500 |

Both chains can be source or destination. Flows work in both directions.

## Supported Tokens

**Any token allowed.** Common tokens:
- USDC
- USDT

Note: Obscure tokens may not be filled by relayers.

## Core Terms

| Term | Description |
|------|-------------|
| **Source Chain** | Where sender deposits |
| **Destination Chain** | Where receiver gets paid |
| **Sender** | User who initiates payment |
| **Receiver** | Recipient on destination chain |
| **Relayer** | Service that pays on destination, gets repaid on source (aka Solver/Filler) |
| **Messenger** | Cross-chain verification (Axelar) |

## Amount Terms

| Term | Description |
|------|-------------|
| **sourceAmount** | Amount sender deposits (locked in contract) |
| **destinationAmount** | Minimum amount receiver expects (set by sender with slippage) |

Frontend calculates fees/slippage upfront. Sender specifies both amounts when creating intent.

## Intent Status

| Status | Description |
|--------|-------------|
| **NEW** | Sender deposited, waiting for fill |
| **FILLING** | Relayer called `fill()`, awaiting messenger confirmation |
| **FILLED** | Fill completed (via `notify()` or `slowFill()`) |
| **REFUNDED** | Sender refunded |

## Functions

| Function | Caller | Description |
|----------|--------|-------------|
| `createIntent()` | Sender | Deposit funds |
| `fill()` | Relayer | Mark as FILLING (fast path, awaits notify) |
| `slowFill()` | Relayer | Bridge via CCTP → FILLED directly |
| `notify()` | Messenger only | Confirm fast fill → FILLED, pay relayer |
| `refund()` | Sender | Refund expired intent |

## Fill Modes

| Mode | Status Flow | Relayer Profit |
|------|-------------|----------------|
| **Fast Fill** | NEW → FILLING → FILLED | Yes (spread) |
| **Slow Fill** | NEW → FILLED | No (service only) |
