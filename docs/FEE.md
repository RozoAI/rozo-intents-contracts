# RozoIntents Fee Structure

## Overview

Fees are collected on the **source chain** because that's where the protocol receives tokens.

## Fee Components

| Component | Who sets | Who receives | When charged |
|-----------|----------|--------------|--------------|
| **Protocol Fee** | Rozo (fixed) | Rozo protocol | On source chain, on top of amount |
| **Relayer Spread** | Relayer (variable) | Relayer | Built into exchange rate |

## Protocol Fee

Fixed percentage set by protocol, currently **0.03% (3 bps)**.

```
Protocol Fee = sourceAmount * protocolFeeBps / 10000

Example:
- User deposits: 1000 USDC
- Protocol fee (3 bps): 1000 * 3 / 10000 = 0.3 USDC
- Available for relayer: 999.7 USDC
```

**Charged on source chain:**
- Protocol fee is deducted from what relayer receives
- User deposits full amount, protocol takes cut before relayer payout

## Relayer Spread

Relayer decides their own profit margin based on:
- Bridge costs
- Swap costs (if token conversion needed)
- Gas costs on destination
- Risk premium

### EXACT_IN: Relayer Decides Destination Amount

```
┌─────────────────────────────────────────────────────────────┐
│  EXACT_IN Flow                                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  User specifies: sourceAmount = 1000 USDC (on Base)         │
│                                                             │
│  Protocol fee:   1000 * 0.03% = 0.3 USDC                    │
│  Relayer gets:   999.7 USDC                                 │
│                                                             │
│  Relayer decides to pay: 995 USDC (on Stellar)              │
│  Relayer profit: 999.7 - 995 = 4.7 USDC equivalent          │
│                  (minus bridge/gas costs)                   │
│                                                             │
│  Receiver gets:  995 USDC on Stellar                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### EXACT_OUT: Relayer Decides Source Amount

```
┌─────────────────────────────────────────────────────────────┐
│  EXACT_OUT Flow                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  User specifies: destinationAmount = 1000 USDC (on Stellar) │
│                                                             │
│  Relayer calculates how much source needed:                 │
│  - Destination amount: 1000 USDC                            │
│  - Relayer spread: ~5 USDC                                  │
│  - Protocol fee: ~0.3 USDC                                  │
│  - Required source: ~1005.3 USDC                            │
│                                                             │
│  User must deposit: 1005.3 USDC (on Base)                   │
│  Protocol fee: 1005.3 * 0.03% = 0.3 USDC                    │
│  Relayer gets: 1005 USDC                                    │
│  Relayer pays: 1000 USDC on Stellar                         │
│  Relayer profit: 5 USDC equivalent (minus costs)            │
│                                                             │
│  Receiver gets: exactly 1000 USDC on Stellar                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Fee Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           SOURCE CHAIN                                   │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  User deposits 1000 USDC                                                 │
│         │                                                                │
│         ▼                                                                │
│  ┌─────────────────────┐                                                 │
│  │   Main Contract     │                                                 │
│  │                     │                                                 │
│  │  Protocol Fee: 0.3  │──────► Protocol Treasury                        │
│  │  Relayer: 999.7     │──────► Relayer Wallet                           │
│  │                     │                                                 │
│  └─────────────────────┘                                                 │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                         DESTINATION CHAIN                                │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Relayer pays receiver (amount based on their spread)                    │
│         │                                                                │
│         ▼                                                                │
│  ┌─────────────────────┐                                                 │
│  │     Receiver        │                                                 │
│  │   (gets ~995 USDC)  │                                                 │
│  └─────────────────────┘                                                 │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Protocol Fee Configuration

```solidity
// In RozoBridgeInterface contract
uint256 public protocolFeeBps;  // Default: 3 (0.03%)

// Fee calculation
uint256 protocolFee = sourceAmount * protocolFeeBps / 10000;
uint256 relayerReceives = sourceAmount - protocolFee;
```

## Fee Admin Functions

```solidity
/// @notice Set protocol fee (only owner)
/// @param feeBps Fee in basis points (e.g., 3 = 0.03%)
function setProtocolFee(uint256 feeBps) external onlyOwner;

/// @notice Withdraw accumulated protocol fees
/// @param token Token address (or address(0) for native)
/// @param to Recipient address
function withdrawFees(address token, address to) external onlyOwner;
```

## Summary

| Intent Type | Amount in Intent | Relayer Decides | Receiver Gets |
|-------------|------------------|-----------------|---------------|
| EXACT_IN | Source amount (fixed) | Destination amount | Variable (source - fees - spread) |
| EXACT_OUT | Destination amount (fixed) | Source amount required | Fixed (exactly as specified) |

**Protocol always takes 0.03% from source amount.** Relayer profit is the spread between what they receive and what they pay.
