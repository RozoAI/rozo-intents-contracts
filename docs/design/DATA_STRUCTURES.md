# RozoIntents Data Structures

## Contract Storage (Source Chain)

```solidity
contract RozoIntents {
    // ============ Intent Storage ============
    // Intent storage
    mapping(bytes32 => Intent) public intents;

    // ============ Access Control ============
    // Relayer whitelist
    mapping(address => bool) public relayers;

    // Messenger whitelist (Axelar)
    mapping(address => bool) public messengers;

    // Owner
    address public owner;

    // ============ Cross-Chain Configuration ============
    // Trusted contracts per chain (for cross-chain verification)
    mapping(string => string) public trustedContracts;  // chainName => contractAddress

    // Chain ID to Axelar chain name mapping (REQUIRED for fillAndNotify routing)
    mapping(uint256 => string) public chainIdToAxelarName;  // e.g., 8453 => "base", 1500 => "stellar"

    // ============ SlowFill Configuration (EVM only) ============
    // SlowFill bridge adapters per route
    // key = keccak256(abi.encodePacked(destinationChainId, sourceToken, destinationToken))
    mapping(bytes32 => address) public slowFillBridges;

    // ============ Fee Configuration ============
    // Protocol fee in basis points (max 30 bps = 0.3%)
    uint256 public protocolFee;  // e.g., 3 = 0.03%

    // Accumulated fees per token (for admin withdrawal)
    mapping(address => uint256) public accumulatedFees;

    // Fee recipient (admin)
    address public feeRecipient;
}
```

## Contract Storage (Destination Chain)

Destination chain stores minimal state for fill tracking and cross-chain messaging:

```solidity
contract RozoIntentsDestination {
    // ============ Fill Tracking ============
    // Tracks filled intents to prevent double-fills
    // Key: keccak256(abi.encode(intentData, block.chainid))
    mapping(bytes32 => bool) public filledIntents;

    // ============ Access Control ============
    // Relayer whitelist
    mapping(address => bool) public relayers;

    // Trusted contracts per chain
    mapping(string => string) public trustedContracts;

    // Chain ID to Axelar chain name mapping
    mapping(uint256 => string) public chainIdToAxelarName;

    // Axelar Gateway
    IGateway public gateway;

    // Owner
    address public owner;
}
```

---

## Intent Struct (Source Chain)

```solidity
struct Intent {
    bytes32 intentId;           // Unique identifier (off-chain generated)
    address sender;             // Who created the intent
    address refundAddress;      // Where to refund if expired (usually sender)
    address sourceToken;        // Token deposited on source chain
    uint256 sourceAmount;       // Amount deposited (source chain decimals)
    uint256 destinationChainId; // Target chain ID
    bytes32 destinationToken;   // Token on destination (bytes32 for cross-chain compatibility)
    bytes32 receiver;           // Recipient on destination (bytes32 for cross-chain)
    uint256 destinationAmount;  // Minimum amount receiver expects
    uint64 deadline;            // Unix timestamp (seconds) - after this, refund allowed
    IntentStatus status;        // Current state
    address relayer;            // Assigned relayer (from RFQ) or address(0) for open intents
}
```

## IntentData Struct (Destination Chain)

The `IntentData` struct is passed to `fillAndNotify()` on the destination chain. It contains all intent parameters needed for verification and fill tracking, including the assigned relayer.

```solidity
/// @notice Intent data passed to destination chain for filling
/// @dev Mirrors the Intent struct from source chain (excludes status)
struct IntentData {
    bytes32 intentId;
    bytes32 sender;             // Source chain sender as bytes32
    bytes32 refundAddress;      // Source chain refund address as bytes32
    bytes32 sourceToken;        // Source token as bytes32
    uint256 sourceAmount;
    uint256 sourceChainId;      // Which chain created this intent
    uint256 destinationChainId;
    bytes32 destinationToken;
    bytes32 receiver;
    uint256 destinationAmount;
    uint64 deadline;
    bytes32 relayer;            // Assigned relayer as bytes32 (address(0) for open intents)
}
```

