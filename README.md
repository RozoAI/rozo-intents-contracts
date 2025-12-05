# RozoIntents

Intent-based cross-chain payments. Base ↔ Stellar (bidirectional).

No custom validators. Axelar handles verification.

Architecture supports ERC-20/Soroban tokens. **Currently: USDC only.** Frontend calculates fees upfront.

> **New to RozoIntents?** Start with [GLOSSARY.md](./docs/design/GLOSSARY.md) to understand key terms.

## Flow

```
Sender ──► createIntent() ──► NEW
                               │
Relayer ──► fill() ───────────►│──► FILLING
                               │
Messenger ──► notify() ────────┴──► FILLED (relayer paid)
```

## Documentation

### Design

System architecture and protocol specifications.

| Document | Description |
|----------|-------------|
| [DESIGN.md](./docs/design/DESIGN.md) | Architecture, functions, status flow |
| [GLOSSARY.md](./docs/design/GLOSSARY.md) | Terms, chains, tokens, roles |
| [FUND_FLOW.md](./docs/design/FUND_FLOW.md) | Fund movement, fees, refunds |
| [DATA_STRUCTURES.md](./docs/design/DATA_STRUCTURES.md) | Intent struct, events, errors |
| [MESSENGER_DESIGN.md](./docs/design/MESSENGER_DESIGN.md) | Axelar integration |
| [SLOWFILLED.md](./docs/design/SLOWFILLED.md) | CCTP bridge fallback |
| [STELLAR.md](./docs/design/STELLAR.md) | Stellar address/token encoding, Soroban integration |

### Development

Implementation guides for developers.

| Document | Description |
|----------|-------------|
| [DEPLOYMENT.md](./docs/development/DEPLOYMENT.md) | Contract deployment & configuration |
| [TESTING.md](./docs/development/TESTING.md) | Test strategy & test cases |
| [RELAYER.md](./docs/development/RELAYER.md) | Relayer implementation guide |

## Quick Reference

### Status Flow
```
NEW → FILLING → FILLED
 │       │
 │       └──► FAILED (verification mismatch, admin recovery)
 │
 └──► REFUNDED (after deadline)
```

### Key Points

- **Fast Fill:** Relayer pays receiver, gets repaid via Axelar (~5-10 sec)
- **Slow Fill:** CCTP bridges directly to receiver (~1-60 min, EVM only)
- **Safety:** No fill = sender refunds after deadline, no fund loss
- **Admin:** Fee management, relayer whitelist, intent recovery
