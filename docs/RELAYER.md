# Relayer Guide

## Overview

Relayers fill intents by paying on destination chain, then get repaid on source chain.

## Current Phase: Whitelisted Relayers

| Setting | Value |
|---------|-------|
| Who can relay | Admin-whitelisted addresses only |
| How to add | Admin calls `addRelayer(address)` |
| Guarantee/Bond | Not required (Phase 1) |

## Flow

```
1. User creates intent on Base (funds locked)
2. Relayer sees intent (off-chain indexer)
3. Relayer pays receiver on Stellar
4. Relayer calls RozoStellar.fill() → Axelar message
5. Axelar delivers → fillRelay() → Relayer gets paid
```

## What If Relayer Doesn't Act?

**User funds are SAFE.**

| Scenario | Result |
|----------|--------|
| No relayer fills | User waits until deadline |
| Deadline passes | Anyone calls `refund()` |
| User gets | Full amount back (no fee) |

```
Intent created ──► No fill ──► Deadline expires ──► refund() ──► User gets 100%
```

**Worst case = wait for timeout.** No fund loss possible.

## Off-Chain Data

| Data | Where |
|------|-------|
| Intent creation | On-chain event |
| Relayer monitoring | Off-chain indexer |
| Stellar payment | Stellar ledger |
| Fill confirmation | Axelar message (verified by 75+ validators) |
| Settlement | On-chain fillRelay() |

## Future: Open Relayer Network (Phase 2)

| Feature | Status |
|---------|--------|
| Open registration | Planned |
| Relayer bond/stake | Planned |
| Timeout compensation | Planned |
| Competition (first-fill-wins) | Planned |

### Planned: Relayer Bond

```solidity
// Future: Relayer must stake to participate
function registerRelayer() external payable {
    require(msg.value >= MIN_BOND);
    relayers[msg.sender] = true;
}
```

### Planned: Timeout Compensation

If intent times out, user may receive compensation (off-chain airdrop or on-chain reward) to offset the wait.

## Admin Functions

```solidity
// Phase 1: Whitelist management
function addRelayer(address relayer) external onlyOwner;
function removeRelayer(address relayer) external onlyOwner;
```

## Security Summary

| Risk | Mitigation |
|------|-----------|
| Relayer doesn't fill | User refunds after deadline |
| Relayer fills wrong amount | Axelar verifies actual payment |
| Fake fill message | Only Axelar Gateway can call fillRelay |
| Relayer front-running | Whitelist (Phase 1), bond (Phase 2) |
