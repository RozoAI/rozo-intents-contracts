# Relayer Guide

## Overview

Relayers fill intents by paying on destination chain, then get repaid on source chain.

## Current Phase: Whitelisted Relayers

| Setting | Value |
|---------|-------|
| Who can relay | Admin-whitelisted addresses only |
| How to add | Admin calls `addRelayer(address)` on each chain |
| Guarantee/Bond | Off-chain (legal agreement / escrow) |

## Multi-Chain Address Requirement

**Relayers MUST have addresses on both source and destination chains.**

| Chain | Required For |
|-------|--------------|
| Source (e.g., Base) | Receive payment via `repaymentAddress` |
| Destination (e.g., Stellar) | Call `fillAndNotify()`, pay receiver |

### Cross-Chain Address Mismatch Solution

Stellar and EVM use different key formats (Ed25519 vs secp256k1). A relayer's Stellar address cannot be derived to a valid EVM address. The `repaymentAddress` parameter solves this:

```
Relayer fills on Stellar:
- Stellar address: GABC...XYZ (calls fillAndNotify)
- repaymentAddress: 0x1234...7890 (receives payout on Base)

fillAndNotify(intentData, repaymentAddress: 0x1234...7890)
    ↓
Axelar message carries repaymentAddress
    ↓
notify() on Base pays 0x1234...7890
```

### Example: Base → Stellar

```
Relayer needs:
- Base address (EVM):    0x1234...abcd  → receives USDC via repaymentAddress
- Stellar address:       G...           → calls fillAndNotify(), pays receiver
```

### Relayer Registration

Admin must whitelist relayer address on **both chains**:

```solidity
// On Base (source)
RozoIntentsBase.addRelayer(0x1234...abcd);

// On Stellar (destination)
RozoIntentsStellar.addRelayer(G...);
```

**Note:** The `repaymentAddress` specified in `fillAndNotify()` is where funds are sent on the source chain. This can be any valid address the relayer controls.

---

## RFQ (Request for Quote) System

Instead of racing on-chain, relayers compete in an off-chain auction before intent creation.

### RFQ Flow

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

### Quote Request Parameters

- `sourceChain`: Chain where user funds are locked
- `destinationChain`: Chain where user wants to receive funds
- `sourceToken`: Token being swapped from
- `destinationToken`: Token being received
- `amount`: Input or output amount depending on intent type
- `intentType`: One of `exact_input`, `exact_output`, or `min_output`

### Intent Types

| Type | Description | User Specifies | Relayer Quotes |
|------|-------------|----------------|----------------|
| `exact_input` | User knows exact amount to send | Source amount | Destination amount they'll receive |
| `exact_output` | User knows exact amount to receive | Destination amount | Source amount required |
| `min_output` | User sets minimum acceptable output | Source amount + minimum | Best destination amount above minimum |

### Assigned vs Open Intents

| Intent Type | `relayer` field | Who can fill |
|-------------|-----------------|--------------|
| **Assigned** | Specific address from RFQ | Only that relayer |
| **Open** | `address(0)` | Any whitelisted relayer |

**Open intents** are created when:
- No relayers bid in the RFQ auction
- User opts out of RFQ (accepts market price)
- ROZO backup relayer fills unclaimed intents

---

## Fast Fill Flow (Base → Stellar)

```
1. User requests quote from RFQ server
2. Relayers submit bids during auction window
3. User accepts best quote, calls createIntent(relayer = winning_relayer)
4. Assigned relayer sees IntentCreated event (or via Rozo API)
5. Relayer calls fillAndNotify(intentData, repaymentAddress) on Stellar
   └── Contract verifies relayer matches intentData.relayer
   └── Contract verifies intent not already filled (filledIntents mapping)
   └── Contract transfers tokens: relayer → receiver
   └── Contract calls Axelar Gateway with payment proof
6. Axelar validators verify the Stellar contract event
7. Axelar delivers → notify() on Base → status = FILLED, relayer paid to repaymentAddress
```

**Important:**
- Relayer must pass full `IntentData` struct to `fillAndNotify()`
- Contract verifies `msg.sender` matches `intentData.relayer` (if assigned intent)
- `repaymentAddress` specifies where to receive payout on source chain

## Slow Fill Flow (EVM ↔ EVM only)

**Note:** SlowFill only works for EVM ↔ EVM routes (CCTP). Base ↔ Stellar uses Fast Fill only.

```
Example: Base → Arbitrum
1. Sender creates intent on Base (funds locked, status = PENDING)
2. Relayer/bot calls slowFill() on RozoIntentsBase
3. Contract deducts fee, calls CCTP burn → status = FILLED
4. CCTP mints directly to receiver on Arbitrum
```

## Functions

### Source Chain

| Function | Caller | Result |
|----------|--------|--------|
| `createIntent()` | Sender | → PENDING (with optional relayer assignment) |
| `slowFill()` | Relayer | PENDING → FILLED (bridge path, no relayer profit) |
| `notify()` | Messenger | PENDING → FILLED (relayer paid to repaymentAddress) |
| `refund()` | Sender/refundAddress | PENDING → REFUNDED (after deadline) |

