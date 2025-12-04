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
- [EVM.md](./EVM.md) - EVM-specific implementation (CREATE2 intent addresses)
- [FEE.md](./FEE.md) - Fee structure and calculations
- [FUND_FLOW.md](./FUND_FLOW.md) - How funds move through the system

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
4. (Or) Deadline passes → User calls `refund()`

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
| `refund()` | Used | Used |

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
| EXPIRED | REFUNDED | `refund()` | User |

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
│     [Funds ISOLATED here until relayer claims]              │
│                                                             │
│  3. Relayer detects deposit, pays receiver on destination   │
│                                                             │
│  4. Relayer calls startIntent() + fulfillIntent() in one tx │
│     - startIntent(): deploys intent contract, pulls funds   │
│     - fulfillIntent(): validates sigs, transfers to relayer │
│     Intent Address ──► Main Contract ──► Relayer (atomic)   │
└─────────────────────────────────────────────────────────────┘
```

**Who does what:**
- **User**: Just transfers tokens to intent address
- **API**: Creates RozoIntent (generates nonce, computes address), returns intent address, monitors for deposits
- **Relayer**: Receives intent params from API, calls startIntent() + fulfillIntent() after paying destination

**How intent params are conveyed:**
- API creates RozoIntent struct (destinationChainId, receiver, amount, nonce, deadline, etc.)
- API stores intent params off-chain, computes CREATE2 address
- When deposit detected, API notifies relayer with full RozoIntent data
- Relayer passes RozoIntent to startIntent() on-chain

**Use case**:
- Regular users via Rozo API
- Consumer products integrating Rozo
- Simpler UX (just send to address)

For detailed CREATE2 implementation, see [EVM.md](./EVM.md).

### Mode 2: Direct Contract Interaction (Contract Users)

For smart contracts or dApps interacting directly:

```
┌─────────────────────────────────────────────────────────────┐
│  1. User calls createIntent() directly on main contract     │
│     - With approve + transfer, OR                           │
│     - With Permit2 signature                                │
│     - Intent is registered, funds go to main contract       │
│                                                             │
│  2. Relayer detects intent, pays receiver on destination    │
│                                                             │
│  3. (v1) Relayer calls fulfillIntent() directly             │
│     (v2) Relayer calls processRequest() to lock first,      │
│          then fulfillIntent() after paying destination      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Who does what:**
- **User**: Calls createIntent() with approve/Permit2 (registers intent + deposits)
- **Relayer**: Calls fulfillIntent() after paying destination
- **No startIntent() needed**: createIntent() already registers the intent

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

// Two ways to create intent:
// 1. createIntent() - direct deposit to main contract (Contract Users)
// 2. startIntent() - pull from CREATE2 intent address (API Users)
```

For CREATE2 intent address implementation details, see [EVM.md](./EVM.md).

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
│  - Sender withdraws via refund()                      │
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
/// @dev Address is deterministic based on intent params only (no sender)
/// @dev User can send ANY token to this address
function getIntentAddress(
    RozoIntent calldata intent
) external view returns (address intentAddress);

/// @notice Create intent with standard ERC20 approve (direct deposit)
/// @dev Transfers sourceToken from sender to main contract
/// @param intent The intent parameters
/// @param sourceToken Token to deposit (what user is sending)
/// @param sourceAmount Amount to deposit (in source token decimals)
function createIntent(
    RozoIntent calldata intent,
    address sourceToken,
    uint256 sourceAmount
) external payable returns (bytes32 intentHash);

/// @notice Create intent with Permit2 (gasless approval)
/// @dev Transfers sourceToken from sender using Permit2 signature
function createIntentWithPermit2(
    RozoIntent calldata intent,
    address sourceToken,
    uint256 sourceAmount,
    bytes calldata permit2Signature
) external returns (bytes32 intentHash);

/// @notice Start intent from pre-funded intent address
/// @dev For CREATE2 flow: relayer calls this after user deposited to intent address
/// @dev Uses ALL token balance on the intent address
/// @param intent The intent parameters
/// @param sourceToken Token that was deposited to intent address
function startIntent(
    RozoIntent calldata intent,
    address sourceToken
) external returns (bytes32 intentHash);

/// @notice Refund expired intent to refundAddress
function refund(bytes32 intentHash) external;
```

**Note:** `RozoIntent` does NOT include `sender`, `sourceToken`, or `sourceAmount`. These are:
- `sender` - Set to msg.sender (createIntent) or derived from deposit (startIntent)
- `sourceToken` - Passed as parameter (user can deposit any token)
- `sourceAmount` - Passed as parameter or uses full balance (startIntent)

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
User deposits:     sourceAmount
Protocol fee:      sourceAmount * feeBps / 10000
Relayer receives:  sourceAmount - protocolFee

Example (feeBps = 3, i.e., 0.03%):
- User deposits: 1000 USDC
- Protocol fee:  1000 * 3 / 10000 = 0.3 USDC
- Relayer gets:  999.7 USDC
```

The relayer's profit comes from the spread between what they receive (999.7 USDC) and what they pay on destination.

For detailed fee structure and examples, see [FEE.md](./FEE.md).

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
- Expired intents: User can always refund via `refund()`

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