### Why IntentData?

| Aspect | intentId only | Full IntentData struct |
|--------|---------------|------------------------|
| Parameter binding | None - attacker can fill with wrong params | **All parameters bound** |
| Cross-chain replay | Vulnerable | **Protected by chainId** |
| Deadline verification | Not possible | **Can verify on destination** |
| Relayer verification | Not possible | **Can verify msg.sender matches assigned relayer** |
| Double-fill prevention | Weak - same ID, different params | **Strong - hash includes all params** |

### Fill Hash Computation

The destination chain computes a fill hash from all intent parameters to ensure uniqueness:

```solidity
bytes32 fillHash = keccak256(abi.encode(intentData, block.chainid));
```

This prevents:
- **Double-fills**: Same intent cannot be filled twice
- **Parameter tampering**: Relayer cannot change amounts/receiver
- **Cross-chain replay**: Different chainId = different hash

### Relayer Verification on Destination

When an intent has an assigned relayer (`intentData.relayer != bytes32(0)`), the destination contract verifies that `msg.sender` matches the assigned relayer:

```solidity
// If intent has assigned relayer, verify caller is that relayer
if (intentData.relayer != bytes32(0)) {
    bytes32 callerBytes32 = bytes32(uint256(uint160(msg.sender)));
    require(callerBytes32 == intentData.relayer, "NotAssignedRelayer");
}
// If relayer is address(0), any whitelisted relayer can fill (open intent)
```

This ensures:
- **RFQ-assigned intents**: Only the winning relayer from the RFQ auction can fill
- **Open intents**: Any whitelisted relayer can fill when `relayer = address(0)`

---

## createIntent Parameters

| Parameter | Type | Description | Set By | Required |
|-----------|------|-------------|--------|----------|
| `intentId` | `bytes32` | Unique ID, generated off-chain (e.g., keccak256 of UUID) | Frontend | Yes |
| `sourceToken` | `address` | Token to deposit on source chain | Frontend | Yes |
| `sourceAmount` | `uint256` | Amount to deposit (source chain decimals) | Frontend | Yes |
| `destinationChainId` | `uint256` | Target chain ID (e.g., 1500 for Stellar) | Frontend | Yes |
| `destinationToken` | `bytes32` | Token address/asset on destination | Frontend | Yes |
| `receiver` | `bytes32` | Recipient address on destination chain | User | Yes |
| `destinationAmount` | `uint256` | Minimum amount receiver expects | Frontend (calculated) | Yes |
| `deadline` | `uint64` | Unix timestamp after which refund is allowed | Frontend | Yes |
| `refundAddress` | `address` | Where to refund if expired (default: sender) | User | Optional |
| `relayer` | `address` | Assigned relayer from RFQ auction (address(0) for open) | RFQ Server | Optional |

### Notes

- **`intentId`**: Must be unique. Frontend generates as `keccak256(abi.encodePacked(uuid))` or similar.
- **`bytes32` addresses**: Cross-chain addresses use `bytes32` for compatibility. EVM addresses are left-padded with zeros.
- **`destinationAmount`**: Frontend calculates based on fees. For Fast Fill: relayer fills if spread is profitable. For Slow Fill: `sourceAmount - destinationAmount` goes to protocol.
- **`deadline`**: Recommended: 30 minutes to 24 hours from creation. Too short = no relayer fills. Too long = funds locked.
- **`refundAddress`**: If not provided, defaults to `sender`. Used for both RozoIntents refund and CCTP refund (SlowFill).
- **`relayer`**: From RFQ auction. If `address(0)`, any whitelisted relayer can fill (open intent). Destination chain verifies `msg.sender` matches this field.

---

## Intent Status

```solidity
enum IntentStatus {
    PENDING,  // 0 - Created, waiting for fill
    FILLED,   // 1 - Completed (via notify or slowFill)
    FAILED,   // 2 - Fill verification failed (admin must investigate)
    REFUNDED  // 3 - Sender refunded after deadline
}
```

