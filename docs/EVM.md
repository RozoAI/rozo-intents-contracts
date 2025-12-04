# RozoIntents EVM Implementation

This document covers EVM-specific implementation details, including CREATE2 intent addresses.

## Overview

The EVM contracts are deployed on source chains (Base, Ethereum, Arbitrum, etc.) to receive user deposits and pay out relayers after fulfillment validation.

## CREATE2 Intent Addresses

CREATE2 allows computing deterministic contract addresses before deployment. This enables users to deposit funds to an address that doesn't exist yet.

### How It Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CREATE2 FLOW (API Users)                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. User calls Rozo API                                                     │
│     POST /create-payment                                                    │
│     {                                                                       │
│       "destination": { "chainId": "1500", "receiver": "G...", ... },        │
│       "amount": "100000000",                                                │
│       "type": "exactIn"                                                     │
│     }                                                                       │
│                                                                             │
│  2. API creates RozoIntent struct, computes CREATE2 address                 │
│     intentAddress = CREATE2(salt=intentHash, bytecode=RozoIntentContract)   │
│                                                                             │
│  3. API returns intent address to user                                      │
│     { "intentAddress": "0x7a3b...f2c1" }                                    │
│                                                                             │
│  4. User transfers ANY token to intent address                              │
│     (Contract doesn't exist yet, but address can receive ERC20/native)      │
│                                                                             │
│  5. API detects deposit, notifies relayer                                   │
│                                                                             │
│  6. Relayer pays receiver on destination chain                              │
│                                                                             │
│  7. Relayer calls startIntent() + fulfillIntent()                           │
│     - startIntent(): Deploys intent contract via CREATE2, pulls funds      │
│     - fulfillIntent(): Validates signatures, transfers to relayer          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### CREATE2 Address Computation

```solidity
// Intent address is computed from:
// 1. Factory address (RozoBridgeInterface)
// 2. Salt (intentHash)
// 3. Bytecode of RozoIntentContract

function getIntentAddress(RozoIntent calldata intent) public view returns (address) {
    bytes32 intentHash = getIntentHash(intent);

    return Create2.computeAddress(
        intentHash,  // salt
        keccak256(abi.encodePacked(
            type(RozoIntentContract).creationCode,
            abi.encode(address(this), intentHash)
        ))
    );
}

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

### Why CREATE2?

| Benefit | Description |
|---------|-------------|
| **Deterministic** | Address can be computed off-chain before deployment |
| **Gas efficient** | Contract only deployed when needed (by relayer) |
| **Simple UX** | User just transfers to address, no contract interaction |
| **Any token** | User can deposit any ERC20 or native token |
| **Isolated funds** | Each intent has its own address |

### RozoIntentContract (Minimal)

```solidity
contract RozoIntentContract {
    address public immutable mainContract;
    bytes32 public immutable intentHash;

    constructor(address _mainContract, bytes32 _intentHash) {
        mainContract = _mainContract;
        intentHash = _intentHash;
    }

    /// @notice Release funds to main contract (only callable by main contract)
    function release(address token) external {
        require(msg.sender == mainContract, "Unauthorized");

        if (token == address(0)) {
            // Native token
            payable(mainContract).transfer(address(this).balance);
        } else {
            // ERC20
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).transfer(mainContract, balance);
        }
    }

    /// @notice Receive native token
    receive() external payable {}
}
```

## API-Triggered Flow

The CREATE2 flow is triggered by the API, not directly via contract. This simplifies the process:

### API Responsibilities

| Step | API Does |
|------|----------|
| 1 | Receives payment request from user |
| 2 | Generates nonce (unique per order) |
| 3 | Computes intent hash and CREATE2 address |
| 4 | Returns intent address to user |
| 5 | Monitors intent address for deposits |
| 6 | Notifies relayer when deposit detected |

### Relayer Responsibilities

| Step | Relayer Does |
|------|--------------|
| 1 | Receives notification from API |
| 2 | Pays receiver on destination chain |
| 3 | Gets validator signatures |
| 4 | Calls `startIntent()` + `fulfillIntent()` on source chain |

### One Intent Per Order

Each API order creates ONE intent with a unique nonce:

```
Order 1 → Intent (nonce=1) → Address 0xabc...
Order 2 → Intent (nonce=2) → Address 0xdef...
Order 3 → Intent (nonce=3) → Address 0x123...
```

The nonce ensures each order has a unique intent address, even if all other parameters are the same.

## Relayer Contract Interaction

### startIntent()

Deploys the intent contract (if not exists) and pulls funds:

```solidity
function startIntent(
    RozoIntent calldata intent,
    address sourceToken
) external returns (bytes32 intentHash) {
    intentHash = getIntentHash(intent);
    address intentAddress = getIntentAddress(intent);

    // Deploy intent contract if not exists
    if (intentAddress.code.length == 0) {
        new RozoIntentContract{salt: intentHash}(address(this), intentHash);
    }

    // Get balance before
    uint256 balanceBefore = _getBalance(sourceToken);

    // Pull funds from intent contract
    RozoIntentContract(intentAddress).release(sourceToken);

    // Calculate actual amount received
    uint256 sourceAmount = _getBalance(sourceToken) - balanceBefore;

    // Store intent
    intents[intentHash] = IntentStorage({
        status: IntentStatus.NEW,
        sender: address(0),  // Unknown for CREATE2 flow
        sourceToken: sourceToken,
        sourceAmount: sourceAmount,
        processor: address(0),
        fulfillmentTxHash: bytes32(0)
    });

    emit IntentCreated(intentHash, address(0), sourceToken, sourceAmount, ...);
}
```

### Combined startIntent + fulfillIntent

Relayer typically calls both in one transaction:

```solidity
// Relayer's transaction
contract RelayerHelper {
    function startAndFulfill(
        RozoIntent calldata intent,
        address sourceToken,
        bytes32 destinationTxHash,
        bytes calldata primarySig,
        bytes calldata secondarySig
    ) external {
        // Start intent (deploy + pull funds)
        bytes32 intentHash = rozoBridge.startIntent(intent, sourceToken);

        // Fulfill intent (validate + claim)
        rozoBridge.fulfillIntent(intent, destinationTxHash, primarySig, secondarySig);
    }
}
```

Or the main contract can have a combined function:

```solidity
function startAndFulfillIntent(
    RozoIntent calldata intent,
    address sourceToken,
    bytes32 destinationTxHash,
    bytes calldata primarySignature,
    bytes calldata secondarySignature
) external returns (bytes32 intentHash);
```

## Refund Flow (CREATE2)

If relayer doesn't fulfill before deadline:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           REFUND FLOW                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. Deadline passes, no fulfillment                                         │
│                                                                             │
│  2. Anyone can call refund(intentHash)                                │
│     - If intent contract not deployed: deploys it first                    │
│     - Pulls funds from intent contract                                      │
│     - Sends to refundAddress                                                │
│                                                                             │
│  3. Intent marked as REFUNDED                                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```solidity
function refund(bytes32 intentHash) external {
    IntentStorage storage stored = intents[intentHash];

    // Check deadline passed
    require(block.timestamp > intent.deadline, "Not expired");
    require(stored.status == IntentStatus.NEW, "Not refundable");

    // Deploy intent contract if needed
    address intentAddress = getIntentAddress(intent);
    if (intentAddress.code.length == 0) {
        new RozoIntentContract{salt: intentHash}(address(this), intentHash);
    }

    // Pull and send to refundAddress
    RozoIntentContract(intentAddress).release(stored.sourceToken);
    _transfer(stored.sourceToken, intent.refundAddress, stored.sourceAmount);

    stored.status = IntentStatus.REFUNDED;
    emit IntentRefunded(intentHash, intent.refundAddress, stored.sourceToken, stored.sourceAmount);
}
```

## Gas Considerations

| Operation | Estimated Gas |
|-----------|---------------|
| getIntentAddress (view) | 0 (no tx) |
| startIntent (deploy + pull) | ~150,000 |
| fulfillIntent | ~70,000 |
| startAndFulfillIntent | ~200,000 |
| refund | ~150,000 |

## Security Notes

1. **Intent address receives funds before contract exists** - This is safe because:
   - ERC20 tokens use balance mapping (address can receive without code)
   - Native token can be received by any address
   - Only the main contract can deploy and control the intent contract

2. **Salt collision** - Impossible if nonce is unique per refundAddress

3. **Front-running** - Relayer could be front-run, but:
   - Only whitelisted relayer in v1
   - processRequest() locks intent in v2

4. **Funds stuck** - If user deposits wrong token:
   - Relayer can still claim if profitable (swap)
   - Otherwise user refunds after deadline
