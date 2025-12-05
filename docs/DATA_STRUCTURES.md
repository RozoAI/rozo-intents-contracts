# RozoIntents Data Structures

## Contract Storage (Source Chain)

```solidity
contract RozoIntents {
    // Intent storage
    mapping(bytes32 => Intent) public intents;

    // Relayer whitelist
    mapping(address => bool) public relayers;

    // Messenger whitelist (Axelar)
    mapping(address => bool) public messengers;

    // Trusted contracts per chain (for cross-chain verification)
    mapping(string => string) public trustedContracts;  // chainName => contractAddress

    // Protocol fee (max 30 bps)
    uint256 public protocolFee;

    // Fee recipient (admin)
    address public feeRecipient;

    // Owner
    address public owner;
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
- **`destinationAmount`**: Frontend calculates: `sourceAmount - protocolFee - slippage`. Relayer only fills if profitable.
- **`deadline`**: Recommended: 30 minutes to 24 hours from creation. Too short = no relayer fills. Too long = funds locked.
- **`refundAddress`**: If not provided, defaults to `sender`. Used for both RozoIntents refund and CCTP refund (SlowFill).

---

## Intent Status

```solidity
enum IntentStatus {
    NEW,      // 0 - Created, waiting for fill
    FILLING,  // 1 - Relayer called fill(), awaiting confirmation
    FILLED,   // 2 - Completed (via notify or slowFill)
    REFUNDED  // 3 - Sender refunded after deadline
}
```

**Note:** No EXPIRED status in storage. Deadline expiry is checked via `block.timestamp >= deadline`.

### Status Transitions

```
createIntent() ──► NEW
                    │
        ┌───────────┼───────────┐
        │           │           │
    fill()      slowFill()   refund()
        │           │        (after deadline)
        ▼           │           │
    FILLING         │           │
        │           │           │
    notify()        │           │
        │           │           │
        ▼           ▼           ▼
      FILLED      FILLED    REFUNDED
```

**Key:** SlowFill skips FILLING state. Refund allowed from NEW or FILLING after deadline.

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

When Axelar delivers a fill confirmation, the payload is:

```solidity
struct NotifyPayload {
    bytes32 intentId;    // Which intent was filled
    uint256 amountPaid;  // Amount actually paid to receiver
    bytes32 relayer;     // Relayer address as bytes32 (who should receive sourceAmount)
}
```

Encoding:
```solidity
bytes memory payload = abi.encode(intentId, amountPaid, relayer);
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
    bytes calldata payload  // abi.encode(intentId, amountPaid, relayer)
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

    // Verify all parameters match the original intent
    require(intent.status == IntentStatus.FILLING, "InvalidStatus");
    require(intent.receiver == receiver, "ReceiverMismatch");
    require(intent.destinationToken == destToken, "TokenMismatch");
    require(amountPaid >= intent.destinationAmount, "InsufficientAmount");

    // Mark as filled and pay relayer
    intent.status = IntentStatus.FILLED;
    uint256 payout = intent.sourceAmount - protocolFee;
    IERC20(intent.sourceToken).transfer(address(uint160(uint256(relayer))), payout);
}
```

#### Relayer Prerequisites

Before calling `fillAndNotify()`, relayer must:

1. **Approve tokens**: Call `token.approve(RozoIntentsDestination, amount)`
2. **Have sufficient balance**: Own `amount` of `token` on destination chain
3. **Be whitelisted**: Address must be in `relayers` mapping on destination chain

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
```

---

## See Also

- [DESIGN.md](./DESIGN.md) - Architecture overview
- [TERMINOLOGY.md](./TERMINOLOGY.md) - Terms and definitions
- [FUND_FLOW.md](./FUND_FLOW.md) - Fund movement
- [SLOWFILLED.md](./SLOWFILLED.md) - SlowFill details