**Note:** No EXPIRED status in storage. Deadline expiry is checked via `block.timestamp >= deadline`.

### FAILED Status Details

Intent is set to FAILED when `notify()` receives mismatched data:
- `receiver` in payload ≠ `intent.receiver`
- `destinationToken` in payload ≠ `intent.destinationToken`
- `amountPaid` < `intent.destinationAmount`

Admin must investigate and recover using admin functions.

### Status Transitions

```
createIntent() ──► PENDING
                     │
         ┌───────────┼───────────┐
         │           │           │
     slowFill()   refund()    notify()
         │        (deadline)     │
         │           │           │
         │           │       ┌───┴───┐
         │           │       │       │
         ▼           ▼       ▼       ▼
      FILLED     REFUNDED  FILLED  FAILED
```

**Key points:**
- SlowFill: PENDING → FILLED directly
- Refund allowed from PENDING after deadline
- `notify()` sets FAILED if payload doesn't match intent
- No FILLING state - relayer assignment happens via RFQ before createIntent

### Admin Recovery from FAILED

```
FAILED ──► admin setIntentStatus() ──► PENDING (retry)
       │                           └──► FILLED (if payment was correct)
       │
       └──► admin adminRefund() ──► REFUNDED
```

---

## Cross-Chain Address Encoding

### EVM → bytes32
```solidity
bytes32 receiver = bytes32(uint256(uint160(evmAddress)));
```

### bytes32 → EVM
```solidity
address evmAddress = address(uint160(uint256(receiver)));
```

### Stellar → bytes32
Stellar addresses (G... public keys) are 32 bytes natively. Use as-is.

> **For detailed Stellar encoding examples** (strkey decoding, token contracts, JavaScript/Rust code), see [STELLAR.md](./STELLAR.md).

---

## Intent Timing

| Parameter | Recommended | Min | Max |
|-----------|-------------|-----|-----|
| `deadline` | 1-4 hours | 10 min | 24 hours |

### Timing Considerations

- **Too short (< 10 min)**: Relayers may not have time to fill, especially during high gas periods.
- **Too long (> 24 hours)**: User funds locked unnecessarily if no relayer fills.
- **Near deadline**:
  - `fillAndNotify()` will revert if intent expired on destination
  - `slowFill()` will revert if `block.timestamp >= deadline`
  - `refund()` only allowed after `block.timestamp >= deadline`

### Deadline Validation

```solidity
// In slowFill()
require(block.timestamp < intent.deadline, "Intent expired");

// In refund()
require(block.timestamp >= intent.deadline, "Not expired yet");

// In fillAndNotify() on destination (optional but recommended)
require(block.timestamp <= intentData.deadline, "IntentExpired");
```

---

## notify Payload

When Axelar delivers a fill confirmation, the payload contains 5 parameters:

```solidity
struct NotifyPayload {
    bytes32 intentId;           // Which intent was filled
    uint256 amountPaid;         // Amount actually paid to receiver
    bytes32 repaymentAddress;   // Where to send payout on source chain
    bytes32 receiver;           // Receiver address (for verification)
    bytes32 destinationToken;   // Token paid (for verification)
}
```

Encoding (sent by `fillAndNotify()`):
```solidity
bytes memory payload = abi.encode(intentId, amountPaid, repaymentAddress, receiver, destinationToken);
```

### Repayment Address

The `repaymentAddress` field solves the cross-chain address mismatch problem:

- Relayer fills on destination chain (e.g., Stellar with G... address)
- Relayer specifies their source chain address (e.g., EVM 0x... address) as `repaymentAddress`
- Source chain's `notify()` pays to `repaymentAddress`, not derived from destination address

```solidity
// EVM repayment address → bytes32 (left-padded with zeros)
bytes32 repaymentBytes = bytes32(uint256(uint160(evmRepaymentAddress)));

// bytes32 → EVM address for payout
address payoutAddress = address(uint160(uint256(repaymentBytes)));
```