### Destination Chain

| Function | Caller | Result |
|----------|--------|--------|
| `fillAndNotify()` | Relayer | Pay receiver, send Axelar message with repaymentAddress |

---

## What If Relayer Doesn't Complete?

**Sender funds are SAFE.**

| Scenario | Result |
|----------|--------|
| Assigned relayer doesn't fill | Intent stays PENDING until deadline |
| Deadline passes | Sender calls `refund()` |
| Sender gets | Full amount back (no fee) |

**Worst case = wait for timeout.** No fund loss possible.

---

## Intent Discovery

Relayers discover new intents through:

### Option 1: Rozo API (Recommended)

Rozo provides an API for relayers to discover fillable intents:

```
GET /api/v1/intents?status=PENDING&destinationChain=stellar
```

Returns list of intents with all details needed to fill, including full `IntentData`.

### Option 2: On-Chain Events

Listen to `IntentCreated` events directly:

```solidity
event IntentCreated(
    bytes32 indexed intentId,
    address indexed sender,
    address sourceToken,
    uint256 sourceAmount,
    uint256 destinationChainId,
    bytes32 receiver,
    uint256 destinationAmount,
    uint64 deadline,
    address relayer              // address(0) for open intents
);
```

### Events to Monitor

| Event | When | Action |
|-------|------|--------|
| `IntentCreated` | New intent available | Check if you're assigned relayer, evaluate profitability |
| `IntentFilled` | Intent completed | Update local state |
| `IntentRefunded` | Intent refunded | Remove from active list |

---

## fillAndNotify Workflow

```
Relayer Workflow:

1. DISCOVER
   ├── Listen for IntentCreated events OR poll Rozo API
   └── Filter for intents where you're the assigned relayer
       (or any PENDING intent if it's an open intent)

2. PREPARE
   ├── Build IntentData struct from event/API data
   ├── Verify intent not already filled on destination
   ├── Verify deadline hasn't passed
   └── Calculate if fill is profitable

3. APPROVE (if not already done)
   └── token.approve(RozoIntentsDestination, amount)

4. FILL
   └── fillAndNotify(intentData, repaymentAddress)
       - repaymentAddress = your source chain address

5. RECEIVE PAYMENT (~5-10 seconds)
   └── notify() on source chain pays to repaymentAddress
```

### IntentData Struct

```solidity
struct IntentData {
    bytes32 intentId;
    bytes32 sender;
    bytes32 refundAddress;
    bytes32 sourceToken;
    uint256 sourceAmount;
    uint256 sourceChainId;
    uint256 destinationChainId;
    bytes32 destinationToken;
    bytes32 receiver;
    uint256 destinationAmount;
    uint64 deadline;
    bytes32 relayer;            // Your address as bytes32 (or zero for open intents)
}
```

---

## Off-Chain Data

| Data | Where |
|------|-------|
| Intent creation | On-chain event / Rozo API |
| RFQ auction | Off-chain (WebSocket server) |
| Relayer monitoring | Off-chain indexer / Rozo API |
| Stellar payment | Stellar ledger |
| Fill confirmation | Axelar message (verified by 75+ validators) |
| Settlement | On-chain notify() |

---

## Error Handling

| Error | Cause | Solution |
|-------|-------|----------|
| `NotAssignedRelayer` | You're not the assigned relayer | Only assigned relayer can fill this intent |
| `AlreadyFilled` | Intent already filled | Check `filledIntents` mapping before filling |
| `IntentExpired` | Deadline passed | Cannot fill; user will refund |
| `NotRelayer` | Not whitelisted | Contact admin to whitelist your address |
| `WrongChain` | Wrong destination chain | Check `intentData.destinationChainId` |

---

## Future: Open Relayer Network (Phase 2)

| Feature | Status |
|---------|--------|
| Open registration | Planned |
| Relayer bond/stake | Planned |
| Timeout compensation | Planned |

## Admin Functions

```solidity
function addRelayer(address relayer) external onlyOwner;
function removeRelayer(address relayer) external onlyOwner;
```

## Security Summary

| Risk | Mitigation |
|------|-----------|
| Relayer doesn't complete | Sender refunds after deadline |
| Relayer fills wrong amount | Axelar verifies actual payment |
| Fake fillAndNotify | Only Messenger can call notify() |
| Double-fill attack | `filledIntents` mapping prevents duplicates |
| Wrong relayer fills | `intentData.relayer` verification on destination |
| Cross-chain address mismatch | `repaymentAddress` parameter |

---

## See Also

### Design
- [DESIGN.md](../design/DESIGN.md) - Architecture overview
- [FUND_FLOW.md](../design/FUND_FLOW.md) - Fund movement & fees
- [DATA_STRUCTURES.md](../design/DATA_STRUCTURES.md) - Contract interfaces

### Development
- [DEPLOYMENT.md](./DEPLOYMENT.md) - Deployment guide
- [TESTING.md](./TESTING.md) - Testing guide
