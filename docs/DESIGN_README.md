# RozoIntents

Intent-based cross-chain payments. Base ↔ Stellar (bidirectional).

**Multiple messenger options.** Rozo messenger (default, ~1-3 sec) or Axelar (~5-10 sec). Users receive funds instantly; messenger choice only affects relayer repayment speed.

Architecture supports ERC-20/Soroban tokens. **Currently: USDC only.** Frontend calculates fees upfront.

> **New to RozoIntents?** Start with [GLOSSARY.md](./docs/design/GLOSSARY.md) to understand key terms.

## Flow

```
Source Chain                     Destination Chain
     │                                  │
Sender ──► createIntent() ──► PENDING   │
     │                           │      │
     │                           │   Relayer ──► fillAndNotify()
     │                           │      │        (pays receiver instantly)
     │                           │      │
     │◄──────── Messenger ───────┴──────┘
     │
FILLED (relayer repaid)
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
| [MESSENGER_DESIGN.md](./docs/design/MESSENGER_DESIGN.md) | Messenger adapters (Rozo, Axelar) |
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
PENDING ──► FILLED (via notify)
    │
    ├──► FAILED (verification mismatch, admin recovery)
    │
    └──► REFUNDED (after deadline)
```

### Key Points

- **Instant for users:** Relayer pays receiver immediately on destination chain
- **Messenger options:** Rozo (~1-3 sec) or Axelar (~5-10 sec) for relayer repayment
- **Safety:** No fill = sender refunds after deadline, no fund loss
- **Admin:** Fee management, relayer whitelist, intent recovery