---

## Function Signatures

### Source Chain Functions

```solidity
function createIntent(
    bytes32 intentId,
    address sourceToken,
    uint256 sourceAmount,
    uint256 destinationChainId,
    bytes32 destinationToken,
    bytes32 receiver,
    uint256 destinationAmount,
    uint64 deadline,
    address refundAddress,
    address relayer           // From RFQ auction, or address(0) for open intent
) external;

function notify(
    string calldata sourceChain,
    string calldata sourceContract,
    bytes calldata payload  // abi.encode(intentId, amountPaid, repaymentAddress, receiver, destinationToken)
) external;

function slowFill(bytes32 intentId) external;  // EVM only

function refund(bytes32 intentId) external;
```

### Destination Chain Functions

```solidity
function fillAndNotify(
    IntentData calldata intentData,
    bytes32 repaymentAddress     // Relayer's address on source chain for payout
) external;
```

#### fillAndNotify Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `intentData` | `IntentData` | Full intent data from source chain (see IntentData struct) |
| `repaymentAddress` | `bytes32` | Relayer's address on source chain where payout should be sent |

#### fillAndNotify Logic

```solidity
function fillAndNotify(
    IntentData calldata intentData,
    bytes32 repaymentAddress
) external onlyWhitelistedRelayer {
    // 1. Verify we're on the correct destination chain
    require(intentData.destinationChainId == block.chainid, "WrongChain");

    // 2. Optional: Check deadline hasn't passed
    require(block.timestamp <= intentData.deadline, "IntentExpired");

    // 3. Verify caller is assigned relayer (if intent has one)
    if (intentData.relayer != bytes32(0)) {
        bytes32 callerBytes32 = bytes32(uint256(uint160(msg.sender)));
        require(callerBytes32 == intentData.relayer, "NotAssignedRelayer");
    }
    // If relayer is bytes32(0), any whitelisted relayer can fill

    // 4. Compute fill hash from ALL intent parameters + destination chainId
    bytes32 fillHash = keccak256(abi.encode(intentData, block.chainid));

    // 5. Check if already filled (prevents double-fill attacks)
    require(!filledIntents[fillHash], "AlreadyFilled");
    filledIntents[fillHash] = true;

    // 6. Convert bytes32 to address for destination chain operations
    address receiver = address(uint160(uint256(intentData.receiver)));
    address token = address(uint160(uint256(intentData.destinationToken)));

    // 7. Transfer tokens from relayer to receiver
    IERC20(token).safeTransferFrom(msg.sender, receiver, intentData.destinationAmount);

    // 8. Build payload for source chain
    bytes memory payload = abi.encode(
        intentData.intentId,
        intentData.destinationAmount,
        repaymentAddress,                              // Relayer's source chain address
        intentData.receiver,
        intentData.destinationToken
    );

    // 9. Call Axelar Gateway to send message to source chain
    string memory sourceChain = chainIdToAxelarName[intentData.sourceChainId];
    string memory sourceContract = trustedContracts[sourceChain];

    gateway.callContract(sourceChain, sourceContract, payload);

    // 10. Emit event
    emit FillAndNotifySent(
        intentData.intentId,
        msg.sender,
        repaymentAddress,
        intentData.destinationAmount
    );
}
```

#### Source Chain Verification (in `notify()`)

Source chain's `notify()` receives the payload and verifies:

```solidity
function notify(..., bytes calldata payload) external onlyMessenger {
    (bytes32 intentId, uint256 amountPaid, bytes32 repaymentAddress, bytes32 receiver, bytes32 destToken) =
        abi.decode(payload, (bytes32, uint256, bytes32, bytes32, bytes32));

    Intent storage intent = intents[intentId];

    // Status must be PENDING
    require(intent.status == IntentStatus.PENDING, "InvalidStatus");

    // Verify all parameters match the original intent
    bool valid = true;
    valid = valid && (intent.receiver == receiver);
    valid = valid && (intent.destinationToken == destToken);
    valid = valid && (amountPaid >= intent.destinationAmount);

    if (!valid) {
        // Set to FAILED for admin investigation
        intent.status = IntentStatus.FAILED;
        emit IntentFailed(intentId, "Verification failed");
        return;
    }

    // Mark as filled
    intent.status = IntentStatus.FILLED;

    // Record relayer address (for tracking/analytics)
    address payoutAddress = address(uint160(uint256(repaymentAddress)));
    intent.relayer = payoutAddress;

    // Calculate protocol fee (protocolFee is in bps, e.g., 3 = 0.03%)
    uint256 feeAmount = intent.sourceAmount * protocolFee / 10000;
    uint256 payout = intent.sourceAmount - feeAmount;

    // Transfer payout to relayer's repayment address
    IERC20(intent.sourceToken).transfer(payoutAddress, payout);

    // Accumulate fee for admin withdrawal
    accumulatedFees[intent.sourceToken] += feeAmount;

    emit IntentFilled(intentId, payoutAddress, amountPaid);
}
```

**Key behaviors:**
- Works for PENDING status only
- Pays to `repaymentAddress` from payload (solves cross-chain address mismatch)
- Relayer verification happens on destination chain (not source) via `intentData.relayer`
- On mismatch: sets FAILED instead of reverting (allows admin recovery)

#### Relayer Prerequisites

Before calling `fillAndNotify()`, relayer must:

1. **Get IntentData**: From `IntentCreated` event or Rozo API
2. **Verify assignment**: If `intentData.relayer != bytes32(0)`, only assigned relayer can fill
3. **Approve tokens**: Call `token.approve(RozoIntentsDestination, amount)`
4. **Have sufficient balance**: Own `amount` of `token` on destination chain
5. **Be whitelisted**: Address must be in `relayers` mapping on destination chain
6. **Know repayment address**: Their address on source chain for receiving payout

#### fillAndNotify Complete Workflow

```
Relayer Workflow for fillAndNotify():

1. PREPARE
   ├── Get IntentData from Rozo API or IntentCreated event
   ├── Verify intent is fillable (status = PENDING, not expired)
   ├── Verify you are the assigned relayer (if intentData.relayer != 0)
   ├── Verify not already filled on destination (check filledIntents)
   └── Calculate if fill is profitable

2. APPROVE (if not already done)
   └── token.approve(RozoIntentsDestination, amount)

3. CALL fillAndNotify()
   ├── Input: intentData, repaymentAddress (your source chain address)
   ├── Contract verifies you are assigned relayer (if applicable)
   ├── Contract verifies fill hash uniqueness
   ├── Contract transfers: relayer → receiver
   └── Contract sends Axelar message to source chain

4. WAIT FOR AXELAR (~5-10 seconds)
   └── Axelar validators verify and relay message

5. RECEIVE PAYMENT (automatic)
   └── notify() on source chain pays to repaymentAddress
```

#### Axelar Payload Format

The payload sent via Axelar Gateway:

```solidity
// Encoding (5 parameters)
bytes memory payload = abi.encode(
    intentId,           // bytes32 - which intent
    amount,             // uint256 - amount paid to receiver
    repaymentAddress,   // bytes32 - relayer's source chain address for payout
    receiver,           // bytes32 - who received payment (for verification)
    destinationToken    // bytes32 - token used (for verification)
);

// Decoding on source chain
(
    bytes32 intentId,
    uint256 amountPaid,
    bytes32 repaymentAddress,
    bytes32 receiver,
    bytes32 destinationToken
) = abi.decode(payload, (bytes32, uint256, bytes32, bytes32, bytes32));
```

#### Gas Payment

