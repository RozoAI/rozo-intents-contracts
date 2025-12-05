# RozoIntents Design

Intent-based cross-chain payments. Base ↔ Stellar (bidirectional).

**No custom validators.** Axelar messenger handles verification.

---

## Intent ID

`bytes32` - Generated off-chain, passed to `createIntent()`.

Example: `keccak256(abi.encodePacked(uuid))`

---

## Intent Timing

| Field | Type | Description |
|-------|------|-------------|
| `deadline` | `uint64` | Unix timestamp (seconds). After this, refund is allowed. |

### Recommended Values

| Scenario | Deadline |
|----------|----------|
| Standard transfer | 1-4 hours from now |
| High-value transfer | 4-24 hours from now |
| Minimum | 10 minutes (relayers need time) |

### Timing Rules

- `fill()` / `slowFill()` → require `block.timestamp < deadline`
- `refund()` → require `block.timestamp >= deadline`
- Near deadline: relayers may skip intent to avoid race with expiry

---

## Intent Status

| Status | Description |
|--------|-------------|
| NEW | Sender deposited, waiting for fill |
| FILLING | Relayer called `fill()`, awaiting messenger confirmation |
| FILLED | Fill completed (via `notify()` or `slowFill()`) |
| REFUNDED | Sender refunded after deadline |

**Note:** There is no explicit EXPIRED status in storage. When `deadline` passes:
- Intent remains in current status (NEW or FILLING)
- `refund()` becomes callable
- `refund()` sets status directly to REFUNDED

---

## Amount Model

```
createIntent(sourceAmount, destinationAmount, ...)
```

| Field | Description |
|-------|-------------|
| `sourceAmount` | Amount sender deposits (locked in contract) |
| `destinationAmount` | Minimum amount receiver expects |

**Fee handling:** Frontend calculates fees upfront. Contract does not compute fees - it simply:
1. Locks `sourceAmount` from sender
2. Verifies relayer paid `>= destinationAmount` to receiver
3. Releases `sourceAmount` to relayer on successful fill

---

## Functions

### Source Chain (where intent is created)

| Function | Caller | Description |
|----------|--------|-------------|
| `createIntent()` | Sender | Deposit sourceAmount, lock funds |
| `fill()` | Relayer | Mark as FILLING, record relayer |
| `notify()` | Messenger only | Confirm fill → FILLED, pay relayer |
| `slowFill()` | Relayer/Bot | Bridge via CCTP → FILLED directly (EVM only) |
| `refund()` | Sender | Refund after deadline → REFUNDED |

### Destination Chain (where receiver gets paid)

| Function | Caller | Description |
|----------|--------|-------------|
| `fillAndNotify()` | Relayer | Transfer to receiver + send Axelar message |

---

## Flow

### Fast Fill (via Relayer + Axelar)
```
Source Chain                 Destination Chain              Axelar
     │                              │                          │
1. createIntent()                   │                          │
   status = NEW                     │                          │
     │                              │                          │
2. fill()                           │                          │
   status = FILLING                 │                          │
   relayer recorded                 │                          │
     │                              │                          │
     │                       3. fillAndNotify()                │
     │                          transfer: relayer → receiver   │
     │                          call Axelar Gateway ──────────►│
     │                              │                          │
     │                              │              4. Validators verify
     │                              │                          │
     │◄─────────────────────────────────────────── 5. notify()
     │                              │                          │
6. status = FILLED                  │                          │
   pay relayer                      │                          │
```

### Slow Fill (via CCTP Bridge, EVM only)
```
Source Chain (EVM)           CCTP                    Destination (EVM)
     │                          │                          │
1. createIntent()               │                          │
   status = NEW                 │                          │
     │                          │                          │
2. slowFill()                   │                          │
   deduct fee                   │                          │
   call bridge adapter ────────►│                          │
     │                          │                          │
3. status = FILLED              │                          │
     │                          │                          │
     │                    ~1-60 min                        │
     │                          │                          │
     │                    CCTP mint ──────────────────────►│
     │                          │                   receiver gets funds
```

---

## Admin (Minimal)

```solidity
setFeeRecipient(address)
setProtocolFee(uint256)   // max 30 bps
withdrawFees(token)       // feeRecipient withdraws accumulated fees
addRelayer(address)
removeRelayer(address)
```

---

## Fast vs Slow Fill

| Mode | Function | Speed | Status Flow | Relayer Profit |
|------|----------|-------|-------------|----------------|
| Fast | `fill()` + `notify()` | ~5-10 sec | NEW → FILLING → FILLED | Yes (spread) |
| Slow | `slowFill()` | ~1-60 min | NEW → FILLED | No (service only) |

**Fast Fill:** Relayer pays on destination, gets repaid on source (earns spread).

**Slow Fill:** CCTP bridges funds directly to receiver. Fee deducted before burn. No relayer profit - it's a fallback service. Bypasses RozoIntents on destination chain entirely.

**⚠️ SlowFill Warning:** Once `slowFill()` succeeds (CCTP burn completes), **no refund is possible via RozoIntents**. If CCTP mint stalls, user must claim refund directly from CCTP using their `refundAddress`.

See [SLOWFILLED.md](./SLOWFILLED.md) for full details.

---

## Relayer Management

**Phase 1 (Current):** Admin whitelist only.

**Bond/Guarantee:** Off-chain (legal agreement / escrow).

**Fill Race Condition:** First-come-first-serve. The relayer who successfully changes status on-chain becomes responsible for the fill.

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

## Token Support

**Any token allowed.** No whitelist required.

Note: If a user creates an intent with an obscure token, it may not be filled by any relayer (relayers choose which intents to fill based on profitability).

---

## Supported Chains

| Chain | Contract | Language | Direction |
|-------|----------|----------|-----------|
| Base | RozoIntentsBase | Solidity | Source ↔ Destination |
| Stellar | RozoIntentsStellar | Soroban (Rust) | Source ↔ Destination |

Both chains deploy RozoIntents contract. Flows work in both directions.

### Stellar Implementation Notes

- **Language:** Soroban smart contracts (Rust)
- **Axelar GMP:** Axelar supports Stellar via GMP
- **Address format:** Stellar uses 32-byte public keys (G... addresses), compatible with `bytes32`
- **Token standard:** Stellar uses native token interface (not ERC-20)

### Fill Mode Support

| Route | Fast Fill | Slow Fill |
|-------|-----------|-----------|
| Base ↔ Stellar | Yes | No (CCTP doesn't support Stellar yet) |
| EVM ↔ EVM | Yes | Yes (via CCTP) |

**Fast Fill:** Works on all routes via Axelar messaging.

**Slow Fill:** Only EVM ↔ EVM routes where CCTP is supported. Bypasses destination contract - funds go directly to receiver.

---

## See Also

- [FUND_FLOW.md](./FUND_FLOW.md) - Fund movement & fees
- [TERMINOLOGY.md](./TERMINOLOGY.md) - Terms and supported chains
- [RELAYER.md](./RELAYER.md) - Relayer guide
- [MESSENGER_DESIGN.md](./MESSENGER_DESIGN.md) - Messenger interface & Axelar
- [SLOWFILLED.md](./SLOWFILLED.md) - SlowFill bridge fallback details
