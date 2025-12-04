# RozoIntents Contract Design

## Overview

RozoIntents is a simplified intent-based cross-chain payment system. The contract handles:

1. **Intent Creation** - Generating unique intent addresses for users to deposit
2. **Intent State Management** - Tracking intent lifecycle (NEW → PROCESSED or EXPIRED)
3. **Validation** - Verifying relayer fulfilled the intent on destination chain
4. **Settlement** - Transferring funds to relayer after successful validation

Funds flow through the system in seconds - this is **not a custodial service**. Users can withdraw after the deadline passes (default 24 hours) if no relayer fulfills the intent.

All bridging and swapping is handled **off-chain by relayers**. The contract does not integrate with any bridge protocols directly.

See also:
- [TERMINOLOGY.md](./TERMINOLOGY.md) - Standard terms and definitions
- [DATA_STRUCTURES.md](./DATA_STRUCTURES.md) - Struct definitions and events

## Architecture

```
Source Chain (e.g., Base)                    Destination Chain (e.g., Stellar)
┌──────────────────────────────────┐         ┌─────────────────────────────────┐
│                                  │         │                                 │
│  1. User deposits via:           │         │  2. Relayer pays Bob directly   │
│     - Permit2 signature          │         │     (handles bridge/swap)       │
│     - Standard approve + call    │         │            │                    │
│     - Transfer to intent address │         │            ▼                    │
│            │                     │         │     ┌─────────────┐             │
│            ▼                     │         │     │  Receiver   │             │
│  ┌─────────────────────┐         │         │     │   (Bob)     │             │
│  │ RozoBridgeInterface │         │         │     └─────────────┘             │
│  │                     │         │         │                                 │
│  │  - Intent Storage   │         │         │                                 │
│  │  - Validation       │         │         │                                 │
│  └──────────┬──────────┘         │         │                                 │
│             │                    │         │                                 │
│  3. Validators verify dest tx    │◄────────┼── Relayer submits destTxHash    │
│     (Primary + Secondary sig)    │         │                                 │
│             │                    │         │                                 │
│  4. Relayer claims funds         │         │                                 │
│                                  │         │                                 │
└──────────────────────────────────┘         └─────────────────────────────────┘
```

## Intent Lifecycle

The contract supports **both single and multiple relayer** modes. The difference is operational, not contractual.

### Single Relayer Mode (Phase 1)

In Phase 1, only one whitelisted relayer operates. Relayer can directly fulfill without locking.

```
             User deposits
                  │
                  ▼
            ┌─────────┐
            │   NEW   │
            └────┬────┘
                 │
       ┌─────────┴─────────┐
       │                   │
       ▼                   ▼
  ┌─────────┐         ┌─────────┐
  │PROCESSED│         │ EXPIRED │ (deadline passed)
  └────┬────┘         └────┬────┘
       │                   │
       ▼                   ▼
  Relayer claims      User refunds
```

**Flow:**
1. User deposits → Intent is NEW
2. Relayer pays on destination, gets validator signatures
3. Relayer calls `fulfillIntent()` → Intent is PROCESSED, funds transferred
4. (Or) Deadline passes → User calls `refundIntent()`

### Multiple Relayers Mode (Phase 2)

When multiple relayers compete, use `processRequest()` to lock intent first, preventing race conditions.

```
             User deposits
                  │
                  ▼
            ┌─────────┐
            │   NEW   │
            └────┬────┘
                 │
                 │ Relayer calls processRequest()
                 ▼
           ┌───────────┐
           │PROCESSING │  (locked to this relayer)
           └─────┬─────┘
                 │
       ┌─────────┴─────────┐
       │                   │
       ▼                   ▼
  ┌─────────┐         ┌─────────┐
  │PROCESSED│         │ EXPIRED │
  └────┬────┘         └────┬────┘
       │                   │
       ▼                   ▼
  Relayer claims      User refunds
```

### Contract Supports Both Modes

