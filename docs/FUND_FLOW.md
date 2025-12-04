# RozoIntents Fund Flow

## Key Principle

Funds are **transient**, not stored. They move within seconds.

## Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         FUND FLOW                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  EVM (Base)                        Stellar                       │
│                                                                  │
│  1. User: createIntent()                                         │
│     └── Deposits to RozoBridge                                   │
│                                                                  │
│  2.                                Relayer pays receiver         │
│                                                                  │
│  3.                                Relayer calls fill()          │
│                                    └── Axelar sends message      │
│                                                                  │
│  4. Axelar delivers confirmation                                 │
│     └── RozoBridge.fillRelay()                                   │
│     └── Relayer gets paid (minus fee)                            │
│     └── Protocol fee to feeRecipient                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Fund Locations

```
User Wallet ──► RozoBridge ──► Relayer (on fillRelay)
                    │
                    └──► Protocol Fee ──► feeRecipient
```

## Refund

If intent expires (deadline passed), anyone can call `refund()`:

```
RozoBridge ──► refundAddress (full amount, no fee)
```

## Security

- Funds tracked by intentHash in RozoBridge
- Only Axelar Gateway can trigger fillRelay
- Deadline protection: users can always refund after expiry
