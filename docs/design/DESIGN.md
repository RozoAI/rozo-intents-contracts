# RozoIntents Design

Intent-based cross-chain payments. Base ↔ Stellar (bidirectional).

**Messenger options:** Users can choose between Axelar (third-party validator network) or Rozo Messenger (Rozo's custom messenger) when creating intents.

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

- `fillAndNotify()` / `slowFill()` → require `block.timestamp < deadline`
- `refund()` → require `block.timestamp >= deadline`
- Near deadline: relayers may skip intent to avoid race with expiry

---

## Intent Status

| Status | Description |
|--------|-------------|
| PENDING | Sender deposited, waiting for fill |
| FILLED | Fill completed (via `notify()` or `slowFill()`) |
| FAILED | Fill verification failed (mismatch in receiver, token, or amount) |
| REFUNDED | Sender refunded after deadline |

**Note:** There is no explicit EXPIRED status in storage. When `deadline` passes:
- Intent remains in current status (PENDING)
- `refund()` becomes callable
- `refund()` sets status directly to REFUNDED

### FAILED Status

When `notify()` receives a payload that doesn't match the original intent:
- Receiver address mismatch
- Destination token mismatch
- Amount paid < destinationAmount

The intent is set to `FAILED`. Admin must manually investigate and can:
- Change status back to PENDING (allow retry)
- Change status to FILLED (if payment was actually correct)
- Update relayer address
- Trigger refund

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
| `createIntent()` | Sender | Deposit sourceAmount, lock funds. Optionally assign relayer from RFQ. |
| `notify()` | Messenger only | Confirm fill → FILLED, pay relayer |
| `slowFill()` | Relayer/Bot | Bridge via CCTP → FILLED directly (EVM only) |
| `refund()` | Sender or refundAddress | Refund after deadline → REFUNDED |

### Destination Chain (where receiver gets paid)

| Function | Caller | Description |
|----------|--------|-------------|
| `fillAndNotify()` | Relayer | Transfer to receiver + send Axelar message. Includes `repaymentAddress` for cross-chain payout. |

---

## Flow

### Fast Fill (via Relayer + Axelar)

```
Source Chain                 Destination Chain              Axelar
     │                              │                          │
1. RFQ Auction (off-chain)          │                          │
   relayer assigned                 │                          │
     │                              │                          │
2. createIntent(relayer)            │                          │
   status = PENDING                 │                          │
     │                              │                          │
     │                       3. fillAndNotify(intentData, repaymentAddress)
     │                          verify: not already filled     │
     │                          transfer: relayer → receiver   │
     │                          call Axelar Gateway ──────────►│
     │                              │                          │
     │                              │              4. Validators verify
     │                              │                          │
     │◄─────────────────────────────────────────── 5. notify()
     │                              │                          │
6. status = FILLED                  │                          │
   pay relayer (repaymentAddress)   │                          │
```

### RFQ (Request for Quote) System

Instead of relayers racing on-chain to claim intents, an off-chain RFQ auction determines the relayer before intent creation:

```
User                    RFQ Server              Relayers            Source Chain
  │                         │                      │                     │
  │ Request quote ─────────►│                      │                     │
  │                         │ Broadcast ──────────►│                     │
  │                         │                      │                     │
  │                         │◄──── Bids ───────────│                     │
  │                         │                      │                     │
  │◄─── Best quote ─────────│                      │                     │
  │     (price + relayer)   │                      │                     │
  │                         │                      │                     │
  │ Accept & createIntent(relayer = winner) ──────────────────────────►│
  │                         │                      │                     │
  │                         │                      │  fillAndNotify() ──►│
```

**Benefits:**
- No gas spent on source chain by relayers
- Competitive pricing through auction
- Users see quote before committing
- Single event to watch (`IntentCreated`)

**Open Intents:** If `relayer = address(0)`, any whitelisted relayer can fill. Used when no RFQ bids received.

### Destination Chain Fill Protection

The destination chain tracks filled intents using a hash of the full `IntentData` struct to prevent:
- Double-fill attacks (same intent filled twice)
- Parameter tampering (filling with wrong amounts)
- Cross-chain replay attacks

```solidity
// Destination chain storage
mapping(bytes32 => bool) public filledIntents;  // fillHash => filled

// Fill hash computed from ALL intent parameters
bytes32 fillHash = keccak256(abi.encode(intentData, block.chainid));
require(!filledIntents[fillHash], "AlreadyFilled");
filledIntents[fillHash] = true;
```

### Cross-Chain Repayment Address

Relayers specify a `repaymentAddress` in `fillAndNotify()` to receive payment on the source chain. This solves the cross-chain address mismatch problem:

- Stellar and EVM use different key formats
- Relayer's destination chain address cannot be derived to a valid source chain address
- `repaymentAddress` is passed through Axelar and used for payout on source chain

```
Relayer fills on Stellar (G... address)
    ↓
fillAndNotify(intentData, repaymentAddress: 0x1234...)
    ↓
Axelar message includes repaymentAddress
    ↓
notify() on Base pays 0x1234... (relayer's EVM address)
```

### What If fillAndNotify() Fails?

| Scenario | Result |
|----------|--------|
| Intent already filled on destination | Transaction reverts with "AlreadyFilled" |
| `fillAndNotify()` succeeds but `notify()` fails verification | Intent set to FAILED, admin investigates |
| Relayer never fills | Intent stays PENDING until deadline, then sender refunds |

### Slow Fill (via CCTP Bridge, EVM only)

```
Source Chain (EVM)           CCTP                    Destination (EVM)
     │                          │                          │
1. createIntent()               │                          │
   status = PENDING             │                          │
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

## Admin Functions

### Fee Management
```solidity
setFeeRecipient(address)
setProtocolFee(uint256)   // max 30 bps
withdrawFees(token)       // feeRecipient withdraws accumulated fees
```

### Relayer Management
```solidity
addRelayer(address)
removeRelayer(address)
```

### Intent Recovery (for FAILED status)
```solidity
// Admin can update intent status for recovery
setIntentStatus(bytes32 intentId, IntentStatus status)

// Admin can update relayer address (if wrong relayer recorded)
setIntentRelayer(bytes32 intentId, address relayer)

// Admin can force refund (for stuck intents)
adminRefund(bytes32 intentId)
```

### Cross-Chain Configuration
```solidity
setTrustedContract(string chainName, string contractAddress)
setMessenger(address messenger, bool allowed)
```

---

## Fast vs Slow Fill

| Mode | Function | Speed | Status Flow | Relayer Profit |
|------|----------|-------|-------------|----------------|
| Fast | `fillAndNotify()` + `notify()` | ~5-10 sec | PENDING → FILLED | Yes (spread) |
| Slow | `slowFill()` | ~1-60 min | PENDING → FILLED | No (service only) |

**Fast Fill:** Relayer pays on destination, gets repaid on source (earns spread).

**Slow Fill:** CCTP bridges funds directly to receiver. Fee deducted before burn. No relayer profit - it's a fallback service. Bypasses RozoIntents on destination chain entirely.

**⚠️ SlowFill Warning:** Once `slowFill()` succeeds (CCTP burn completes), **no refund is possible via RozoIntents**. If CCTP mint stalls, user must claim refund directly from CCTP using their `refundAddress`.

See [SLOWFILLED.md](./SLOWFILLED.md) for full details.

---

## Relayer Management

**Phase 1 (Current):** Admin whitelist only.

**Bond/Guarantee:** Off-chain (legal agreement / escrow).

**Relayer Assignment:** Via RFQ auction (off-chain) before intent creation. Assigned relayer address is passed to `createIntent()`. If no relayer assigned (`address(0)`), any whitelisted relayer can fill.

See [RELAYER.md](../development/RELAYER.md) for full details.

---

## User Safety

**If no relayer fills → Sender gets full refund after deadline.**

No fund loss possible. Worst case = wait for timeout.

---

## Contract Upgrade Strategy

**No proxy pattern. No upgrades.**

| Design Choice | Rationale |
|---------------|-----------|
| No fund storage | Funds are transient, not stored long-term |
| Refund guarantee | Users can always refund after deadline |
| Simple contracts | Easier to audit, fewer attack vectors |

If contract changes are needed:
1. Deploy new contract version
2. Update trusted contracts on all chains
3. Old intents can still be filled or refunded on old contract
4. New intents use new contract

---

## Off-Chain vs On-Chain

| Data | Location |
|------|----------|
| Intent state, funds | On-chain |
| RFQ auction | Off-chain (WebSocket server) |
| Relayer monitoring | Off-chain indexer |
| Fill verification | Axelar (75+ validators) |
| Fill tracking (destination) | On-chain (filledIntents mapping) |

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
- **Token standard:** Stellar uses native token interface (SEP-41, not ERC-20)

### Stellar Token Operations (USDC Example)

```rust
// Stellar USDC contract address (testnet example)
const USDC_CONTRACT: Address = address!("CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA");

// Transfer tokens in Soroban
fn transfer_tokens(env: &Env, from: Address, to: Address, amount: i128) {
    let token = token::Client::new(env, &USDC_CONTRACT);
    token.transfer(&from, &to, &amount);
}

// Stellar USDC has 7 decimals
// 100 USDC = 1_000_000_0 (7 zeros)
```

### Stellar Address Encoding

```rust
// Stellar G... address is 32 bytes (Ed25519 public key)
// Can be used directly as bytes32 in cross-chain messages

// Example: G... → bytes32
let stellar_addr: Address = Address::from_string("GABC...");
let bytes32_addr: BytesN<32> = stellar_addr.to_bytes();

// Example: bytes32 → Stellar Address
let addr: Address = Address::from_bytes(&bytes32_addr);
```

### Fill Mode Support

| Route | Fast Fill | Slow Fill |
|-------|-----------|-----------|
| Base ↔ Stellar | Yes | No (CCTP doesn't support Stellar yet) |
| EVM ↔ EVM | Yes | Yes (via CCTP) |

**Fast Fill:** Works on all routes via Axelar messaging.

**Slow Fill:** Only EVM ↔ EVM routes where CCTP is supported. Bypasses destination contract - funds go directly to receiver.

---

## See Also

### Design
- [FUND_FLOW.md](./FUND_FLOW.md) - Fund movement & fees
- [GLOSSARY.md](./GLOSSARY.md) - Terms and supported chains
- [MESSENGER_DESIGN.md](./MESSENGER_DESIGN.md) - Messenger interface & Axelar
- [SLOWFILLED.md](./SLOWFILLED.md) - SlowFill bridge fallback details
- [DATA_STRUCTURES.md](./DATA_STRUCTURES.md) - Intent struct, events, errors

### Development
- [RELAYER.md](../development/RELAYER.md) - Relayer guide
- [DEPLOYMENT.md](../development/DEPLOYMENT.md) - Deployment guide
- [TESTING.md](../development/TESTING.md) - Testing guide
