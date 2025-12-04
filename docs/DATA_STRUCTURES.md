# RozoIntents Data Structures

See [TERMINOLOGY.md](./TERMINOLOGY.md) for field definitions and naming conventions.

## Core Structs

### IntentType (Enum)

```solidity
enum IntentType {
    EXACT_IN,      // 0 - Source amount fixed, destination receives (source - fee)
    EXACT_OUT      // 1 - Destination amount fixed, source pays (destination + fee)
}
```

**Default:** `EXACT_IN`

### RozoIntent

The intent represents a user's cross-chain payment request.

```solidity
struct RozoIntent {
    // Source chain info (contract lives on source chain)
    address sender;                  // User who created the intent
    address sourceToken;             // Token deposited (address(0) = native)
    uint256 sourceAmount;            // Amount deposited on source chain

    // Destination chain info
    uint256 destinationChainId;      // Destination chain ID (e.g., 1500 for Stellar)
    bytes32 receiver;                // Recipient address (bytes32 for cross-chain)
    bytes32 destinationToken;        // Token on destination (bytes32 for non-EVM)
    uint256 destinationAmount;       // Amount receiver should get

    // Intent configuration
    IntentType intentType;           // EXACT_IN or EXACT_OUT
    address refundAddress;           // Where to refund if expired
    uint256 nonce;                   // Unique identifier per sender
    uint256 deadline;                // Expiration timestamp (default: 24h)
}
```

**Field Details:**

| Field | Type | Description |
|-------|------|-------------|
| `sender` | address | The user initiating the payment |
| `sourceToken` | address | Token on source chain (address(0) for native ETH/etc) |
| `sourceAmount` | uint256 | Amount user deposits on source chain |
| `destinationChainId` | uint256 | Target chain ID (e.g., 1500 for Stellar) |
| `receiver` | bytes32 | Recipient on destination (bytes32 for non-EVM compatibility) |
| `destinationToken` | bytes32 | Token to receive on destination (bytes32 for non-EVM) |
| `destinationAmount` | uint256 | Amount receiver should get on destination |
| `intentType` | IntentType | EXACT_IN (default) or EXACT_OUT |
| `refundAddress` | address | Where to send funds if intent expires |
| `nonce` | uint256 | Unique per sender, prevents replay |
| `deadline` | uint256 | Unix timestamp when intent expires |

### Amount Handling by IntentType

```
EXACT_IN (default):
┌─────────────────────────────────────────────────────────────┐
│  sourceAmount = 100 USDC (user deposits this, FIXED)        │
│  fee = 0.3 USDC                                             │
│  destinationAmount = 99.7 USDC (receiver gets this)         │
│                                                             │
│  For Permit2/approve: use sourceAmount from intent          │
│  For intent address: use all balance on contract            │
└─────────────────────────────────────────────────────────────┘

EXACT_OUT:
┌─────────────────────────────────────────────────────────────┐
│  destinationAmount = 100 USDC (receiver gets this, FIXED)   │
│  fee = 0.3 USDC                                             │
│  sourceAmount = 100.3 USDC (user must deposit this)         │
│                                                             │
│  For Permit2/approve: use sourceAmount from intent          │
│  For intent address: use all balance on contract            │
└─────────────────────────────────────────────────────────────┘
```

### IntentStatus (Enum)

```solidity
enum IntentStatus {
    NEW,           // 0 - User deposited, waiting for relayer
    PROCESSING,    // 1 - Relayer locked intent (multi-relayer mode)
    PROCESSED,     // 2 - Fulfilled and claimed by relayer
    EXPIRED,       // 3 - Deadline passed, awaiting refund
    REFUNDED       // 4 - User received refund
}
```

### IntentStorage

On-chain storage for each intent.

