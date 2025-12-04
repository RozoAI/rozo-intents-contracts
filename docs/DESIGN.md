# RozoIntents Design

Intent-based cross-chain payments. Base ↔ Stellar.

**No custom validators.** Axelar messenger handles verification.

---

## Functions

| Function | Who Calls | Description |
|----------|-----------|-------------|
| `createIntent` | User | Deposit funds |
| `fillRelay` | Messenger | Confirm payment, pay relayer |
| `slowFillIntent` | User | Bridge via CCTP/Allbridge |
| `refund` | Anyone | Refund expired intent |
| `flush` | Anyone | Sweep extra funds |

---

## Flow

```
EVM (Base)                           Stellar

1. User: createIntent()
   └── Deposits to RozoBridge

2.                                   Relayer pays receiver

3.                                   Relayer calls RozoStellar.fill()
                                     └── Axelar sends message

4. Axelar delivers confirmation
   └── RozoBridge.fillRelay()
   └── Relayer gets paid
```

---

## Contracts

```
contracts/
├── RozoTypes.sol
├── core/
│   ├── RozoBridge.sol          # Main contract
│   └── RozoBridgeAdmin.sol
├── messengers/
│   ├── IMessenger.sol          # Interface
│   └── AxelarMessenger.sol
└── interfaces/
    └── IRozoBridge.sol
```

---

## Admin (Minimal)

```solidity
setFeeRecipient(address)
setProtocolFee(uint256)   // max 30 bps
```

---

## Fast vs Slow Fill

| Mode | Speed | How |
|------|-------|-----|
| Fast | ~1-2 min | Relayer pays, Axelar confirms |
| Slow | ~15-20 min | User bridges via CCTP/Allbridge |

---

## See Also

- [AXELAR_GMP_DESIGN.md](./AXELAR_GMP_DESIGN.md) - Axelar details
- [FEE.md](./FEE.md) - Fee structure (default 3 bps, max 30 bps)
- [FUND_FLOW.md](./FUND_FLOW.md) - Fund movement
- [TERMINOLOGY.md](./TERMINOLOGY.md) - Terms and supported chains
