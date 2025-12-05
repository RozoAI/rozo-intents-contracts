# RozoIntents

Intent-based cross-chain payments. Base ↔ Stellar (bidirectional).

No custom validators. Axelar handles verification.

Any token supported. Frontend calculates fees upfront.

## Flow

```
Sender ──► createIntent() ──► NEW
                               │
Relayer ──► fill() ───────────►│──► FILLING
                               │
Messenger ──► notify() ────────┴──► FILLED (relayer paid)
```

## Documentation

### [DESIGN.md](./docs/DESIGN.md)
Architecture, functions, status.
- **Status:** NEW → FILLING → FILLED (or REFUNDED after deadline)
- **Functions:** createIntent, fill, slowFill, notify, refund
- **Admin:** setFeeRecipient, setProtocolFee, addRelayer, removeRelayer

### [TERMINOLOGY.md](./docs/TERMINOLOGY.md)
Terms, chains, tokens.
- **Chains:** Base ↔ Stellar (bidirectional)
- **Tokens:** Any (USDC, USDT common)
- **Roles:** Sender, Receiver, Relayer, Messenger

### [FUND_FLOW.md](./docs/FUND_FLOW.md)
Fund movement & fees.
- **Amount model:** Sender specifies sourceAmount + destinationAmount
- **Fees:** Calculated by frontend upfront (in the spread)
- **Refund:** 100% back after deadline expires

### [RELAYER.md](./docs/RELAYER.md)
Relayer guide.
- **Phase 1:** Admin whitelist only
- **Race:** First-come-first-serve
- **Safety:** No fill = sender refunds, no fund loss

### [MESSENGER_DESIGN.md](./docs/MESSENGER_DESIGN.md)
Messenger integration & Axelar flow.
- **Function:** Axelar calls notify() on RozoIntents
- **Multi-chain:** mapping(chain → trustedContract)
- **Live:** Axelar (~5-10 sec)

### [SLOWFILLED.md](./docs/SLOWFILLED.md)
SlowFill bridge fallback details.
- **Bridge:** CCTP (EVM ↔ EVM only for now)
- **Status:** NEW → FILLED directly
- **Delivery:** CCTP mints directly to receiver (bypasses destination contract)
- **⚠️ No refund:** Once SlowFill succeeds, no refund via RozoIntents. If CCTP stalls, use `refundAddress` to claim from CCTP directly.

### [DATA_STRUCTURES.md](./docs/DATA_STRUCTURES.md)
Intent struct, parameters, events, errors.
- **Intent struct:** All fields with types
- **createIntent params:** Full parameter table
- **Events & errors:** Complete list