| Action | Who Pays | Chain |
|--------|----------|-------|
| `fillAndNotify()` call | Relayer | Destination |
| Token transfer | Relayer (via contract) | Destination |
| Axelar message fee | Relayer (included in call) | Destination |
| `notify()` execution | Axelar (prepaid) | Source |
| Relayer payout transfer | Contract | Source |

**Note:** Axelar message fees are paid in native token on destination chain. Fee amount depends on destination chain gas prices.

#### Failure Handling

| Failure Point | Result | Recovery |
|---------------|--------|----------|
| Not assigned relayer | Transaction reverts "NotAssignedRelayer" | Only assigned relayer can fill |
| Already filled (fillHash exists) | Transaction reverts "AlreadyFilled" | None needed - already filled |
| Token transfer fails | Transaction reverts | Relayer retries or abandons |
| Axelar message fails | Rare - Axelar handles | Check Axelar explorer |
| `notify()` verification fails | Status = FAILED | Admin investigates |

#### fillAndNotify Events

```solidity
event FillAndNotifySent(
    bytes32 indexed intentId,
    address indexed relayer,         // Who called fillAndNotify (destination address)
    bytes32 repaymentAddress,        // Where payout goes (source chain address)
    uint256 amount
);
```

#### fillAndNotify Errors

```solidity
error NotRelayer();
error NotAssignedRelayer();
error WrongChain();
error IntentExpired();
error AlreadyFilled();
error InvalidAmount();
error TransferFailed();
error UnsupportedSourceChain();
```

---

## Stellar Implementation

### IntentData Struct (Soroban/Rust)

```rust
/// Intent data passed to destination chain for filling
/// Mirrors the Intent struct from source chain (excludes status)
#[contracttype]
#[derive(Clone)]
pub struct IntentData {
    pub intent_id: BytesN<32>,
    pub sender: BytesN<32>,          // Source chain sender as bytes32
    pub refund_address: BytesN<32>,  // Source chain refund address as bytes32
    pub source_token: BytesN<32>,    // Source token as bytes32
    pub source_amount: i128,
    pub source_chain_id: u64,
    pub destination_chain_id: u64,
    pub destination_token: Address,  // Stellar token contract
    pub receiver: Address,           // Stellar receiver address
    pub destination_amount: i128,
    pub deadline: u64,
    pub relayer: BytesN<32>,         // Assigned relayer as bytes32 (zero for open intents)
}
```

### Fill Hash Computation (Soroban)

```rust
/// Compute fill hash from all intent parameters
/// This binds the fill to exact parameters and prevents tampering
fn compute_fill_hash(env: &Env, intent_data: &IntentData) -> BytesN<32> {
    let mut data = soroban_sdk::Bytes::new(env);

    // Append all intent fields
    data.append(&soroban_sdk::Bytes::from_slice(env, &intent_data.intent_id.to_array()));
    data.append(&soroban_sdk::Bytes::from_slice(env, &intent_data.sender.to_array()));
    data.append(&soroban_sdk::Bytes::from_slice(env, &intent_data.refund_address.to_array()));
    data.append(&soroban_sdk::Bytes::from_slice(env, &intent_data.source_token.to_array()));
    data.append(&Self::i128_to_bytes(env, intent_data.source_amount));
    data.append(&Self::u64_to_bytes(env, intent_data.source_chain_id));
    data.append(&Self::u64_to_bytes(env, intent_data.destination_chain_id));
    data.append(&intent_data.destination_token.to_bytes());
    data.append(&intent_data.receiver.to_bytes());
    data.append(&Self::i128_to_bytes(env, intent_data.destination_amount));
    data.append(&Self::u64_to_bytes(env, intent_data.deadline));
    data.append(&soroban_sdk::Bytes::from_slice(env, &intent_data.relayer.to_array()));

    env.crypto().sha256(&data)
}
```

### Relayer Verification (Soroban)

