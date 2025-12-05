# RozoIntents Fund Flow & Fees

## Key Principle

Funds are **transient**, not stored. They move within seconds.

## Fast Fill Flow

```
Sender              Relayer              Destination Contract        Axelar
  │                    │                        │                       │
  │ createIntent()     │                        │                       │
  │ (deposit funds)    │                        │                       │
  ▼                    │                        │                       │
 NEW                   │                        │                       │
  │                    │                        │                       │
  │              fill()                         │                       │
  │              (claim intent)                 │                       │
  │                    ▼                        │                       │
  │                 FILLING                     │                       │
  │                    │                        │                       │
  │                    │   fillAndNotify() ────►│                       │
  │                    │                        │ transfer tokens       │
  │                    │                        │ relayer → receiver    │
  │                    │                        │                       │
  │                    │                        │ call Axelar ─────────►│
  │                    │                        │                       │
  │                    │                        │                notify()
  │                    │                        │                (confirms)
  │                    ▼                        │                       │
  │                 FILLED ◄────────────────────────────────────────────┘
  │              (relayer paid)
```

**Key:** Relayer calls `fillAndNotify()` on destination contract. Contract executes payment, then Axelar verifies the event.

## Slow Fill Flow

```
Sender                     Relayer/Bot                 CCTP
  │                          │                           │
  │ createIntent()           │                           │
  │ (deposit funds)          │                           │
  ▼                          │                           │
 NEW                         │                           │
  │                          │                           │
  │                    slowFill()                        │
  │                    (triggers bridge)                 │
  │                          │                           │
  │                    deduct fees                       │
  │                          │                           │
  │                    CCTP burn ────────────────────────►
  │                          │                           │
  ▼                          ▼                           │
FILLED                    (done)                         │
  │                                                      │
  │                                        ~1-60 min later
  │                                                      │
  │                                              CCTP mint
  │                                                      │
  │                                              receiver
  │                                              gets funds
```

**Key difference:** SlowFill goes directly from NEW → FILLED. No FILLING state.

## Fund Locations

```
Sender Wallet ──► RozoIntents ──┬──► Relayer (sourceAmount - protocolFee)
                               │
                               └──► Protocol Fee ──► feeRecipient
```

## Amount Model

Sender specifies both amounts when creating intent:

| Field | Description |
|-------|-------------|
| `sourceAmount` | Amount deposited (locked in contract) |
| `destinationAmount` | Minimum receiver expects |

**Fees calculated by frontend upfront.** Contract simply:
1. Locks `sourceAmount`
2. Verifies `amountPaid >= destinationAmount`
3. Releases `sourceAmount - protocolFee` to relayer
4. Accumulates `protocolFee` for admin withdrawal

## Example

```
Sender creates intent:
- sourceAmount: 1000 USDC (deposited on Base)
- destinationAmount: 995 USDC (minimum on Stellar)

Protocol fee: 3 bps = 0.3 USDC

Relayer fills:
- Pays receiver: 995 USDC (on Stellar)
- Receives: 999.7 USDC (1000 - 0.3 protocolFee) (on Base)
- Profit: 4.7 USDC (minus gas costs)
```

## Protocol Fee (Optional)

Protocol fee can be taken from the spread. Configured via admin:
- `setProtocolFee(uint256)` - max 30 bps
- `setFeeRecipient(address)`
- `withdrawFees(token)` - admin withdraws fees directly

---

## Fee Formula

### Fast Fill Formula

```
┌─────────────────────────────────────────────────────────────────┐
│  sourceAmount = destinationAmount + protocolFee + relayerSpread │
│                                                                 │
│  Where:                                                         │
│  - sourceAmount:      What sender deposits                      │
│  - destinationAmount: What receiver gets                        │
│  - protocolFee:       sourceAmount × protocolFeeBps / 10000     │
│  - relayerSpread:     Relayer's profit (difference)             │
└─────────────────────────────────────────────────────────────────┘
```

### Slow Fill Formula

```
┌─────────────────────────────────────────────────────────────────┐
│  sourceAmount = destinationAmount + protocolFee                 │
│                                                                 │
│  Where:                                                         │
│  - sourceAmount:      What sender deposits                      │
│  - destinationAmount: What receiver gets (bridged via CCTP)     │
│  - protocolFee:       sourceAmount - destinationAmount          │
│  - No relayer spread (SlowFill is a service, not arbitrage)     │
└─────────────────────────────────────────────────────────────────┘
```

### Relayer Payout Formula (Fast Fill)

```
relayerPayout = sourceAmount - protocolFee
```

Relayer pays `destinationAmount` on destination, receives `sourceAmount - protocolFee` on source.

---

## Cross-Chain Examples

### Example 1: Base → Stellar (USDC)

