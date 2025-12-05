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

**Destination chain does NOT store intents.** It only:
1. Receives `fillAndNotify()` calls from relayers
2. Executes token transfers
3. Sends Axelar messages back to source chain

```solidity
contract RozoIntentsDestination {
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

## Intent Struct

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
    address relayer;            // Who filled (set on fill())
}
```

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

### Notes

- **`intentId`**: Must be unique. Frontend generates as `keccak256(abi.encodePacked(uuid))` or similar.
- **`bytes32` addresses**: Cross-chain addresses use `bytes32` for compatibility. EVM addresses are left-padded with zeros.
- **`destinationAmount`**: Frontend calculates based on fees. For Fast Fill: relayer fills if spread is profitable. For Slow Fill: `sourceAmount - destinationAmount` goes to protocol.
- **`deadline`**: Recommended: 30 minutes to 24 hours from creation. Too short = no relayer fills. Too long = funds locked.
- **`refundAddress`**: If not provided, defaults to `sender`. Used for both RozoIntents refund and CCTP refund (SlowFill).

---

## Intent Status

```solidity
enum IntentStatus {
    NEW,      // 0 - Created, waiting for fill
    FILLING,  // 1 - Relayer called fill(), awaiting confirmation
    FILLED,   // 2 - Completed (via notify or slowFill)
    FAILED,   // 3 - Fill verification failed (admin must investigate)
    REFUNDED  // 4 - Sender refunded after deadline
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
createIntent() ──► NEW
                    │
        ┌───────────┼───────────┬───────────┐
        │           │           │           │
    fill()      slowFill()   refund()    notify()
        │           │        (deadline)  (no fill())
        ▼           │           │           │
    FILLING         │           │           │
        │           │           │           │
    notify()        │           │           │
     │    │         │           │           │
     │    │         │           │           │
     ▼    ▼         ▼           ▼           ▼
  FILLED FAILED   FILLED    REFUNDED     FILLED
```

**Key points:**
- SlowFill skips FILLING state (NEW → FILLED directly)
- Refund allowed from NEW or FILLING after deadline
- `notify()` can work on NEW status (if relayer skipped `fill()`)
- `notify()` sets FAILED if payload doesn't match intent

### Admin Recovery from FAILED

```
FAILED ──► admin setIntentStatus() ──► NEW (retry)
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
  - `fill()` will revert if `block.timestamp >= deadline`
  - `slowFill()` will revert if `block.timestamp >= deadline`
  - `refund()` only allowed after `block.timestamp >= deadline`

### Deadline Validation

```solidity
// In fill() and slowFill()
require(block.timestamp < intent.deadline, "Intent expired");

// In refund()
require(block.timestamp >= intent.deadline, "Not expired yet");
```

---

## notify Payload

When Axelar delivers a fill confirmation, the payload contains 5 parameters:

```solidity
struct NotifyPayload {
    bytes32 intentId;        // Which intent was filled
    uint256 amountPaid;      // Amount actually paid to receiver
    bytes32 relayer;         // Relayer address as bytes32 (who should receive payout)
    bytes32 receiver;        // Receiver address (for verification)
    bytes32 destinationToken; // Token paid (for verification)
}
```

Encoding (sent by `fillAndNotify()`):
```solidity
bytes memory payload = abi.encode(intentId, amountPaid, relayer, receiver, destinationToken);
```

### Relayer Address Encoding

All relayer addresses use `bytes32` for cross-chain compatibility:

```solidity
// EVM address → bytes32 (left-padded with zeros)
bytes32 relayerBytes = bytes32(uint256(uint160(evmAddress)));

// bytes32 → EVM address
address evmAddress = address(uint160(uint256(relayerBytes)));
```

This ensures consistent ABI whether relayer is on EVM or Stellar.

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
    address refundAddress
) external;

function fill(bytes32 intentId) external;

function notify(
    string calldata sourceChain,
    string calldata sourceContract,
    bytes calldata payload  // abi.encode(intentId, amountPaid, relayer, receiver, destinationToken)
) external;

function slowFill(bytes32 intentId) external;  // EVM only

function refund(bytes32 intentId) external;
```

### Destination Chain Functions

```solidity
function fillAndNotify(
    bytes32 intentId,
    bytes32 receiver,
    address token,
    uint256 amount,
    uint256 sourceChainId
) external;
```

