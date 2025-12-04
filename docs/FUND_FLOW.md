# RozoIntents Fund Flow

This document describes how funds move through the system for different user types.

## Key Principle

Funds are **transient**, not stored. They should move within seconds:
- Deposit → Fulfill → Claim (typically < 30 seconds)
- This is NOT a liquidity pool or vault

## Two User Types

| User Type | Deposit Method | Intent Address | Relayer Mode |
|-----------|---------------|----------------|--------------|
| **API User** | Transfer to CREATE2 address | Yes (isolated) | Single (Rozo) |
| **Contract User** | Permit2 / Approve | No (direct to main contract) | Multiple (v2) |

## Flow 1: API User (Recommended)

User interacts via Rozo API. Funds are isolated in intent address until relayer claims (atomic pull + fulfill).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           API USER FLOW                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. User calls Rozo API to create payment                                   │
│     POST /create-payment                                                    │
│                                                                             │
│  2. API returns unique intent address (CREATE2)                             │
│     { "intentAddress": "0x7a3b...f2c1" }                                    │
│                                                                             │
│  3. User transfers tokens to intent address                                 │
│     User Wallet ──────► Intent Address (0x7a3b...f2c1)                      │
│                         [Funds ISOLATED here until relayer claims]          │
│                                                                             │
│  4. Relayer detects deposit, pays receiver on destination                   │
│     Relayer ──────────► Receiver (Stellar)                                  │
│                                                                             │
│  5. Validators verify destination payment, sign proof                       │
│                                                                             │
│  6. Relayer calls startIntent() + fulfillIntent() in one tx                 │
│     - startIntent(): deploys intent contract, pulls funds                   │
│     - fulfillIntent(): validates signatures, transfers to relayer           │
│     Intent Address ──► Main Contract ──► Relayer (atomic)                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Characteristics:**
- Funds isolated in intent address until relayer claims
- Relayer calls startIntent() + fulfillIntent() atomically
- Single relayer (Rozo) - no competition
- Simple UX: just transfer to address
- CREATE2 address is deterministic (can be pre-computed)

## Flow 2: Contract User (Direct Interaction)

User interacts directly with contract (e.g., dApp integration). Multiple relayers can compete in v2.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CONTRACT USER FLOW                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. User approves token to main contract (or uses Permit2)                  │
│                                                                             │
│  2. User calls createIntent() on main contract                              │
│     - Contract pulls sourceAmount from user                                 │
│     - Funds go directly to main contract                                    │
│     User Wallet ──────► Main Contract                                       │
│                         [Funds tracked by intentHash]                       │
│                                                                             │
│  3. (v2) Multiple relayers see the intent, compete to fulfill               │
│     - Relayer calls processRequest() to lock intent (optional)              │
│                                                                             │
│  4. Relayer pays receiver on destination                                    │
│     Relayer ──────────► Receiver (Stellar)                                  │
│                                                                             │
│  5. Validators verify destination payment, sign proof                       │
│                                                                             │
│  6. Relayer calls fulfillIntent() with signatures                           │
│     - Main contract transfers to relayer (minus fee)                        │
│     Main Contract ──────► Relayer                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Characteristics:**
- Funds pooled in main contract (tracked by mapping)
- Multiple relayers can compete (v2)
- Lower gas (no intent contract deployment)
- Requires contract interaction (Permit2 or approve)

## Fund Location Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         FUND LOCATIONS                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  API User (Transfer to CREATE2):                                            │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐                │
│  │ User Wallet  │ ──► │Intent Address│ ──► │Main Contract │ ──► Relayer    │
│  └──────────────┘     └──────────────┘     └──────────────┘                │
│                       (isolated until       (atomic with                    │
│                        relayer claims)       fulfillment)                   │
│                                                                             │
│  Contract User (Permit2/Approve via createIntent):                          │
│  ┌──────────────┐     ┌──────────────┐                                     │
│  │ User Wallet  │ ──► │Main Contract │ ──────────────────────► Relayer     │
│  └──────────────┘     └──────────────┘                                     │
│                        (tracked by intentHash)                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key Difference:**
- **API User**: Funds isolated in intent address until relayer atomically pulls + claims
- **Contract User**: Funds in main contract immediately, tracked by intentHash

## Pooled Funds

For contract users, funds are pooled in main contract:

1. **Short duration** - Funds move in seconds, not stored
2. **Tracked by intentHash** - Each intent's funds are accounted
3. **No mixing risk** - Relayer can only claim what validators signed for
4. **Not a liquidity pool** - No yield, no sharing, just pass-through

## Refund Scenarios

| Scenario | API User | Contract User |
|----------|----------|---------------|
| Intent expires | Funds in intent address → refundAddress | Funds in main contract → refundAddress |
| Relayer fails | Same as expired | Same as expired |
| Double deposit | Excess stays in intent address (can refund) | Excess tracked, can refund |

## Version Comparison

| Aspect | v1 (Single Relayer) | v2 (Multiple Relayers) |
|--------|---------------------|------------------------|
| API Users | Rozo relayer only | Rozo relayer only |
| Contract Users | Rozo relayer only | Open competition |
| processRequest() | Not used | Used to lock intent |
| Intent locking | Not needed | Prevents double-fulfill |
| Design Purpose | Easy to use in consumer products | Use in smart contracts |

## Security Notes

1. **Intent Address Isolation**: API users have fully isolated funds per intent
2. **Main Contract Tracking**: Contract users have funds tracked by intentHash mapping
3. **Validator Signatures**: Relayer can only claim after validators confirm destination payment
4. **Deadline Protection**: Users can always refund after deadline passes
5. **No Custodial Risk**: Funds flow through, not stored long-term