```rust
// Verify caller is assigned relayer (if intent has one)
let zero_relayer = BytesN::from_array(env, &[0u8; 32]);
if intent_data.relayer != zero_relayer {
    let caller_bytes = Self::address_to_bytes32(env, &env.invoker());
    if caller_bytes != intent_data.relayer {
        return Err(Error::NotAssignedRelayer);
    }
}
// If relayer is zero, any whitelisted relayer can fill
```

### Storage Keys (Soroban)

```rust
#[contracttype]
pub enum DataKey {
    FilledIntent(BytesN<32>),  // fill_hash => bool
    Relayers,
    Gateway,
    TrustedContract(String),
    ChainIdToAxelarName(u64),
}
```

---

## Admin Functions

```solidity
// ============ Fee Management ============
function setFeeRecipient(address recipient) external onlyOwner;
function setProtocolFee(uint256 feeBps) external onlyOwner;  // max 30 bps
function withdrawFees(address token) external;  // only feeRecipient

// ============ Relayer Management ============
function addRelayer(address relayer) external onlyOwner;
function removeRelayer(address relayer) external onlyOwner;

// ============ Cross-Chain Configuration ============
function setTrustedContract(string calldata chainName, string calldata contractAddress) external onlyOwner;
function setMessenger(address messenger, bool allowed) external onlyOwner;

// Chain ID to Axelar name mapping (REQUIRED for cross-chain routing)
function setChainIdToAxelarName(uint256 chainId, string calldata axelarName) external onlyOwner;

// ============ SlowFill Bridge Configuration (EVM only) ============
function setSlowFillBridge(
    uint256 destinationChainId,
    address sourceToken,
    bytes32 destinationToken,
    address bridgeAdapter
) external onlyOwner;

function removeSlowFillBridge(
    uint256 destinationChainId,
    address sourceToken,
    bytes32 destinationToken
) external onlyOwner;

// ============ Intent Recovery (for FAILED status) ============
function setIntentStatus(bytes32 intentId, IntentStatus status) external onlyOwner;
function setIntentRelayer(bytes32 intentId, address relayer) external onlyOwner;
function adminRefund(bytes32 intentId) external onlyOwner;
```

### Required Configuration After Deployment

| Function | Purpose | Example |
|----------|---------|---------|
| `setChainIdToAxelarName` | Maps chain IDs to Axelar names for message routing | `setChainIdToAxelarName(1500, "stellar")` |
| `setTrustedContract` | Whitelists remote contracts | `setTrustedContract("stellar", "C...")` |
| `setMessenger` | Allows Axelar Gateway to call `notify()` | `setMessenger(axelarGateway, true)` |
| `addRelayer` | Whitelists relayer addresses | `addRelayer(0x...)` |
| `setSlowFillBridge` | Enables SlowFill routes (EVM only) | `setSlowFillBridge(42161, USDC, USDC_bytes32, adapter)` |

### Admin Recovery Scenarios

| Scenario | Admin Action |
|----------|--------------|
| Wrong relayer recorded | `setIntentRelayer()` then `setIntentStatus(FILLED)` |
| Payment was correct but marked FAILED | `setIntentStatus(FILLED)` |
| Need to retry fill | `setIntentStatus(PENDING)` |
| Stuck intent, need refund | `adminRefund()` |

---

## Events

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
    address relayer              // Assigned relayer from RFQ (address(0) if open)
);

event IntentFilled(
    bytes32 indexed intentId,
    address indexed relayer,     // Relayer's repayment address on source chain
    uint256 amountPaid
);

event IntentFailed(
    bytes32 indexed intentId,
    string reason
);

event IntentRefunded(
    bytes32 indexed intentId,
    address indexed refundAddress,
    uint256 amount
);

event SlowFillTriggered(
    bytes32 indexed intentId,
    bytes32 bridgeMessageId,
    address indexed caller
);

// Destination chain events
event FillAndNotifySent(
    bytes32 indexed intentId,
    address indexed relayer,         // Destination chain relayer address
    bytes32 repaymentAddress,        // Source chain payout address
    uint256 amount
);