```solidity
struct IntentStorage {
    IntentStatus status;             // Current state
    address processor;               // Relayer who locked/fulfilled (address(0) if none)
    address sourceToken;             // Token deposited
    uint256 amountDeposited;         // Actual amount received on source chain
    bytes32 fulfillmentTxHash;       // Destination tx hash (set after fulfillment)
    uint256 deadline;                // Copied from intent for refund checks
}
```

## Validation Structs

### FulfillmentProof

Data that validators sign to confirm relayer paid on destination.

```solidity
struct FulfillmentProof {
    bytes32 intentHash;              // keccak256(abi.encode(intent))
    bytes32 destinationTxHash;       // Transaction hash on destination chain
    uint256 amountPaid;              // Actual amount paid to receiver
    uint256 timestamp;               // When validator verified the payment
}
```

### EIP-712 Domain

```solidity
bytes32 constant DOMAIN_TYPEHASH = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
);

// Domain separator
bytes32 DOMAIN_SEPARATOR = keccak256(abi.encode(
    DOMAIN_TYPEHASH,
    keccak256("RozoIntents"),
    keccak256("1"),
    block.chainid,
    address(this)
));
```

### FulfillmentProof TypeHash

```solidity
bytes32 constant FULFILLMENT_TYPEHASH = keccak256(
    "FulfillmentProof(bytes32 intentHash,bytes32 destinationTxHash,uint256 amountPaid,uint256 timestamp)"
);
```

## Storage Mappings

```solidity
// Intent hash => Intent storage
mapping(bytes32 => IntentStorage) public intents;

// Primary validator address
address public primaryValidator;

// Secondary validators (any one can co-sign with primary)
mapping(address => bool) public secondaryValidators;

// Protocol fee in basis points (e.g., 30 = 0.3%)
uint256 public protocolFeeBps;

// Accumulated fees per token
mapping(address => uint256) public accumulatedFees;
```

## Intent Hash Calculation

```solidity
function getIntentHash(RozoIntent calldata intent) public pure returns (bytes32) {
    return keccak256(abi.encode(
        intent.sender,
        intent.sourceToken,
        intent.sourceAmount,
        intent.destinationChainId,
        intent.receiver,
        intent.destinationToken,
        intent.destinationAmount,
        intent.intentType,
        intent.refundAddress,
        intent.nonce,
        intent.deadline
    ));
}
```

## Intent Address Calculation (CREATE2)

```solidity
function getIntentAddress(RozoIntent calldata intent) public view returns (address) {
    bytes32 intentHash = getIntentHash(intent);
    bytes32 salt = intentHash;

    return Create2.computeAddress(
        salt,
        keccak256(abi.encodePacked(
            type(RozoIntentContract).creationCode,
            abi.encode(address(this), intentHash)
        ))
    );
}
```

## Events

```solidity
// Intent created (user deposited)
event IntentCreated(
    bytes32 indexed intentHash,
    address indexed sender,
    address sourceToken,
    uint256 sourceAmount,
    uint256 destinationChainId,
    bytes32 receiver
);

// Intent locked by relayer (multi-relayer mode)
event IntentProcessing(
    bytes32 indexed intentHash,
    address indexed processor
);

// Intent fulfilled and claimed
event IntentFulfilled(
    bytes32 indexed intentHash,
    address indexed processor,
    bytes32 destinationTxHash
);

// Intent expired
event IntentExpired(
    bytes32 indexed intentHash
);

// Intent refunded to user
event IntentRefunded(
    bytes32 indexed intentHash,
    address indexed refundAddress,
    uint256 amount
);
```

## Errors

```solidity
error IntentAlreadyExists();
error IntentNotFound();
error IntentNotNew();
error IntentNotExpired();
error IntentAlreadyProcessed();
error IntentDeadlinePassed();
error IntentDeadlineNotPassed();
error InvalidSignature();
error InvalidPrimarySignature();
error InvalidSecondarySignature();
error InsufficientDeposit();
error TransferFailed();
error Unauthorized();
```
