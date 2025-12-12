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

    // Messenger adapters (supports multiple messengers via adapter pattern)
    mapping(uint8 => IMessengerAdapter) public messengerAdapters;  // messengerId => adapter (0=Rozo, 1=Axelar)

    // ============ Fee Configuration ============
    // Protocol fee in basis points (max 30 bps = 0.3%)
    uint256 public protocolFee;  // e.g., 3 = 0.03%

    // Accumulated fees per token (for admin withdrawal)
    mapping(address => uint256) public accumulatedFees;

    // Fee recipient (admin)
    address public feeRecipient;

    // ============ Rozo Relayer Fallback ============
    // Address of the Rozo relayer, which can fill intents if the assigned relayer fails
    address public rozoRelayer;

    // The threshold after which the Rozo relayer is allowed to fill an intent
    uint256 public rozoRelayerThreshold; // e.g., 10 seconds
}
```

## Contract Storage (Destination Chain)

Destination chain stores minimal state for fill tracking and cross-chain messaging:

```solidity
contract RozoIntentsDestination {
    // ============ Fill Tracking ============
    // Tracks filled intents with relayer and repayment address for retries
    // Key: keccak256(abi.encode(intentData))
    // Value: FillRecord containing relayer info and repayment address
    mapping(bytes32 => FillRecord) public filledIntents;

    // ============ Access Control ============
    // Relayer whitelist
    mapping(address => bool) public relayers;

    // Trusted contracts per chain
    mapping(string => string) public trustedContracts;

    // Messenger adapters (supports multiple messengers via adapter pattern)
    mapping(uint8 => IMessengerAdapter) public messengerAdapters;  // messengerId => adapter (0=Rozo, 1=Axelar)

    // Owner
    address public owner;

    // ============ Rozo Relayer Fallback ============
    // Address of the Rozo relayer, which can fill intents if the assigned relayer fails
    address public rozoRelayer;

    // The threshold after which the Rozo relayer is allowed to fill an intent
    uint256 public rozoRelayerThreshold; // e.g., 10 seconds
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
    uint64 createdAt;           // Timestamp of intent creation for fallback logic
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
    uint64 createdAt;           // Timestamp of intent creation for fallback logic
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
bytes32 fillHash = keccak256(abi.encode(intentData));
```

This prevents:
- **Double-fills**: Same intent cannot be filled twice
- **Parameter tampering**: Relayer cannot change amounts/receiver
- **Cross-chain replay**: Different chainId = different hash

## FillRecord Struct (Destination Chain)

The `FillRecord` struct stores metadata about fills to enable the messenger retry mechanism when the initial messenger fails to deliver the notification.

```solidity
/// @notice Fill record stored on destination chain for retries
/// @dev Used to track who performed the fill and where to send payout
struct FillRecord {
    address relayer;              // Who performed the fill (original relayer address on destination chain)
    bytes32 repaymentAddress;     // Where to send payout on source chain (relayer's source chain address)
}
```

### FillRecord Purpose and Usage

The `FillRecord` struct solves a critical problem in the cross-chain fill process:

**The Problem:**
If a relayer calls `fillAndNotify()` on the destination chain and the messenger fails to deliver the `notify()` message to the source chain, the relayer gets stuck—they've already paid the user but can't be repaid.

**The Solution:**
`FillRecord` enables the **messenger retry mechanism** via the `retryNotify()` function. When the primary messenger fails, the original relayer can call `retryNotify()` with an alternative messenger, and the contract will:
1. Verify the caller is the original relayer (using `fill.relayer == msg.sender`)
2. Retrieve the stored repayment address (`fill.repaymentAddress`)
3. Resend the notification via the new messenger

### FillRecord Storage Lifecycle

```solidity
// 1. Created in fillAndNotify()
bytes32 fillHash = keccak256(abi.encode(intentData));
filledIntents[fillHash] = FillRecord({
    relayer: msg.sender,                    // Original relayer on destination chain
    repaymentAddress: repaymentAddress      // Relayer's address on source chain
});

// 2. Accessed in retryNotify()
FillRecord storage fill = filledIntents[fillHash];
require(fill.relayer == msg.sender, "NotRelayer");      // Only original relayer can retry

// 3. Used to rebuild payload with correct repayment address
bytes memory payload = abi.encode(
    intentData.intentId,
    fillHash,
    fill.repaymentAddress,      // Uses stored address (same as original fill)
    actualRelayer
);
```

### FillRecord Security Features

| Protection | How FillRecord Helps |
|------------|----------------------|
| **Only original relayer can retry** | `fill.relayer == msg.sender` authorization check |
| **Correct repayment address** | Uses stored `fill.repaymentAddress` instead of requiring it again |
| **Prevention of griefing** | Other relayers cannot interfere with retry attempts |
| **Consistent payload** | Retries use the exact same repayment address as original fill |

### Relayer Verification on Destination

When an intent has an assigned relayer (`intentData.relayer != bytes32(0)`), the destination contract verifies that `msg.sender` is either the assigned relayer or the Rozo fallback relayer after a specified threshold.

```solidity
// On the destination chain, new state variables are needed for the fallback logic
address public rozoRelayer;
uint256 public rozoRelayerThreshold; // e.g., 10 seconds

// If intent has assigned relayer, verify caller is the assigned relayer OR the Rozo fallback relayer after the threshold
if (intentData.relayer != bytes32(0)) {
    bytes32 callerBytes32 = bytes32(uint256(uint160(msg.sender)));
    bool isAssignedRelayer = (callerBytes32 == intentData.relayer);
    
    // The Rozo relayer can fill if the configured threshold has passed since intent creation
    bool isRozoFallback = (callerBytes32 == bytes32(uint256(uint160(rozoRelayer))) &&
                           block.timestamp > intentData.createdAt + rozoRelayerThreshold);

    require(isAssignedRelayer || isRozoFallback, "NotAuthorizedRelayer");
}
// If relayer is address(0), any whitelisted relayer can fill (open intent)
```

This ensures:
- **RFQ-assigned intents**: Only the winning relayer from the RFQ auction can fill within the `rozoRelayerThreshold` window.
- **Rozo Relayer Fallback**: If the assigned relayer fails to act, the `rozoRelayer` can fill the intent after the threshold, providing a fulfillment guarantee.
- **Open intents**: Any whitelisted relayer can fill when `relayer = address(0)`.

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
- **`destinationAmount`**: Frontend calculates based on fees. Relayer fills if spread is profitable.
- **`deadline`**: Recommended: 30 minutes to 24 hours from creation. Too short = no relayer fills. Too long = funds locked.
- **`refundAddress`**: If not provided, defaults to `sender`.
- **`relayer`**: From RFQ auction. If `address(0)`, any whitelisted relayer can fill (open intent). Destination chain verifies `msg.sender` matches this field.

---

## Intent Status

```solidity
enum IntentStatus {
    PENDING,  // 0 - Created, waiting for fill
    FILLED,   // 1 - Completed (via notify)
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
         ┌───────────┴───────────┐
         │                       │
      refund()                notify()
      (deadline)                 │
         │                   ┌───┴───┐
         │                   │       │
         ▼                   ▼       ▼
      REFUNDED            FILLED  FAILED
```

**Key points:**
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
  - `refund()` only allowed after `block.timestamp >= deadline`

### Deadline Validation

```solidity
// In refund()
require(block.timestamp >= intent.deadline, "Not expired yet");

// In fillAndNotify() on destination (optional but recommended)
require(block.timestamp <= intentData.deadline, "IntentExpired");
```

---

## notify Payload

When a messenger delivers a fill confirmation, the payload contains 4 parameters (minimal payload for security):

```solidity
struct NotifyPayload {
    bytes32 intentId;           // Which intent was filled
    bytes32 fillHash;           // Hash of all intent parameters (verified on source)
    bytes32 repaymentAddress;   // Where to send payout on source chain
    bytes32 relayer;            // Who performed the fill (for retry tracking)
}
```

Encoding (sent by both `fillAndNotify()` and `retryNotify()`):
```solidity
bytes memory payload = abi.encode(
    intentId,
    fillHash,
    fill.repaymentAddress,
    actualRelayer              // Current relayer (msg.sender as bytes32)
);
```

**Security:** The source chain recomputes `fillHash` from stored intent data and verifies it matches. This binds all intent parameters - any tampering will cause hash mismatch. The `relayer` field tracks who performed the fill for proper attribution in retry scenarios.

### Repayment Address

The `repaymentAddress` field solves the cross-chain address mismatch problem:

- Relayer fills on destination chain (e.g., Stellar with G... address)
- Relayer specifies their source chain address (e.g., EVM 0x... address) as `repaymentAddress`
- Messenger carries the `repaymentAddress` to source chain
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
    uint8 messengerId,
    uint256 sourceChainId,
    bytes calldata messageData  // Messenger-specific data, adapter decodes to payload
) external;

function refund(bytes32 intentId) external;
```

### Destination Chain Functions

```solidity
function fillAndNotify(
    IntentData calldata intentData,
    bytes32 repaymentAddress,    // Relayer's address on source chain for payout
    uint8 messengerId            // 0=Rozo (default), 1=Axelar
) external;
```

#### fillAndNotify Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `intentData` | `IntentData` | Full intent data from source chain (see IntentData struct) |
| `repaymentAddress` | `bytes32` | Relayer's address on source chain where payout should be sent |
| `messengerId` | `uint8` | Messenger to use for notification (0=Rozo default, 1=Axelar) |

#### fillAndNotify Logic

```solidity
function fillAndNotify(
    IntentData calldata intentData,
    bytes32 repaymentAddress,
    uint8 messengerId
) external onlyWhitelistedRelayer {
    // 1. Verify we're on the correct destination chain
    if (intentData.destinationChainId != block.chainid) revert WrongChain();

    // 2. Optional: Check deadline hasn't passed
    if (block.timestamp > intentData.deadline) revert IntentExpired();

    // 3. Verify caller is assigned relayer (if intent has one)
    if (intentData.relayer != bytes32(0)) {
        bytes32 callerBytes32 = bytes32(uint256(uint160(msg.sender)));
        if (callerBytes32 != intentData.relayer) revert NotAssignedRelayer();
    }
    // If relayer is bytes32(0), any whitelisted relayer can fill

    // 4. Compute fill hash from ALL intent parameters
    bytes32 fillHash = keccak256(abi.encode(intentData));

    // 5. Check if already filled (prevents double-fill attacks)
    FillRecord storage fill = filledIntents[fillHash];
    if (fill.relayer != address(0)) revert AlreadyFilled();
    fill.relayer = msg.sender;
    fill.repaymentAddress = repaymentAddress;

    // 6. Convert bytes32 to address for destination chain operations
    address receiver = address(uint160(uint256(intentData.receiver)));
    address token = address(uint160(uint256(intentData.destinationToken)));

    // 7. Transfer tokens from relayer to receiver
    IERC20(token).safeTransferFrom(msg.sender, receiver, intentData.destinationAmount);

    // 8. Get messenger adapter
    IMessengerAdapter adapter = messengerAdapters[messengerId];
    if (address(adapter) == address(0)) revert InvalidMessenger();

    // 9. Build payload (4 parameters: intentId, fillHash, repaymentAddress, relayer)
    bytes32 actualRelayer = bytes32(uint256(uint160(msg.sender)));
    bytes memory payload = abi.encode(
        intentData.intentId,
        fillHash,
        repaymentAddress,
        actualRelayer
    );

    // 10. Send message via selected messenger
    adapter.sendMessage(intentData.sourceChainId, payload);

    // 11. Emit event
    emit FillAndNotifySent(
        intentData.intentId,
        msg.sender,
        repaymentAddress,
        fillHash,
        messengerId
    );
}
```

A new `retryNotify` function is added to the destination chain contract to handle messenger failures.

#### retryNotify Logic

If the initial messenger fails to deliver the notification, the original relayer can call `retryNotify` with the same `intentData` and a new `messengerId` to re-trigger the notification process.

```solidity
function retryNotify(
    IntentData calldata intentData,
    uint8 messengerId
) external {
    // 1. Recompute fillHash to find the original fill record
    bytes32 fillHash = keccak256(abi.encode(intentData));

    // 2. Verify the fill exists and the caller is the original relayer
    FillRecord storage fill = filledIntents[fillHash];
    if (fill.relayer != msg.sender) revert NotRelayer();

    // 3. Get the new messenger adapter
    IMessengerAdapter adapter = messengerAdapters[messengerId];
    if (address(adapter) == address(0)) revert InvalidMessenger();

    // 4. Build the payload again
    bytes32 actualRelayer = bytes32(uint256(uint160(msg.sender)));
    bytes memory payload = abi.encode(
        intentData.intentId,
        fillHash,
        fill.repaymentAddress, // Use the original repayment address
        actualRelayer
    );

    // 5. Send message via the new messenger
    adapter.sendMessage(intentData.sourceChainId, payload);

    // 6. Emit an event
    emit NotificationRetried(
        intentData.intentId,
        msg.sender,
        fillHash,
        messengerId
    );
}
```

This ensures that only the relayer who performed the initial fill can trigger a retry, preventing griefing attacks or accidental duplicate messages from other relayers. The source chain is protected from double-payment by the `intent.status` check in the `notify` function.

#### Source Chain Verification (in `notify()`)

Source chain's `notify()` receives the message and verifies via the messenger adapter:

```solidity
function notify(
    uint8 messengerId,
    uint256 sourceChainId,
    bytes calldata messageData
) external {
    // 1. Get and verify messenger adapter
    IMessengerAdapter adapter = messengerAdapters[messengerId];
    if (address(adapter) == address(0)) revert InvalidMessenger();
    if (msg.sender != address(adapter)) revert NotMessenger();

    // 2. Adapter verifies and decodes message
    bytes memory payload = adapter.verifyMessage(sourceChainId, messageData);

    // 3. Decode 4-parameter payload
    (bytes32 intentId, bytes32 fillHash, bytes32 repaymentAddress, bytes32 relayer) =
        abi.decode(payload, (bytes32, bytes32, bytes32, bytes32));

    Intent storage intent = intents[intentId];

    // 4. Status must be PENDING
    if (intent.status != IntentStatus.PENDING) revert InvalidStatus(intent.status, IntentStatus.PENDING);

    // 5. Recompute expected fillHash from stored intent data
    bytes32 expectedFillHash = _computeFillHash(intent);

    // 6. Verify fillHash matches (binds all intent parameters)
    if (fillHash != expectedFillHash) {
        intent.status = IntentStatus.FAILED;
        emit IntentFailed(intentId, "FillHashMismatch");
        return;
    }

    // 7. Mark as filled
    intent.status = IntentStatus.FILLED;

    // 8. Calculate protocol fee and payout
    address payoutAddress = address(uint160(uint256(repaymentAddress)));
    uint256 feeAmount = intent.sourceAmount * protocolFee / 10000;
    uint256 payout = intent.sourceAmount - feeAmount;

    // 9. Transfer payout to relayer's repayment address
    IERC20(intent.sourceToken).transfer(payoutAddress, payout);

    // 10. Accumulate fee for admin withdrawal
    accumulatedFees[intent.sourceToken] += feeAmount;

    emit IntentFilled(intentId, payoutAddress, intent.destinationAmount);
}
```

**Key behaviors:**
- Works for PENDING status only
- Messenger adapter verifies message authenticity before decoding
- Uses `fillHash` to verify all intent parameters match (no tampering possible)
- Pays to `repaymentAddress` from payload (solves cross-chain address mismatch)
- Relayer verification happens on destination chain (not source) via `intentData.relayer`
- On mismatch: sets FAILED instead of reverting (allows admin recovery)

#### _computeFillHash Implementation

The source chain recomputes the expected fill hash from the stored `Intent` struct to verify the fill:

```solidity
function _computeFillHash(Intent storage intent) internal view returns (bytes32) {
    // Reconstruct IntentData from stored Intent
    IntentData memory intentData = IntentData({
        intentId: intent.intentId,
        sender: bytes32(uint256(uint160(intent.sender))),
        refundAddress: bytes32(uint256(uint160(intent.refundAddress))),
        sourceToken: bytes32(uint256(uint160(intent.sourceToken))),
        sourceAmount: intent.sourceAmount,
        sourceChainId: block.chainid,
        destinationChainId: intent.destinationChainId,
        destinationToken: intent.destinationToken,
        receiver: intent.receiver,
        destinationAmount: intent.destinationAmount,
        deadline: intent.deadline,
        createdAt: intent.createdAt,
        relayer: bytes32(uint256(uint160(intent.relayer)))
    });

    // Hash must match what destination chain computed
    return keccak256(abi.encode(intentData));
}
```

This ensures the fill hash received from the messenger matches exactly what would be computed from the original intent parameters.

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
   ├── Calculate if fill is profitable
   └── Choose messenger (0=Rozo for speed, 1=Axelar for decentralization)

2. APPROVE (if not already done)
   └── token.approve(RozoIntentsDestination, amount)

3. CALL fillAndNotify()
   ├── Input: intentData, repaymentAddress, messengerId
   ├── Contract verifies you are assigned relayer (if applicable)
   ├── Contract verifies fill hash uniqueness
   ├── Contract transfers: relayer → receiver
   └── Contract sends message via selected messenger adapter

4. WAIT FOR MESSENGER
   ├── Rozo: ~1-3 seconds (Rozo relayer network)
   └── Axelar: ~5-10 seconds (75+ validators verify)

5. RECEIVE PAYMENT (automatic)
   └── notify() on source chain pays to repaymentAddress
```

#### Messenger Payload Format

The payload sent via messenger adapter (same format for all messengers, used by both fillAndNotify and retryNotify):

```solidity
// Encoding (4 parameters - same for both fillAndNotify and retryNotify)
bytes memory payload = abi.encode(
    intentId,               // bytes32 - which intent
    fillHash,               // bytes32 - hash of all intent parameters (verified on source)
    repaymentAddress,       // bytes32 - relayer's source chain address for payout
    actualRelayer           // bytes32 - who performed the fill (msg.sender as bytes32)
);

// Decoding on source chain
(
    bytes32 intentId,
    bytes32 fillHash,
    bytes32 repaymentAddress,
    bytes32 relayer
) = abi.decode(payload, (bytes32, bytes32, bytes32, bytes32));
```

**Security:** The `fillHash` binds all intent parameters. Source chain recomputes the expected hash from stored intent data and verifies it matches. The `relayer` field provides attribution for both initial fills and retries.

#### Gas Payment

| Action | Who Pays | Chain |
|--------|----------|-------|
| `fillAndNotify()` call | Relayer | Destination |
| Token transfer | Relayer (via contract) | Destination |
| Messenger fee | Relayer (via msg.value) | Destination |
| `notify()` execution | Messenger network | Source |
| Relayer payout transfer | Contract | Source |

**Note:** Messenger fees are paid in native token on destination chain via `msg.value`. Fee varies by messenger and destination chain gas prices.

#### Failure Handling

| Failure Point | Result | Recovery |
|---------------|--------|----------|
| Not assigned relayer | Transaction reverts "NotAssignedRelayer" | Only assigned relayer can fill |
| Already filled (fillHash exists) | Transaction reverts "AlreadyFilled" | None needed - already filled |
| Invalid messenger ID | Transaction reverts "InvalidMessenger" | Use valid messengerId (0 or 1) |
| Token transfer fails | Transaction reverts | Relayer retries or abandons |
| Messenger fails to deliver | Relayer uses `retryNotify()` | See [Messenger Failure](./MESSENGER_DESIGN.md#concern-messenger-failure) |
| `notify()` verification fails | Status = FAILED | Admin investigates |

#### fillAndNotify Events

```solidity
event FillAndNotifySent(
    bytes32 indexed intentId,
    address indexed relayer,         // Who called fillAndNotify (destination address)
    bytes32 repaymentAddress,        // Where payout goes (source chain address)
    bytes32 fillHash,                // Hash binding all intent parameters
    uint8 messengerId                // Which messenger was used (0=Rozo, 1=Axelar)
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
error InvalidMessenger();
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
    pub created_at: u64,             // Timestamp of intent creation for fallback logic
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
    data.append(&Self::u64_to_bytes(env, intent_data.created_at));
    data.append(&soroban_sdk::Bytes::from_slice(env, &intent_data.relayer.to_array()));

    env.crypto().sha256(&data)
}
```

### Relayer Verification (Soroban)

```rust
// Verify caller is assigned relayer OR the Rozo fallback relayer after a threshold
let zero_relayer = BytesN::from_array(env, &[0u8; 32]);
if intent_data.relayer != zero_relayer {
    let caller_bytes = Self::address_to_bytes32(env, &env.invoker());
    let is_assigned_relayer = caller_bytes == intent_data.relayer;

    let rozo_relayer = Self::get_rozo_relayer(env); // Assuming a getter for rozo_relayer state
    let rozo_relayer_threshold = Self::get_rozo_relayer_threshold(env); // Assuming a getter for the threshold
    let is_rozo_fallback = caller_bytes == rozo_relayer &&
                           env.ledger().timestamp() > intent_data.created_at + rozo_relayer_threshold;

    if !is_assigned_relayer && !is_rozo_fallback {
        return Err(Error::NotAuthorizedRelayer);
    }
}
// If relayer is zero, any whitelisted relayer can fill
```

### Storage Keys (Soroban)

```rust
#[contracttype]
pub enum DataKey {
    FilledIntent(BytesN<32>),  // fill_hash => bool
    Relayers, // mapping(Address => RelayerType)
    Gateway,
    TrustedContract(String),
    ChainIdToAxelarName(u64),
    RozoRelayerThreshold,
}

#[contracttype]
pub enum RelayerType {
    NONE,
    ROZO,
    EXTERNAL,
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
function setMessengerAdapter(IMessengerAdapter adapter) external onlyOwner;  // Auto-registers by messengerId

// ============ Rozo Relayer Fallback ============
function setRozoRelayer(address _rozoRelayer) external onlyOwner;
function setRozoRelayerThreshold(uint256 _threshold) external onlyOwner;

// ============ Intent Recovery (for FAILED status) ============
function setIntentStatus(bytes32 intentId, IntentStatus status) external onlyOwner;
function setIntentRelayer(bytes32 intentId, address relayer) external onlyOwner;
function adminRefund(bytes32 intentId) external onlyOwner;
```

### Required Configuration After Deployment

| Function | Purpose | Example |
|----------|---------|---------|
| `setMessengerAdapter` | Registers messenger adapters (auto-assigns by ID) | `setMessengerAdapter(rozoAdapter)` |
| `setRozoRelayer` | Sets the address of the Rozo fallback relayer | `setRozoRelayer(0x...)` |
| `setRozoRelayerThreshold` | Sets the fallback time threshold in seconds | `setRozoRelayerThreshold(10)` |
| `setTrustedContract` | Whitelists remote contracts | `setTrustedContract("stellar", "C...")` |
| `addRelayer` | Whitelists relayer addresses | `addRelayer(0x...)` |

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

### Core Protocol Errors

```solidity
// ============ Intent State Errors ============
error IntentAlreadyExists();
error IntentNotFound();
error InvalidStatus(IntentStatus current, IntentStatus expected);
error IntentExpired();
error IntentNotExpired();

// ============ Access Control Errors ============
error NotRelayer();
error NotAssignedRelayer();
error NotAuthorizedRelayer();
error NotMessenger();

// ============ Cross-Chain & Messenger Errors ============
error InvalidMessenger();
error UntrustedSource();
error WrongChain();

// ============ Fill & Payment Errors ============
error AlreadyFilled();
error FillHashMismatch();
error InsufficientAmount(uint256 paid, uint256 required);
error TransferFailed();

// ============ Fee & Configuration Errors ============
error InvalidFee();
```

### Error Categories & Reference

#### Intent State Errors

| Error | Function | When Triggered | How to Fix |
|-------|----------|----------------|-----------|
| `IntentAlreadyExists` | `createIntent()` | Duplicate intentId submitted | Generate unique intentId using `keccak256(abi.encodePacked(uuid))` |
| `IntentNotFound` | Any intent function | Non-existent intentId | Verify intentId is correct, check correct chain |
| `InvalidStatus` | `notify()` | Intent not in PENDING state | Check `intent.status` - must be PENDING for notify() to work |
| `IntentExpired` | `fillAndNotify()` | `block.timestamp > deadline` | Intent deadline passed, relayer cannot fill |
| `IntentNotExpired` | `refund()` | `block.timestamp < deadline` | Wait until deadline passes before requesting refund |

#### Access Control Errors

| Error | Function | When Triggered | Root Cause | How to Fix |
|-------|----------|----------------|-----------|-----------|
| `NotRelayer` | `retryNotify()` | `fill.relayer != msg.sender` | Caller is not the original relayer who filled the intent | Only the relayer who called fillAndNotify() can retry |
| `NotAssignedRelayer` | `fillAndNotify()` | `msg.sender != intentData.relayer` (for assigned intents) | Wrong relayer attempting to fill assigned intent | Only the relayer from RFQ auction can fill assigned intents |
| `NotAuthorizedRelayer` | `fillAndNotify()` | Neither assigned relayer nor Rozo fallback after threshold | Caller is neither the assigned relayer nor Rozo fallback | Check intentData.relayer; if set, only that relayer (or Rozo after 10s) can fill |
| `NotMessenger` | `notify()` | `msg.sender != address(adapter)` | Non-messenger contract called notify() | Only registered messenger adapters can call notify() |

#### Cross-Chain & Messenger Errors

| Error | Function | When Triggered | Root Cause | How to Fix |
|-------|----------|----------------|-----------|-----------|
| `InvalidMessenger` | `fillAndNotify()`, `retryNotify()` | `messengerAdapters[messengerId] == address(0)` | Invalid or unregistered messenger ID | Use valid messengerId: 0=Rozo (default), 1=Axelar |
| `UntrustedSource` | Adapter's `verifyMessage()` | Source contract not in trusted list | Message from unauthorized contract | Configure `trustedContracts` mapping for source chain |
| `WrongChain` | `fillAndNotify()` | `block.chainid != intentData.destinationChainId` | Called on wrong destination chain | Switch RPC to correct destination chain (e.g., Stellar, not Ethereum) |

#### Fill & Payment Errors

| Error | Function | When Triggered | Root Cause | How to Fix |
|-------|----------|----------------|-----------|-----------|
| `AlreadyFilled` | `fillAndNotify()` | `filledIntents[fillHash]` already has relayer set | Intent already filled on destination | Check blockchain explorer - intent already executed, cannot fill twice |
| `FillHashMismatch` | `notify()` (soft revert) | Computed hash ≠ received hash | Intent parameters tampered or modified | Admin investigates and manually recovers (sets intent to FILLED or PENDING) |
| `InsufficientAmount` | `fillAndNotify()` | Relayer payment < required | Relayer didn't provide enough funds | Increase relayer's payment amount to match `destinationAmount` |
| `TransferFailed` | `fillAndNotify()` | ERC-20 transfer reverted | Insufficient balance, allowance, or token contract issue | Check token balance, approve contract, or verify token is valid |

#### Fee & Configuration Errors

| Error | Function | When Triggered | How to Fix |
|-------|----------|----------------|-----------|
| `InvalidFee` | `setProtocolFee()` | Fee > 30 basis points (0.3%) | Set fee to <= 30 bps |

### Error Scenarios by Use Case

#### Relayer Workflow Error Troubleshooting

| Scenario | Likely Error | Solution |
|----------|--------------|----------|
| Intent won't fill on destination | `NotAssignedRelayer` | Verify you're the assigned relayer from RFQ (check `intentData.relayer`) |
| Intent won't fill on destination | `WrongChain` | Switch RPC to correct destination chain |
| Intent won't fill on destination | `IntentExpired` | Deadline passed; intent can no longer be filled |
| Intent won't fill on destination | `AlreadyFilled` | Another relayer already filled it; check blockchain explorer |
| Intent status stays PENDING on source | `InvalidMessenger` | Use valid messengerId (0=Rozo, 1=Axelar) |
| Intent status stays PENDING on source | Messenger down | Use `retryNotify()` with alternative messenger |
| Cannot retry notification | `NotRelayer` | Only original filler can retry; must be same msg.sender as fillAndNotify() |
| Cannot retry notification | `InvalidMessenger` | Alternative messengerId not registered |

#### Operator/Admin Debugging

| Error | Investigation | Resolution |
|-------|-------------|------------|
| Intent in FAILED status | Check `IntentFailed` event for reason | If "FillHashMismatch": parameters may have been tampered; call `setIntentStatus(FILLED)` or `adminRefund()` |
| Intent stuck PENDING after deadline | Messenger failure or late delivery | Call `retryNotify()` if fill was sent, or `refund()` if never filled |
| Double-fill detected | Investigate blockchain logs | FillRecord structure prevents this; if seen, indicates separate fills with different parameters

### Common Debugging Steps

1. **Transaction reverted with no error**
   - Check gas limit
   - Check token approval: `token.allowance(sender, RozoIntents)`
   - Check token balance

2. **Intent stuck in PENDING**
   - Check if `fillAndNotify()` was called on destination
   - Check messenger status (Rozo dashboard or Axelar explorer)
   - Wait for messenger confirmation (Rozo: ~1-3 sec, Axelar: ~5-10 sec)

3. **Intent marked FAILED**
   - Check event logs for `IntentFailed` reason
   - If "FillHashMismatch": intent parameters may have been tampered
   - Contact admin for recovery

4. **"AlreadyFilled" error on destination**
   - Intent was already filled by another relayer
   - Check `filledIntents[fillHash]` mapping
   - This is expected behavior - first filler wins

5. **"NotAssignedRelayer" error**
   - Intent has a specific relayer assigned via RFQ
   - Only that relayer can fill this intent
   - Check `intentData.relayer` field

6. **"InvalidMessenger" error**
   - Invalid messengerId provided to `fillAndNotify()`
   - Use 0 for Rozo (default) or 1 for Axelar
   - Check `messengerAdapters[id]` is registered

---

## See Also

### Design
- [DESIGN.md](./DESIGN.md) - Architecture overview
- [GLOSSARY.md](./GLOSSARY.md) - Terms and definitions
- [FUND_FLOW.md](./FUND_FLOW.md) - Fund movement
- [STELLAR.md](./STELLAR.md) - Stellar address/token encoding

### Development
- [DEPLOYMENT.md](../development/DEPLOYMENT.md) - Deployment guide
- [TESTING.md](../development/TESTING.md) - Testing guide