The contract includes all functions for both modes. The mode is **operational choice**, not a contract setting:

| Function | Phase 1 | Phase 2 |
|----------|---------|---------|
| `createIntent()` | Used | Used |
| `startIntent()` | Used | Used |
| `processRequest()` | **Skip** (not needed) | **Use** (lock first) |
| `fulfillIntent()` | Used (from NEW) | Used (from PROCESSING) |
| `refundIntent()` | Used | Used |

### Intent States

| State | Value | Description |
|-------|-------|-------------|
| NEW | 0 | User deposited funds, waiting for relayer |
| PROCESSING | 1 | Relayer locked intent, working on fulfillment |
| PROCESSED | 2 | Validators confirmed, funds transferred to relayer |
| EXPIRED | 3 | Deadline passed without fulfillment |
| REFUNDED | 4 | User received refund |

### State Transitions

| From | To | Trigger | Who |
|------|-----|---------|-----|
| - | NEW | `createIntent()` / `startIntent()` | User |
| NEW | PROCESSING | `processRequest()` (optional) | Relayer |
| NEW | PROCESSED | `fulfillIntent()` (skip PROCESSING) | Relayer |
| NEW | EXPIRED | deadline passed | Anyone |
| PROCESSING | PROCESSED | `fulfillIntent()` | Same Relayer |
| PROCESSING | EXPIRED | deadline passed | Anyone |
| EXPIRED | REFUNDED | `refundIntent()` | User |

## Data Structures

See [DATA_STRUCTURES.md](./DATA_STRUCTURES.md) for detailed struct definitions, events, and errors.

## Validation Mechanism

### Primary + Secondary Validator Model

Based on proven cross-chain messaging patterns, we use a dual-signature validation:

```
┌─────────────────────────────────────────────────────────────┐
│                    VALIDATION FLOW                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Relayer pays Bob on destination chain                   │
│                        │                                    │
│                        ▼                                    │
│  2. Primary Validator monitors destination chain            │
│     - Sees payment tx, verifies amount/recipient            │
│     - Signs fulfillment proof                               │
│                        │                                    │
│                        ▼                                    │
│  3. Secondary Validator (independent) also verifies         │
│     - Runs own node, confirms same tx                       │
│     - Signs fulfillment proof                               │
│                        │                                    │
│                        ▼                                    │
│  4. Relayer submits both signatures to contract             │
│     - Contract verifies: primary sig + any secondary sig    │
│     - Marks intent as PROCESSED                             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Signature Content

Validators sign EIP-712 typed data:

```solidity
struct FulfillmentProof {
    bytes32 intentHash;          // keccak256(abi.encode(intent))
    bytes32 destinationTxHash;   // Transaction hash on destination
    uint256 amountPaid;          // Actual amount paid to receiver
    uint256 timestamp;           // When fulfillment was verified
}
```

### Why Primary + Secondary?

| Aspect | Description |
|--------|-------------|
| **Security** | Two independent parties must agree |
| **Simplicity** | Only 2 signatures to verify (low gas) |
| **Control** | Primary (Rozo) has oversight of all intents |
| **Redundancy** | Multiple secondaries provide backup |

### Failure Scenarios

| Scenario | Impact | User Funds |
|----------|--------|------------|
| Primary server down | No new fulfillments processed | **SAFE** - withdraw after deadline |
| Secondary server down | Use different secondary | **SAFE** - system continues |
| Primary key compromised | Attacker can fake fulfillments | **AT RISK** - see Security section |
| Secondary key compromised | Need primary + this secondary to attack | **SAFE** - rotate key |

## Intent Address Design: Dual Mode Support

We support **two deposit methods** to accommodate different user types:

### Mode 1: Per-Intent Address (API Users)

For users interacting via Rozo API:

```
┌─────────────────────────────────────────────────────────────┐
│  1. User calls Rozo API to create payment                   │
│     → API returns unique intent address (CREATE2)           │
│                                                             │
│  2. User sends tokens to intent address (simple transfer)   │
│     0x7a3b...f2c1 (unique per intent)                       │
│                                                             │
│  3. User payin triggers startIntent() on-chain              │
│     - Deploys intent contract, pulls funds to main contract │
│                                                             │
│  4. Relayer detects intent, pays receiver on destination    │
│                                                             │
│  5. Relayer calls fulfillIntent() with validator signatures │
│     - Validates signatures, transfers funds to relayer      │
└─────────────────────────────────────────────────────────────┘
```

**Use case**:
- Regular users via Rozo API
- Consumer products integrating Rozo
- Simpler UX (just send to address)

### Mode 2: Direct Contract Interaction (Contract Users)

For smart contracts or dApps interacting directly:

```
┌─────────────────────────────────────────────────────────────┐
│  1. User calls createIntent() directly on main contract     │
│     - With approve + transfer, OR                           │
│     - With Permit2 signature                                │
│     - Funds go directly to main contract                    │
│                                                             │
│  2. (v1) Relayer calls fulfillIntent() directly             │
│     (v2) Relayer calls processRequest() to lock, then       │
│          fulfillIntent() after paying destination           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Use case**:
- Smart contract wallets (Safe, etc.)
- dApps integrating RozoIntents directly
- Multiple relayer competition (v2)