#### fillAndNotify Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `intentId` | `bytes32` | Intent ID from source chain (relayer gets this from indexer) |
| `receiver` | `bytes32` | Recipient address on destination chain |
| `token` | `address` | Token to transfer on destination chain |
| `amount` | `uint256` | Amount to pay receiver (in destination chain decimals) |
| `sourceChainId` | `uint256` | Source chain ID (for Axelar callback routing) |

#### fillAndNotify Logic

**Destination contract does NOT verify intent details.** It only:
1. Executes token transfer (relayer → receiver)
2. Passes parameters to Axelar
3. **Source chain's `notify()` does all verification**

```solidity
function fillAndNotify(
    bytes32 intentId,
    bytes32 receiver,
    address token,
    uint256 amount,
    uint256 sourceChainId
) external {
    // 1. Validate caller is whitelisted relayer
    require(relayers[msg.sender], "NotRelayer");

    // 2. Transfer tokens from relayer to receiver
    //    Relayer must have approved this contract beforehand
    address receiverAddr = address(uint160(uint256(receiver)));
    IERC20(token).transferFrom(msg.sender, receiverAddr, amount);

    // 3. Build payload for source chain (pass through, no validation)
    bytes memory payload = abi.encode(
        intentId,
        amount,
        bytes32(uint256(uint160(msg.sender))),  // relayer address
        receiver,
        bytes32(uint256(uint160(token)))         // destination token
    );

    // 4. Call Axelar Gateway to send message to source chain
    string memory sourceChain = chainIdToAxelarName[sourceChainId];
    string memory sourceContract = trustedContracts[sourceChain];

    gateway.callContract(sourceChain, sourceContract, payload);

    // 5. Emit event
    emit FillAndNotifySent(intentId, msg.sender, receiver, amount);
}
```

#### Source Chain Verification (in `notify()`)

Source chain's `notify()` receives the payload and verifies:

```solidity
function notify(..., bytes calldata payload) external onlyMessenger {
    (bytes32 intentId, uint256 amountPaid, bytes32 relayer, bytes32 receiver, bytes32 destToken) =
        abi.decode(payload, (bytes32, uint256, bytes32, bytes32, bytes32));

    Intent storage intent = intents[intentId];

    // Status must be NEW or FILLING
    require(
        intent.status == IntentStatus.NEW || intent.status == IntentStatus.FILLING,
        "InvalidStatus"
    );

    // Verify all parameters match the original intent
    bool valid = true;
    valid = valid && (intent.receiver == receiver);
    valid = valid && (intent.destinationToken == destToken);
    valid = valid && (amountPaid >= intent.destinationAmount);

    // If FILLING, also verify relayer matches
    if (intent.status == IntentStatus.FILLING) {
        valid = valid && (intent.relayer == address(uint160(uint256(relayer))));
    }

    if (!valid) {
        // Set to FAILED for admin investigation
        intent.status = IntentStatus.FAILED;
        emit IntentFailed(intentId, "Verification failed");
        return;
    }

    // Mark as filled and pay relayer
    intent.status = IntentStatus.FILLED;

    // If was NEW (no fill() called), record relayer from payload
    if (intent.relayer == address(0)) {
        intent.relayer = address(uint160(uint256(relayer)));
    }

    // Calculate protocol fee (protocolFee is in bps, e.g., 3 = 0.03%)
    uint256 feeAmount = intent.sourceAmount * protocolFee / 10000;
    uint256 payout = intent.sourceAmount - feeAmount;

    // Transfer payout to relayer
    IERC20(intent.sourceToken).transfer(intent.relayer, payout);

    // Accumulate fee for admin withdrawal
    accumulatedFees[intent.sourceToken] += feeAmount;

    emit IntentFilled(intentId, intent.relayer, amountPaid);
}
```

**Key behaviors:**
- Works for both NEW and FILLING status
- If NEW: records relayer from payload
- If FILLING: verifies relayer matches the one who called `fill()`
- On mismatch: sets FAILED instead of reverting (allows admin recovery)

#### Relayer Prerequisites

Before calling `fillAndNotify()`, relayer must:

1. **Approve tokens**: Call `token.approve(RozoIntentsDestination, amount)`
2. **Have sufficient balance**: Own `amount` of `token` on destination chain
3. **Be whitelisted**: Address must be in `relayers` mapping on destination chain

