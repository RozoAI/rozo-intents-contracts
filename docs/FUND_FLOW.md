# RozoIntents Fund Flow & Fees

## Key Principle

Funds are **transient**, not stored. They move within seconds.

## Flow

```
Sender                     Relayer                    Messenger
  │                          │                           │
  │ createIntent()           │                           │
  │ (deposit funds)          │                           │
  ▼                          │                           │
 NEW                         │                           │
  │                          │                           │
  │                    fill() / slowFill()               │
  │                    (pays on Stellar)                 │
  │                          ▼                           │
  │                       FILLING                        │
  │                          │                           │
  │                          │                    fillNotify()
  │                          │                    (Axelar confirms)
  │                          ▼                           │
  │                       FILLED ◄───────────────────────┘
  │                    (relayer paid)
```

## Fund Locations

```
Sender Wallet ──► RozoIntents ──► Relayer (on fillNotify)
                      │
                      └──► Protocol Fee ──► feeRecipient
```

## Protocol Fee

| Setting | Value |
|---------|-------|
| Default | 3 bps (0.03%) |

```
Example (3 bps):
- Sender deposits: 1000 USDC
- Protocol fee: 0.3 USDC → accumulated in contract
- Relayer receives: 999.7 USDC
```

Fees accumulate in contract. feeRecipient can withdraw anytime via `withdrawFees(token)`.

## Relayer Spread

```
Relayer receives: 999.7 USDC (on Base)
Relayer pays:     995 USDC (on Stellar)
Relayer profit:   4.7 USDC (minus gas costs)
```

## Token Decimals

Different chains use different decimals for the same token:

| Chain | USDC Decimals |
|-------|---------------|
| Base | 6 |
| Stellar | 7 |

**Important:** Amount uses source chain decimals.

```
Example: Send 100 USDC from Base to Stellar
- sourceAmount: 100_000000 (6 decimals on Base)
- Receiver gets: ~997_000000 (7 decimals on Stellar)
```

Contract does NOT convert decimals. Frontend handles conversion.

## Refund

If intent expires (deadline passed), anyone can call `refund()`:

```
NEW ──► (deadline) ──► EXPIRED ──► refund() ──► Sender gets 100%
```

- **No fee on refund** - sender gets full deposit back
- **No partial refund** - all or nothing
- **Anyone can trigger** - but funds go to refundAddress

## Security

- Funds tracked by intentId
- Only Messenger can call `fillNotify()`
- Deadline protection: sender can always refund
