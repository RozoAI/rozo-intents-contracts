# RozoIntents Data Structures

See also:
- [TERMINOLOGY.md](./TERMINOLOGY.md) - Field definitions and naming conventions
- [FEE.md](./FEE.md) - Fee structure and calculations

## Token Decimals

Different chains use different decimals for the same token:

| Chain | USDC Decimals | USDT Decimals |
|-------|---------------|---------------|
| Ethereum | 6 | 6 |
| Base | 6 | 6 |
| Arbitrum | 6 | 6 |
| Polygon | 6 | 6 |
| Stellar | 7 | 7 |
| Solana | 6 | 6 |

**Important:** The `amount` field in `RozoIntent` uses decimals based on `intentType`:
- `EXACT_IN`: Amount is in **source chain token decimals**
- `EXACT_OUT`: Amount is in **destination chain token decimals**

## Core Structs

### IntentType (Enum)

```solidity
enum IntentType {
    EXACT_IN,      // 0 - Amount is source amount (in source token decimals)
    EXACT_OUT      // 1 - Amount is destination amount (in destination token decimals)
}
```

**Default:** `EXACT_IN`

### RozoIntent

The intent definition - used for CREATE2 address computation. Does NOT include sender or source token (unknown until deposit).

```solidity
struct RozoIntent {
    // Destination chain info
    uint256 destinationChainId;      // Destination chain ID (e.g., 1500 for Stellar)
    bytes32 receiver;                // Recipient address (bytes32 for cross-chain)
    bytes32 destinationToken;        // Token on destination (bytes32 for non-EVM)

    // Amount (meaning depends on intentType)
    uint256 amount;                  // EXACT_IN: source amount, EXACT_OUT: destination amount
    IntentType intentType;           // Determines which chain's decimals to use

    // Metadata
    address refundAddress;           // Where to refund if expired
    uint256 nonce;                   // Unique identifier
    uint256 deadline;                // Expiration timestamp (default: 24h)
}
```

**Field Details:**

| Field | Type | Description |
|-------|------|-------------|
| `destinationChainId` | uint256 | Target chain ID (e.g., 1500 for Stellar) |
| `receiver` | bytes32 | Recipient on destination (bytes32 for non-EVM) |
| `destinationToken` | bytes32 | Token to receive (bytes32 for non-EVM) |
| `amount` | uint256 | Fixed amount (decimals based on intentType) |
| `intentType` | IntentType | EXACT_IN or EXACT_OUT |
| `refundAddress` | address | Where to send funds if expired |
| `nonce` | uint256 | Unique per refundAddress |
| `deadline` | uint256 | Unix timestamp when intent expires |

### Amount Decimals by IntentType

```
┌─────────────────────────────────────────────────────────────┐
│  EXACT_IN: Amount in SOURCE chain decimals                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Example: Send 100 USDC from Base to Stellar                │
│                                                             │
│  amount = 100_000_000  (100 USDC in 6 decimals - Base)      │
│  intentType = EXACT_IN                                      │
│                                                             │
│  User deposits: 100 USDC on Base (6 decimals)               │
│  Receiver gets: ~99.7 USDC on Stellar (7 decimals)          │
│                 = 997_000_000 in Stellar decimals           │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  EXACT_OUT: Amount in DESTINATION chain decimals            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Example: Receiver gets exactly 100 USDC on Stellar         │
│                                                             │
│  amount = 1_000_000_000  (100 USDC in 7 decimals - Stellar) │
│  intentType = EXACT_OUT                                     │
│                                                             │
│  Receiver gets: exactly 100 USDC on Stellar (7 decimals)    │
│  User deposits: ~100.3 USDC on Base (6 decimals)            │
│                 = 100_300_000 in Base decimals              │
│                                                             │
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

On-chain storage for each intent. Populated during execution.

```solidity
struct IntentStorage {
    IntentStatus status;             // Current state

    // Intent metadata (copied from RozoIntent for refund)
    address refundAddress;           // Where to refund if expired
    uint256 deadline;                // When intent expires

    // Source info (unknown until deposit)
    address sender;                  // Who deposited
    address sourceToken;             // What token was deposited
    uint256 sourceAmount;            // How much was deposited (in source decimals)

    // Execution info
    address processor;               // Relayer who fulfilled (v2: who locked)
    bytes32 fulfillmentTxHash;       // Destination tx hash (after validation)
}
```

**Why separate from RozoIntent?**
- `sender` - Unknown until someone deposits (for CREATE2 flow)
- `sourceToken` - User can deposit any token, relayer swaps if needed
- `sourceAmount` - Actual deposited amount (may differ for EXACT_OUT)
- `refundAddress`, `deadline` - Copied from RozoIntent so refund() works with just intentHash

## Validation Structs

### FulfillmentProof

Data that validators sign to confirm relayer paid on destination.

```solidity
struct FulfillmentProof {
    bytes32 intentHash;              // keccak256(abi.encode(intent))
    bytes32 destinationTxHash;       // Transaction hash on destination chain
    uint256 amountPaid;              // Actual amount paid (in destination decimals)
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

// Protocol fee in basis points (e.g., 3 = 0.03%)
uint256 public protocolFeeBps;

// Accumulated fees per token
mapping(address => uint256) public accumulatedFees;
```

## Intent Hash Calculation

Intent hash is computed from `RozoIntent` only (no sender/sourceToken):

```solidity
function getIntentHash(RozoIntent calldata intent) public pure returns (bytes32) {
    return keccak256(abi.encode(
        intent.destinationChainId,
        intent.receiver,
        intent.destinationToken,
        intent.amount,
        intent.intentType,
        intent.refundAddress,
        intent.nonce,
        intent.deadline
    ));
}
```

## Intent Address Calculation (CREATE2)

Address is deterministic based on intent parameters only:

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

**Note:** `sender` and `sourceToken` are NOT part of the address calculation. This allows:
- User to deposit any token
- Address to be computed before anyone deposits

## Events

```solidity
// Intent created via createIntent() or startIntent()
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
    bytes32 destinationTxHash,
    uint256 amountPaid
);

// Intent expired
event IntentExpired(
    bytes32 indexed intentHash
);

// Intent refunded to user
event IntentRefunded(
    bytes32 indexed intentHash,
    address indexed refundAddress,
    address token,
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
error InvalidIntentType();
error ZeroAmount();
error ZeroAddress();
```
