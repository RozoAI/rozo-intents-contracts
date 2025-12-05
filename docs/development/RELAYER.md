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
| Source (e.g., Base) | Call `fill()`, receive payment |
| Destination (e.g., Stellar) | Call `fillAndNotify()`, pay receiver |

### Example: Base → Stellar

```
Relayer needs:
- Base address (EVM):    0x1234...abcd  → calls fill(), receives USDC
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

**Note:** The relayer address recorded in `intent.relayer` is the source chain address. This is the address that receives `sourceAmount - protocolFee` on `notify()`.

## Fill Race Condition

**First-come-first-serve.** Multiple relayers may attempt to fill the same intent:

1. First relayer to successfully call `fill()` changes status to FILLING
2. That relayer's address is recorded as responsible for the fill
3. Other relayers' transactions will revert (status already FILLING)
4. Only the recorded relayer receives payment on `notify()`

## Fast Fill Flow (Base → Stellar)

```
1. Sender creates intent on Base (funds locked, status = NEW)
2. Relayer sees intent (off-chain indexer)
3. Relayer calls fill() on RozoIntentsBase → status = FILLING
4. Relayer calls fillAndNotify() on RozoIntentsStellar
   └── Contract transfers tokens: relayer → receiver
   └── Contract calls Axelar Gateway with payment proof
5. Axelar validators verify the Stellar contract event
6. Axelar delivers → notify() on RozoIntentsBase → status = FILLED, relayer paid
```

**Important:** Relayer must call `fillAndNotify()` on destination chain contract. The contract executes the payment (not the relayer directly), so Axelar can verify the on-chain event.

## Slow Fill Flow (EVM ↔ EVM only)

**Note:** SlowFill only works for EVM ↔ EVM routes (CCTP). Base ↔ Stellar uses Fast Fill only.

```
Example: Base → Arbitrum
1. Sender creates intent on Base (funds locked, status = NEW)
2. Relayer/bot calls slowFill() on RozoIntentsBase
3. Contract deducts fee, calls CCTP burn → status = FILLED
4. CCTP mints directly to receiver on Arbitrum
```

## Functions

| Function | Caller | Result |
|----------|--------|--------|
| `fill()` | Relayer | NEW → FILLING (fast path) |
| `slowFill()` | Relayer | NEW → FILLED (bridge path, no relayer profit) |
| `notify()` | Messenger | FILLING → FILLED (relayer paid) |

## What If Relayer Doesn't Complete?

**Sender funds are SAFE.**

| Scenario | Result |
|----------|--------|
| Relayer calls fill() but never pays | Intent stays FILLING until deadline |
| Deadline passes | Sender calls `refund()` |
| Sender gets | Full amount back (no fee) |

**Worst case = wait for timeout.** No fund loss possible.

## Intent Discovery

Relayers discover new intents through:

### Option 1: Rozo API (Recommended)

Rozo provides an API for relayers to discover fillable intents:

```
GET /api/v1/intents?status=NEW&destinationChain=stellar
```

Returns list of intents with all details needed to fill.

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
    uint64 deadline
);
```

### Events to Monitor

| Event | When | Action |
|-------|------|--------|
| `IntentCreated` | New intent available | Evaluate profitability, decide to fill |
| `IntentFilling` | Another relayer claimed | Stop trying to fill this intent |
| `IntentFilled` | Intent completed | Update local state |
| `IntentRefunded` | Intent refunded | Remove from active list |

## Off-Chain Data

| Data | Where |
|------|-------|
| Intent creation | On-chain event / Rozo API |
| Relayer monitoring | Off-chain indexer / Rozo API |
| Stellar payment | Stellar ledger |
| Fill confirmation | Axelar message (verified by 75+ validators) |
| Settlement | On-chain notify() |

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
| Fake fillNotify | Only Messenger can call |

---

## See Also

### Design
- [DESIGN.md](../design/DESIGN.md) - Architecture overview
- [FUND_FLOW.md](../design/FUND_FLOW.md) - Fund movement & fees
- [DATA_STRUCTURES.md](../design/DATA_STRUCTURES.md) - Contract interfaces

### Development
- [DEPLOYMENT.md](./DEPLOYMENT.md) - Deployment guide
- [TESTING.md](./TESTING.md) - Testing guide