### Comparison

| Aspect | Per-Intent Address | Direct Interaction |
|--------|-------------------|-------------------|
| Gas cost | Higher (deploy intent contract) | Lower |
| UX | Simple (send to address) | Requires contract call |
| Atomicity | Two steps | Single tx possible |
| Smart contract wallets | Works but wasteful | Preferred |
| Fund visibility | Scattered | Centralized |

### Architecture

```solidity
// Main contract holds all funds after processing
mapping(bytes32 => IntentStorage) public intents;

// Factory for per-intent addresses
RozoIntentFactory public intentFactory;

// Two ways to create intent:
// 1. createIntent() - direct deposit to main contract
// 2. startIntent() - pull from intent address
```

### How Intent Address Works

```solidity
// RozoIntentContract.sol - minimal proxy deployed per intent
contract RozoIntentContract {
    address public immutable mainContract;
    bytes32 public immutable intentHash;

    // Only main contract can pull funds
    function release(address token) external {
        require(msg.sender == mainContract);
        // Transfer all tokens to main contract
    }

    // User can reclaim if intent expires
    function refund(address token, address to) external {
        require(block.timestamp > deadline);
        // Transfer to refund address
    }
}
```

### Important: Not a Savings Account

```
┌─────────────────────────────────────────────────────────────┐
│                      DESIGN PRINCIPLE                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Intent addresses are TRANSIENT, not for storage.           │
│                                                             │
│  Expected flow:                                             │
│  ┌──────────┐     ┌──────────┐     ┌──────────┐            │
│  │  Deposit │ ──► │ Fulfill  │ ──► │  Claim   │            │
│  │  (T+0s)  │     │ (T+5s)   │     │ (T+10s)  │            │
│  └──────────┘     └──────────┘     └──────────┘            │
│                                                             │
│  Funds should move within SECONDS, not hours.               │
│                                                             │
│  If no relayer fulfills:                                    │
│  - Intent expires after deadline (default 24h)              │
│  - Sender withdraws via refundIntent()                      │
│                                                             │
│  DO NOT use intent addresses as wallets or vaults.          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Why this matters:**
- Intent addresses are minimal contracts (no access control beyond deadline)
- No interest earned on deposited funds
- Funds are locked until fulfilled or expired
- Designed for speed, not storage

### Fund Flow

```
Mode 1 (Intent Address):
User → Intent Address → Main Contract → Relayer

Mode 2 (Direct):
User → Main Contract → Relayer
```

## Contract Functions

### User Functions

```solidity
/// @notice Get intent address for an intent (does not deploy)
/// @dev User can send funds to this address before calling startIntent
function getIntentAddress(
    RozoIntent calldata intent
) external view returns (address intentAddress);