// Admin events
event IntentStatusChanged(
    bytes32 indexed intentId,
    IntentStatus oldStatus,
    IntentStatus newStatus,
    address indexed admin
);

event IntentRelayerChanged(
    bytes32 indexed intentId,
    address oldRelayer,
    address newRelayer,
    address indexed admin
);
```

---

## Error Codes

```solidity
error IntentAlreadyExists();
error IntentNotFound();
error InvalidStatus(IntentStatus current, IntentStatus expected);
error IntentExpired();
error IntentNotExpired();
error NotRelayer();
error NotAssignedRelayer();
error NotMessenger();
error InsufficientAmount(uint256 paid, uint256 required);
error SlowFillUnsupported();
error TransferFailed();
error InvalidFee();
error UntrustedSource();
error WrongChain();
error AlreadyFilled();
```

### Error Reference Guide

| Error | When Triggered | How to Debug |
|-------|----------------|--------------|
| `IntentAlreadyExists` | `createIntent()` with duplicate intentId | Generate new unique intentId |
| `IntentNotFound` | Any function with non-existent intentId | Check intentId is correct, check correct chain |
| `InvalidStatus` | Function called on wrong status | Check current status via `intents[id].status` |
| `IntentExpired` | `fillAndNotify()` or `slowFill()` after deadline | Intent can only be refunded now |
| `IntentNotExpired` | `refund()` before deadline | Wait until `block.timestamp >= deadline` |
| `NotRelayer` | Non-whitelisted address calls relayer function | Check `relayers[address]` mapping |
| `NotAssignedRelayer` | Wrong relayer tries to fill assigned intent | Only assigned relayer can fill; check `intentData.relayer` |
| `NotMessenger` | Non-messenger calls `notify()` | Only Axelar Gateway can call |
| `InsufficientAmount` | `amountPaid < destinationAmount` | Relayer must pay at least destinationAmount |
| `SlowFillUnsupported` | SlowFill on unsupported route | Check `slowFillBridges` mapping for route |
| `TransferFailed` | Token transfer reverts | Check token balance, allowance, or token contract |
| `InvalidFee` | `setProtocolFee()` with fee > 30 bps | Fee must be <= 30 (0.3%) |
| `UntrustedSource` | `notify()` from untrusted contract | Check `trustedContracts[chainName]` |
| `WrongChain` | `fillAndNotify()` on wrong destination chain | Check `intentData.destinationChainId` matches |
| `AlreadyFilled` | `fillAndNotify()` for already-filled intent | Intent already filled, check `filledIntents` |

### Common Debugging Steps

1. **Transaction reverted with no error**
   - Check gas limit
   - Check token approval: `token.allowance(sender, RozoIntents)`
   - Check token balance

2. **Intent stuck in PENDING**
   - Check if `fillAndNotify()` was called on destination
   - Check Axelar explorer for message status
   - Wait for Axelar confirmation (~5-10 sec)

3. **Intent marked FAILED**
   - Check event logs for `IntentFailed` reason
   - Compare payload data with original intent
   - Contact admin for recovery

4. **"AlreadyFilled" error on destination**
   - Intent was already filled by another relayer
   - Check `filledIntents[fillHash]` mapping
   - This is expected behavior - first filler wins

5. **"NotAssignedRelayer" error**
   - Intent has a specific relayer assigned via RFQ
   - Only that relayer can fill this intent
   - Check `intentData.relayer` field

---

## See Also

### Design
- [DESIGN.md](./DESIGN.md) - Architecture overview
- [GLOSSARY.md](./GLOSSARY.md) - Terms and definitions
- [FUND_FLOW.md](./FUND_FLOW.md) - Fund movement
- [SLOWFILLED.md](./SLOWFILLED.md) - SlowFill details
- [STELLAR.md](./STELLAR.md) - Stellar address/token encoding

### Development
- [DEPLOYMENT.md](../development/DEPLOYMENT.md) - Deployment guide
- [TESTING.md](../development/TESTING.md) - Testing guide