#### fillAndNotify Complete Workflow

```
Relayer Workflow for fillAndNotify():

1. PREPARE
   ├── Get intent details from Rozo API or on-chain events
   ├── Verify intent is fillable (status = NEW or FILLING, not expired)
   └── Calculate if fill is profitable

2. APPROVE (if not already done)
   └── token.approve(RozoIntentsDestination, amount)

3. CALL fillAndNotify()
   ├── Input: intentId, receiver, token, amount, sourceChainId
   ├── Contract transfers: relayer → receiver
   └── Contract sends Axelar message to source chain

4. WAIT FOR AXELAR (~5-10 seconds)
   └── Axelar validators verify and relay message

5. RECEIVE PAYMENT (automatic)
   └── notify() on source chain pays relayer
```

#### Axelar Payload Format

The payload sent via Axelar Gateway:

```solidity
// Encoding (5 parameters)
bytes memory payload = abi.encode(
    intentId,           // bytes32 - which intent
    amount,             // uint256 - amount paid to receiver
    relayer,            // bytes32 - who to pay (relayer address as bytes32)
    receiver,           // bytes32 - who received payment (for verification)
    destinationToken    // bytes32 - token used (for verification)
);

// Decoding on source chain
(
    bytes32 intentId,
    uint256 amountPaid,
    bytes32 relayer,
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
| Token transfer fails | Transaction reverts | Relayer retries or abandons |
| Axelar message fails | Rare - Axelar handles | Check Axelar explorer |
| `notify()` verification fails | Status = FAILED | Admin investigates |

#### fillAndNotify Events

```solidity
event FillAndNotifySent(
    bytes32 indexed intentId,
    address indexed relayer,
    bytes32 receiver,
    uint256 amount
);
```

#### fillAndNotify Errors

```solidity
error NotRelayer();
error InvalidAmount();
error TransferFailed();
error UnsupportedSourceChain();
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
| Need to retry fill | `setIntentStatus(NEW)` |
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
    uint64 deadline
);

event IntentFilling(
    bytes32 indexed intentId,
    address indexed relayer
);

event IntentFilled(
    bytes32 indexed intentId,
    address indexed relayer,
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
error NotMessenger();
error InsufficientAmount(uint256 paid, uint256 required);
error SlowFillUnsupported();
error TransferFailed();
error InvalidFee();
error UntrustedSource();
```

### Error Reference Guide

| Error | When Triggered | How to Debug |
|-------|----------------|--------------|
| `IntentAlreadyExists` | `createIntent()` with duplicate intentId | Generate new unique intentId |
| `IntentNotFound` | Any function with non-existent intentId | Check intentId is correct, check correct chain |
| `InvalidStatus` | Function called on wrong status | Check current status via `intents[id].status` |
| `IntentExpired` | `fill()` or `slowFill()` after deadline | Intent can only be refunded now |
| `IntentNotExpired` | `refund()` before deadline | Wait until `block.timestamp >= deadline` |
| `NotRelayer` | Non-whitelisted address calls relayer function | Check `relayers[address]` mapping |
| `NotMessenger` | Non-messenger calls `notify()` | Only Axelar Gateway can call |
| `InsufficientAmount` | `amountPaid < destinationAmount` | Relayer must pay at least destinationAmount |
| `SlowFillUnsupported` | SlowFill on unsupported route | Check `slowFillBridges` mapping for route |
| `TransferFailed` | Token transfer reverts | Check token balance, allowance, or token contract |
| `InvalidFee` | `setProtocolFee()` with fee > 30 bps | Fee must be <= 30 (0.3%) |
| `UntrustedSource` | `notify()` from untrusted contract | Check `trustedContracts[chainName]` |

### Common Debugging Steps

1. **Transaction reverted with no error**
   - Check gas limit
   - Check token approval: `token.allowance(sender, RozoIntents)`
   - Check token balance

2. **Intent stuck in FILLING**
   - Check if `fillAndNotify()` was called on destination
   - Check Axelar explorer for message status
   - Wait for Axelar confirmation (~5-10 sec)

3. **Intent marked FAILED**
   - Check event logs for `IntentFailed` reason
   - Compare payload data with original intent
   - Contact admin for recovery

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