/// @notice Create intent with standard ERC20 approve (direct deposit)
/// @dev For Permit2/approve: transfers sourceAmount from sender
function createIntent(
    address sourceToken,
    uint256 sourceAmount,
    uint256 destinationChainId,
    bytes32 receiver,
    bytes32 destinationToken,
    uint256 destinationAmount,
    IntentType intentType,       // EXACT_IN (default) or EXACT_OUT
    uint256 deadline
) external payable returns (bytes32 intentHash);

/// @notice Create intent with Permit2 (gasless approval)
/// @dev For Permit2: transfers sourceAmount from sender using signature
function createIntentWithPermit2(
    address sourceToken,
    uint256 sourceAmount,
    uint256 destinationChainId,
    bytes32 receiver,
    bytes32 destinationToken,
    uint256 destinationAmount,
    IntentType intentType,
    uint256 deadline,
    bytes calldata permit2Signature
) external returns (bytes32 intentHash);

/// @notice Start intent from pre-funded intent address
/// @dev For intent address: uses ALL balance on the intent contract
/// @dev Deploys intent contract if needed, pulls funds to main contract
function startIntent(
    RozoIntent calldata intent
) external returns (bytes32 intentHash);

/// @notice Refund expired intent to refundAddress
function refundIntent(bytes32 intentHash) external;
```

### Relayer Functions

```solidity
/// @notice Lock an intent for processing (optional, for multi-relayer mode)
/// @dev Marks intent as PROCESSING, prevents other relayers from fulfilling
function processRequest(bytes32 intentHash) external;

/// @notice Fulfill intent and claim funds
/// @dev Verifies validator signatures, transfers funds to relayer
/// @dev Can be called from NEW (single relayer) or PROCESSING (multi relayer)
function fulfillIntent(
    RozoIntent calldata intent,
    bytes32 destinationTxHash,
    bytes calldata primarySignature,
    bytes calldata secondarySignature
) external;
```

**Usage by Mode:**

| Mode | Flow | Functions Used |
|------|------|----------------|
| Single Relayer | Pay → Fulfill (1 tx) | `fulfillIntent()` only |
| Multi Relayer | Lock → Pay → Fulfill | `processRequest()` then `fulfillIntent()` |

### Admin Functions

```solidity
/// @notice Set primary validator address
function setPrimaryValidator(address validator) external onlyOwner;

/// @notice Add a secondary validator
function addSecondaryValidator(address validator) external onlyOwner;

/// @notice Remove a secondary validator
function removeSecondaryValidator(address validator) external onlyOwner;

/// @notice Set protocol fee (in basis points)
function setProtocolFee(uint256 feeBps) external onlyOwner;

/// @notice Withdraw accumulated protocol fees
function withdrawFees(address token, address to) external onlyOwner;

/// @notice Emergency pause
function pause() external onlyOwner;
function unpause() external onlyOwner;
```

## Fee Structure

```
User deposits:     amountIn
Protocol fee:      amountIn * feeBps / 10000
Relayer receives:  amountIn - protocolFee

Example (feeBps = 30, i.e., 0.3%):
- User deposits: 1000 USDC
- Protocol fee:  1000 * 30 / 10000 = 3 USDC
- Relayer gets:  997 USDC
```

The relayer's profit comes from the spread between what they receive (997 USDC) and what they pay on destination (`amountOut`).

## Security Considerations

### Primary + Secondary Validator Security

The dual-validator model provides defense in depth:

```
┌─────────────────────────────────────────────────────────────┐
│                    SECURITY MODEL                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  To approve a fulfillment, attacker needs BOTH:             │
│  ┌───────────────┐     AND     ┌───────────────┐            │
│  │ Primary Key   │             │ Secondary Key │            │
│  │ (Rozo HSM)    │             │ (Any 1 of N)  │            │
│  └───────────────┘             └───────────────┘            │
│                                                             │
│  Single key compromise = SAFE (cannot approve alone)        │
│  Both keys compromised = AT RISK                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Compromise Scenarios