```
Chain Decimals:
- Base USDC:    6 decimals (1 USDC = 1_000000)
- Stellar USDC: 7 decimals (1 USDC = 10_000000)

User wants to send 100 USDC from Base to Stellar:

1. Frontend calculates:
   - sourceAmount:      100_000000      (100 USDC, 6 decimals on Base)
   - protocolFee:           30000       (0.03 USDC, 3 bps of 100)
   - relayerSpread:        470000       (0.47 USDC)
   - destinationAmount: 995_0000000     (99.5 USDC, 7 decimals on Stellar)
                        ^^^^^^^^^^^
                        Note: 7 zeros for Stellar!

2. User approves & calls createIntent():
   - Deposits: 100_000000   (Base USDC, 6 decimals)
   - Expects:  995_0000000  (Stellar USDC, 7 decimals)

3. Relayer fills:
   - Pays receiver: 995_0000000 (Stellar USDC, 7 decimals = 99.5 USDC)
   - Receives:       99_970000  (Base USDC, 6 decimals = 99.97 USDC)
   - Profit:         0.47 USDC (spread) minus gas costs
```

> **Decimal Conversion:** When converting amounts between chains:
> - Base → Stellar: multiply by 10 (add one zero)
> - Stellar → Base: divide by 10 (remove one zero)

### Example 2: Stellar → BNB Chain (USDC) - Future Support

> **Note:** BNB Chain support is planned for future release. This example demonstrates decimal handling across chains with different token decimals.

```
Chain Decimals:
- Stellar USDC: 7 decimals
- BNB USDC:     18 decimals

User wants to send 500 USDC from Stellar to BNB Chain:

1. Frontend calculates:
   - sourceAmount:     5000_000000              (500 USDC, 7 decimals)
   - protocolFee:      1500000                  (0.15 USDC, 3 bps)
   - relayerSpread:    23500000                 (2.35 USDC)
   - destinationAmount: 497_500000000000000000  (497.5 USDC, 18 decimals)

2. User approves & calls createIntent():
   - Deposits: 5000_000000 (Stellar USDC)
   - Expects:  497_500000000000000000 (BNB USDC)

3. Relayer fills:
   - Pays receiver: 497_500000000000000000 (BNB USDC, 18 decimals)
   - Receives:      4998_500000             (Stellar USDC, 7 decimals = 500 - 0.15 fee)
   - Profit:        2.35 USDC (spread) minus gas costs
```

### Decimal Conversion Reference

| Chain | USDC Decimals |
|-------|---------------|
| Base | 6 |
| Stellar | 7 |
| BNB Chain | 18 |
| Ethereum | 6 |
| Arbitrum | 6 |

**Important:** Contract does NOT convert decimals. Frontend must handle all decimal conversions when setting `sourceAmount` and `destinationAmount`.

---

## Token Decimals

Different chains use different decimals for the same token:

| Chain | USDC Decimals |
|-------|---------------|
| Base | 6 |
| Stellar | 7 |

### Decimal Handling

| Field | Decimals | Set By |
|-------|----------|--------|
| `sourceAmount` | Source chain decimals | Frontend |
| `destinationAmount` | Destination chain decimals | Frontend |

**Relayer responsibility:** Relayer must pay `>= destinationAmount` in destination chain decimals. Conversion is relayer's job.

```
Example: Send 100 USDC from Base to Stellar

Frontend sets:
- sourceAmount:      100_000000  (6 decimals, Base = 100 USDC)
- destinationAmount: 997_000000  (7 decimals, Stellar = 99.7 USDC)
                     ^^^^^^^^^^
                     7 digits after underscore

Relayer:
- Pays receiver: 997_0000000 (7 decimals on Stellar = 99.7 USDC)
- Receives: 100_000000 - protocolFee (6 decimals on Base)
- Profit: spread minus gas costs
```

Contract does NOT convert decimals. Frontend calculates both amounts. Relayer handles conversion.

## Supported Tokens

**Currently: Stablecoins only (USDC).** Native assets NOT supported.

| Chain | Supported | NOT Supported |
|-------|-----------|---------------|
| EVM (Base) | ERC-20 tokens | Native ETH |
| Stellar | Soroban tokens (SEP-41) | Native XLM |

**Why no native assets?**
- Contract uses `transferFrom()` to pull tokens
- Native assets require `msg.value` / different transfer mechanism
- Sender must `approve()` RozoIntents before calling `createIntent()`

See [GLOSSARY.md](./GLOSSARY.md) for full token support matrix.

## Refund

If intent expires (deadline passed), refund can be triggered:

```
NEW or FILLING ──► (deadline passes) ──► refund() ──► REFUNDED
```

- **No fee on refund** - full `sourceAmount` returned
- **No partial refund** - all or nothing
- **Who can call:** `sender` or `refundAddress` can trigger refund
- **Funds go to:** `refundAddress` (defaults to sender if not specified)
- **No EXPIRED status** - `refund()` sets status directly to REFUNDED

## Security

- Funds tracked by intentId
- Only Messenger can call `notify()`
- Deadline protection: sender can always refund
