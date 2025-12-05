# Relayer Guide

## Overview

Relayers fill intents by paying on destination chain, then get repaid on source chain.

## Current Phase: Whitelisted Relayers

| Setting | Value |
|---------|-------|
| Who can relay | Admin-whitelisted addresses only |
| How to add | Admin calls `addRelayer(address)` |
| Guarantee/Bond | Off-chain (legal agreement / escrow) |

## Flow

```
1. Sender creates intent on Base (funds locked, status = NEW)
2. Relayer sees intent (off-chain indexer)
3. Relayer calls fill() or slowFill() → status = FILLING
4. Relayer pays receiver on Stellar
5. Relayer calls RozoStellar.fill() → Axelar message
6. Axelar delivers → fillNotify() → status = FILLED, relayer paid
```

## Functions

| Function | Caller | Result |
|----------|--------|--------|
| `fill()` | Relayer | NEW → FILLING (fast path) |
| `slowFill()` | Relayer | NEW → FILLING (slow bridge) |
| `fillNotify()` | Messenger | FILLING → FILLED (relayer paid) |

## What If Relayer Doesn't Complete?

**Sender funds are SAFE.**

| Scenario | Result |
|----------|--------|
| Relayer calls fill() but never pays | Intent stays FILLING until deadline |
| Deadline passes | Anyone calls `refund()` |
| Sender gets | Full amount back (no fee) |

**Worst case = wait for timeout.** No fund loss possible.

## Off-Chain Data

| Data | Where |
|------|-------|
| Intent creation | On-chain event |
| Relayer monitoring | Off-chain indexer |
| Stellar payment | Stellar ledger |
| Fill confirmation | Axelar message (verified by 75+ validators) |
| Settlement | On-chain fillNotify() |

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