| Scenario | Can Attacker Steal? | Mitigation |
|----------|---------------------|------------|
| Primary key leaked | **NO** - needs secondary too | Rotate primary key |
| 1 Secondary key leaked | **NO** - needs primary too | Remove that secondary |
| Primary + 1 Secondary leaked | **YES** | Pause contract immediately |
| Primary server down (not leaked) | **NO** - just liveness issue | Users refund after deadline |

### Key Compromise Response Plan

**If primary key is compromised:**

1. **T+0**: Detect compromise (monitoring alerts)
2. **T+1min**: Call `pause()` via multi-sig owner
3. **T+5min**: Deploy new primary validator infrastructure
4. **T+10min**: Call `setPrimaryValidator(newAddress)`
5. **T+15min**: Call `unpause()`

**User fund safety:**
- Funds in PROCESSING state: Safe (attacker needs secondary too)
- Funds in NEW state: Safe (no fulfillment possible while paused)
- Expired intents: User can always refund via `refundIntent()`

### Infrastructure Recommendations

| Component | Recommendation |
|-----------|----------------|
| Primary Validator Key | Hardware Security Module (HSM) |
| Secondary Validator Keys | Separate HSMs, geographically distributed |
| Contract Owner | Multi-sig (e.g., 2-of-3 Safe) |
| Admin Operations | Time-lock (24h delay for critical changes) |
| Monitoring | Real-time alerts for unusual patterns |

### Additional Security Measures

1. **Rate Limiting**: Max fulfillment amount per hour
2. **Velocity Checks**: Alert on sudden volume spikes
3. **Validator Diversity**: Secondaries run by different parties
4. **Regular Key Rotation**: Rotate secondary keys periodically
5. **Bug Bounty**: Incentivize responsible disclosure

### Contract Security

- ReentrancyGuard on all state-changing functions
- Checks-Effects-Interactions pattern
- SafeERC20 for token transfers
- Deadline validation before any action
- Intent hash uniqueness (includes nonce)
- No external calls in loops (gas griefing prevention)

## Upgradeability

### UUPS Proxy Pattern

```solidity
contract RozoBridgeInterface is
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // Implementation
}
```

**What can be upgraded:**
- Validator logic (change from 1+1 to M-of-N)
- Fee calculation
- New features (batch processing, etc.)

**What cannot change:**
- Existing intent data (storage layout must be compatible)
- User funds (always withdrawable)

### Migration Path

To change validator model in the future:

1. Deploy new implementation with new validator logic
2. Call `upgradeTo(newImplementation)`
3. Configure new validators
4. No fund migration needed (same contract address)

## Supported Tokens

### Source Chain Input
- Any ERC20 token
- Native token (ETH, etc.) via `msg.value`

### Destination Chain Output
- Specified by `tokenOut` and `amountOut`
- Relayer responsible for providing correct token

## Contract Files

```
contracts/
├── RozoBridgeInterface.sol      # Main contract (upgradeable)
├── RozoIntentContract.sol       # Per-intent address contract
├── RozoIntentFactory.sol        # CREATE2 factory for intent addresses
├── RozoTypes.sol                # Structs and enums
├── interfaces/
│   └── IRozoBridgeInterface.sol # Interface
└── libraries/
    └── SignatureVerifier.sol    # EIP-712 signature verification
```

## Future Enhancements

1. **Batch Operations** - Process multiple intents in one tx
2. **M-of-N Validators** - More decentralized validation
3. **Optimistic Mode** - Challenge-based validation for lower gas
4. **Cross-chain Messaging** - Wormhole/LayerZero for validator consensus
5. **Relayer Staking** - Economic security for larger amounts
