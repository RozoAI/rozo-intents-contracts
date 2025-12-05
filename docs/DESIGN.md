# RozoIntents Design

Intent-based cross-chain payments. Base ↔ Stellar.

**No custom validators.** Axelar messenger handles verification.

---

## Intent Status

| Status | Description |
|--------|-------------|
| NEW | Sender deposited, waiting for relayer |
| FILLING | Relayer called fill()/slowFill(), processing |
| FILLED | Messenger called fillNotify(), relayer paid |
| EXPIRED | Deadline passed |
| REFUNDED | Sender refunded |

---

## Functions

| Function | Caller | Description |
|----------|--------|-------------|
| `createIntent()` | Sender | Deposit sourceAmount, specify destinationAmount |
| `fill()` | Relayer | Mark as FILLING (fast path) |
| `slowFill()` | Relayer | Mark as FILLING (slow bridge path) |
| `fillNotify()` | Messenger only | Confirm fill → FILLED, pay relayer |
| `refund()` | Anyone | Refund expired intent |

---

## Flow

```
                    Sender                     Relayer                    Messenger
                      │                          │                           │
  createIntent() ─────┼──► NEW                   │                           │
                      │                          │                           │
                      │     fill() / slowFill() ─┼──► FILLING                │
                      │                          │                           │
                      │                          │      fillNotify() ────────┼──► FILLED
                      │                          │      (relayer paid)       │
```

---

## Admin (Minimal)

```solidity
setFeeRecipient(address)
setProtocolFee(uint256)   // max 30 bps
addRelayer(address)
removeRelayer(address)
```

---

## Fast vs Slow Fill

| Mode | Function | Speed | How |
|------|----------|-------|-----|
| Fast | `fill()` | ~5-10 seconds | Relayer pays, Axelar confirms |
| Slow | `slowFill()` | ~2-60 min | Bridge via CCTP/Allbridge |

Both set status to FILLING. Messenger's `fillNotify()` completes the fill.

---

## Relayer Management

**Phase 1 (Current):** Admin whitelist only.

**Bond/Guarantee:** Off-chain (legal agreement / escrow).

See [RELAYER.md](./RELAYER.md) for full details.

---

## User Safety

**If no relayer fills → Sender gets full refund after deadline.**

No fund loss possible. Worst case = wait for timeout.

---

## Off-Chain vs On-Chain

| Data | Location |
|------|----------|
| Intent state, funds | On-chain |
| Relayer monitoring | Off-chain indexer |
| Fill verification | Axelar (75+ validators) |

---

## See Also

- [FUND_FLOW.md](./FUND_FLOW.md) - Fund movement & fees
- [TERMINOLOGY.md](./TERMINOLOGY.md) - Terms and supported chains
- [RELAYER.md](./RELAYER.md) - Relayer guide
- [MESSENGER_DESIGN.md](./MESSENGER_DESIGN.md) - Messenger interface & Axelar
