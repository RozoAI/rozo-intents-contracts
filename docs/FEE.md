# RozoIntents Fee Structure

## Protocol Fee

| Setting | Value |
|---------|-------|
| Default | 3 bps (0.03%) |
| Maximum | 30 bps (0.3%) |
| Adjustable | Yes, by admin |

```
Protocol Fee = sourceAmount * protocolFeeBps / 10000

Example (3 bps):
- User deposits: 1000 USDC
- Protocol fee: 1000 * 3 / 10000 = 0.3 USDC
- Relayer receives: 999.7 USDC
```

## Fee Flow

```
User deposits 1000 USDC
        │
        ▼
┌─────────────────────┐
│    RozoBridge       │
│                     │
│  Protocol: 0.3 USDC │──► feeRecipient
│  Relayer: 999.7     │──► Relayer (on fillRelay)
└─────────────────────┘
```

## Relayer Spread

Relayer profit = what they receive - what they pay on destination

```
Relayer receives: 999.7 USDC (on Base)
Relayer pays:     995 USDC (on Stellar)
Relayer profit:   4.7 USDC (minus bridge/gas costs)
```

## Admin Functions

```solidity
/// @notice Set protocol fee (max 30 bps)
function setProtocolFee(uint256 feeBps) external onlyOwner;

/// @notice Set fee recipient
function setFeeRecipient(address recipient) external onlyOwner;
```

## Fee Storage

- Fees are **not accumulated** in contract
- Fees transfer to `feeRecipient` immediately on each `fillRelay()`
- No separate withdrawal needed

## Intent Type Impact

| Type | Source Amount | Destination Amount | Fee Payer |
|------|--------------|-------------------|-----------|
| EXACT_IN | Fixed | Variable | Receiver (gets less) |
| EXACT_OUT | Variable | Fixed | Sender (pays more) |
