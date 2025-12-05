# RozoIntents

Intent-based cross-chain payments. Base ↔ Stellar.

No custom validators. Axelar handles verification.

## Flow

```
Sender ──► createIntent() ──► NEW
                               │
Relayer ──► fill() ───────────►│──► FILLING
                               │
Messenger ──► fillNotify() ────┴──► FILLED (relayer paid)
```

## Documentation

### [DESIGN.md](./docs/DESIGN.md)
Architecture, functions, status.
- **Status:** NEW → FILLING → FILLED / EXPIRED → REFUNDED
- **Functions:** createIntent, fill, slowFill, fillNotify, refund
- **Admin:** setFeeRecipient, setProtocolFee, addRelayer, removeRelayer

### [TERMINOLOGY.md](./docs/TERMINOLOGY.md)
Terms, chains, tokens.
- **Live:** Base ↔ Stellar
- **Tokens:** USDC, USDT
- **Roles:** Sender, Receiver, Relayer, Messenger

### [FUND_FLOW.md](./docs/FUND_FLOW.md)
Fund movement & fees.
- **Fee:** 3 bps default, to feeRecipient on fillNotify
- **Decimals:** Base=6, Stellar=7. Contract doesn't convert
- **Refund:** 100% back, no fee, after deadline expires

### [RELAYER.md](./docs/RELAYER.md)
Relayer guide.
- **Phase 1:** Admin whitelist only
- **Bond:** Off-chain (legal agreement)
- **Safety:** No fill = sender refunds, no fund loss

### [MESSENGER_DESIGN.md](./docs/MESSENGER_DESIGN.md)
Messenger interface & implementations.
- **Interface:** IMessenger with fillNotify()
- **Multi-chain:** mapping(chain → trustedContract)
- **Live:** Axelar (~5-10 sec)
