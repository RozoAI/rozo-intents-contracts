# Messenger Design

Messengers verify cross-chain fills and deliver notifications to RozoIntents. Multiple messenger options are supported via an adapter pattern.

## Core Principle

**Security is in the adapter's verification logic, not the caller's identity.**

The adapter is a unified verification layer that proves message authenticity. Each messenger type implements its own security model (signatures, gateway validation, oracle consensus, etc.).

---

## Supported Messengers

| ID | Messenger | Speed | Security Model | Default |
|----|-----------|-------|----------------|---------|
| 0 | Rozo | ~1-3 sec | ECDSA signature from trusted signer | ✓ |
| 1 | Axelar | ~5-10 sec | 75+ independent validators via Gateway | |

**Relayers choose** which messenger to use for their repayment. Users receive funds instantly regardless of messenger choice.

---

## How It Works

1. Relayer calls `fillAndNotify()` on RozoIntents (destination chain)
2. RozoIntents contract transfers tokens from relayer to receiver (user paid instantly)
3. RozoIntents contract calls adapter's `sendMessage()` which emits an event
4. Messenger network detects event, verifies the fill, prepares proof
5. `notify()` is called on RozoIntents (source chain) with the proof
6. Adapter's `verifyMessage()` validates the proof (signature/gateway/oracle verification)
7. If verification passes, RozoIntents releases funds to relayer's repayment address

**Key:** The destination contract executes the payment, so the messenger verifies a real on-chain event - not just a relayer's claim.

---

## Messenger Adapter Pattern

Use an adapter pattern to support multiple messengers (Rozo, Axelar, LayerZero, etc.) without coupling RozoIntents to any specific implementation.

### IMessengerAdapter Interface

```solidity
interface IMessengerAdapter {
    error UntrustedSource();
    error NotApproved();
    error InvalidSignature();
    error InvalidChainId();

    /// @notice Send cross-chain notification
    function sendMessage(uint256 destinationChainId, bytes calldata payload) external returns (bytes32 messageId);

    /// @notice Verify incoming message and return decoded payload
    function verifyMessage(uint256 sourceChainId, bytes calldata messageData) external returns (bytes memory payload);

    /// @notice Messenger identifier (0=Rozo, 1=Axelar, 2=LayerZero, etc.)
    function messengerId() external pure returns (uint8);
}
```

### Benefits

- **Clean separation**: Core contract focuses on intents, adapters handle messengers
- **Extensibility**: Add messengers without modifying RozoIntents
- **Flexibility**: Relayers choose optimal messenger for their needs
- **Type-safe errors**: Adapters use custom errors instead of string reverts
- **Auto-registration**: Messenger ID pulled from adapter itself

---

## Rozo Messenger (Default)

Custom lightweight messenger for fast relayer repayment. Optimized for the specific use case of verifying cross-chain fills. Uses a single Rozo-operated relayer that monitors fill events and delivers notifications.

### Architecture

```
Destination Chain          Rozo Relayer           Source Chain
       │                        │                      │
 fillAndNotify()                │                      │
       │                        │                      │
  Emit FillEvent ─────────────► │                      │
       │                   Detect event                │
       │                   Sign message                │
       │                        │                      │
       │                        │ ────► call notify()  │
       │                        │                      │
```

### RozoMessengerAdapter Implementation

```solidity
contract RozoMessengerAdapter is IMessengerAdapter {
    address public trustedSigner;  // Rozo's signing key
    mapping(uint256 => bytes32) public trustedContracts; // chainId => contractAddress

    event MessageSent(bytes32 indexed messageId, uint256 destinationChainId, bytes payload);

    constructor(address _trustedSigner) {
        trustedSigner = _trustedSigner;
    }

    function sendMessage(uint256 destinationChainId, bytes calldata payload) external returns (bytes32) {
        if (trustedContracts[destinationChainId] == bytes32(0)) revert InvalidChainId();

        bytes32 messageId = keccak256(abi.encodePacked(
            block.chainid,
            destinationChainId,
            payload,
            block.timestamp
        ));

        emit MessageSent(messageId, destinationChainId, payload);
        return messageId;
    }

    function verifyMessage(uint256 sourceChainId, bytes calldata messageData) external view returns (bytes memory) {
        (bytes32 sourceContract, bytes memory payload, bytes memory signature) =
            abi.decode(messageData, (bytes32, bytes, bytes));

        // Verify source contract is trusted
        if (sourceContract != trustedContracts[sourceChainId]) revert UntrustedSource();

        // Verify signature from trusted Rozo signer
        bytes32 messageHash = keccak256(abi.encodePacked(
            sourceChainId,
            sourceContract,
            payload
        ));

        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        address signer = _recoverSigner(ethSignedMessageHash, signature);
        if (signer != trustedSigner) revert InvalidSignature();

        return payload;
    }

    function messengerId() external pure returns (uint8) {
        return 0;
    }

    function _recoverSigner(bytes32 ethSignedMessageHash, bytes memory signature)
        internal
        pure
        returns (address)
    {
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        return ecrecover(ethSignedMessageHash, v, r, s);
    }

    function setTrustedContract(uint256 chainId, bytes32 contractAddr) external onlyOwner {
        trustedContracts[chainId] = contractAddr;
    }

    function setTrustedSigner(address _trustedSigner) external onlyOwner {
        trustedSigner = _trustedSigner;
    }
}
```

### Why Rozo Messenger Works for This Use Case

The messenger only verifies that the relayer paid the user on the destination chain. This is a narrow, well-defined task:

1. **Relayer already paid** - By the time messenger is invoked, relayer has already transferred tokens to user
2. **Limited scope** - Only verifying fills, not arbitrary cross-chain messages
3. **One-way verification** - Simply proving a payment happened on destination chain
4. **Fallback exists** - If verification fails, admin can investigate and resolve

The risk is entirely on the relayer side. If the Rozo messenger fails or misbehaves, the worst case is the relayer doesn't get repaid (user already received funds). This makes the security requirements different from general-purpose messaging.

---

## Axelar Messenger

General-purpose cross-chain messaging with decentralized validator set. Use when relayers prefer maximum decentralization.

### AxelarMessengerAdapter Implementation

```solidity
contract AxelarMessengerAdapter is IMessengerAdapter {
    IAxelarGateway public immutable gateway;
    mapping(uint256 => string) public chainIdToAxelarName;
    mapping(string => string) public trustedContracts; // axelarChainName => contractAddress

    function sendMessage(uint256 destinationChainId, bytes calldata payload) external returns (bytes32) {
        string memory chainName = chainIdToAxelarName[destinationChainId];
        if (bytes(chainName).length == 0) revert InvalidChainId();

        string memory destContract = trustedContracts[chainName];
        if (bytes(destContract).length == 0) revert UntrustedSource();

        gateway.callContract(chainName, destContract, payload);

        return keccak256(abi.encodePacked(chainName, destContract, payload, block.timestamp));
    }

    function verifyMessage(uint256 sourceChainId, bytes calldata messageData) external returns (bytes memory) {
        (bytes32 commandId, string memory sourceChain, string memory sourceAddr, bytes memory payload) =
            abi.decode(messageData, (bytes32, string, string, bytes));

        if (!gateway.validateContractCall(commandId, sourceChain, sourceAddr, keccak256(payload))) {
            revert NotApproved();
        }

        if (keccak256(bytes(sourceAddr)) != keccak256(bytes(trustedContracts[sourceChain]))) {
            revert UntrustedSource();
        }

        return payload;
    }

    function messengerId() external pure returns (uint8) {
        return 1;
    }

    function setChainMapping(uint256 chainId, string calldata axelarName) external onlyOwner {
        chainIdToAxelarName[chainId] = axelarName;
    }

    function setTrustedContract(string calldata chainName, string calldata contractAddr) external onlyOwner {
        trustedContracts[chainName] = contractAddr;
    }
}
```

### Axelar Validation

The `gateway.validateContractCall()` is the critical security check:

| Check | Purpose |
|-------|---------|
| `msg.sender == gateway` | Ensures call comes from Axelar Gateway contract |
| `validateContractCall()` | Confirms Axelar validators approved this specific message |
| `trustedContracts[sourceChain]` | Verifies source contract is our trusted RozoIntents |

---

## Messenger Selection

Since the messenger only affects relayer repayment, the **relayer** chooses - not the user. The user receives funds instantly regardless of which messenger is used.

| Option | Repayment Speed | Security Model | Use Case |
|--------|-----------------|----------------|----------|
| Rozo (default) | ~1-3 sec | Rozo relayer network | Standard fills, faster capital cycling |
| Axelar | ~5-10 sec | 75+ independent validators | Relayers who prefer decentralized verification |

### How Relayers Choose

```solidity
// Relayer calls fillAndNotify with their preferred messenger
fillAndNotify(intentData, repaymentAddress, messengerId)

// messengerId = 0 (Rozo, default) - faster repayment
// messengerId = 1 (Axelar) - decentralized verification
```

---

## Security Comparison

| Aspect | Rozo Messenger | Axelar |
|--------|----------------|--------|
| Verification | ECDSA signature from trusted signer | 75+ independent validators |
| Trust model | Centralized (single trusted signer) | Decentralized (validator set) |
| Attack surface | Smaller (purpose-built) | Larger (general GMP) |
| Failure mode | Rozo relayer down | Axelar network congestion |
| Speed | ~1-3 seconds | ~5-10 seconds |
| Best for | Fast capital cycling | Maximum decentralization |

---

## Concern: Messenger Failure

If the messenger fails to deliver `notify()` to the source chain, the relayer cannot receive repayment:

```
Relayer fills on destination
    ↓
User receives funds (instant)
    ↓
Messenger fails to send/deliver notify()
    ↓
Deadline passes on source chain
    ↓
Intent still shows PENDING
    ↓
RESULT: Relayer paid user but cannot get repaid
```

**This affects ALL messengers** (Rozo, Axelar, any future messenger). Any messenger downtime or congestion creates this risk for relayers.

---

## Solution: Extended Deadlines + Messenger Retry

### 1. Extended Deadlines

Relayers should use sufficiently long deadlines to allow messenger time to deliver, even under adverse conditions. Recommended minimum deadline buffer: 1 hour beyond expected messenger delivery time.

### 2. Messenger Retry Mechanism

If the primary messenger fails, the relayer who originally filled the intent can retry notification via an alternative messenger on the **destination chain**.

```
Destination Chain                                        Source Chain
      │                                                       │
1. fillAndNotify(intentData, messengerId=0)                   │
   filledIntents[fillHash] stores relayer & repaymentAddr     │
   Rozo messenger fails ✗                                     │
      │                                                       │
2. Relayer detects notify() not delivered                     │
      │                                                       │
3. retryNotify(intentData, messengerId=1)                     │
   verify(msg.sender == original relayer)                     │
   Axelar messenger sends ─────────────────────────────────► notify()
      │                                                       │
      │                                                  4. status = FILLED
      │                                                     pay relayer
```

**Key points:**
- `retryNotify()` recomputes the `fillHash` from `intentData` to find the original fill record.
- It verifies that `msg.sender` was the original filler, preventing other relayers from interfering.
- The relayer can choose any registered messenger for the retry.
- The source chain is protected from double-payment because `notify()` only works on intents in `PENDING` status.

### `retryNotify` Implementation

```solidity
function retryNotify(
    IntentData calldata intentData,
    uint8 messengerId
) external {
    // 1. Recompute fillHash to find the original fill record
    bytes32 fillHash = keccak256(abi.encode(intentData));

    // 2. Verify the fill exists and the caller is the original relayer
    FillRecord storage fill = filledIntents[fillHash];
    require(fill.relayer == msg.sender, "NotRelayer");

    // 3. Get the new messenger adapter
    IMessengerAdapter adapter = messengerAdapters[messengerId];
    require(address(adapter) != address(0), "InvalidMessenger");

    // 4. Build the payload again using the stored repayment address
    bytes32 actualRelayer = bytes32(uint256(uint160(msg.sender)));
    bytes memory payload = abi.encode(
        intentData.intentId,
        fillHash,
        fill.repaymentAddress,
        actualRelayer
    );

    // 5. Send message via the new messenger
    adapter.sendMessage(intentData.sourceChainId, payload);

    emit NotificationRetried(intentData.intentId, msg.sender, fillHash, messengerId);
}
```

### 3. Double-Payment Protection

Protection exists on **both chains**:

| Chain | Protection | Prevents |
|-------|------------|----------|
| **Destination** | `filledIntents[fillHash] = true` | User receiving funds twice (double-fill) |
| **Source** | `intent.status` must be PENDING | Relayer being paid twice (from retry) |
| **Source** | Computed `fillHash` verification | Intent parameters tampering |

**Source chain verification:** The `fillHash` is recomputed from stored intent data using `_computeFillHash()` and compared against the received `fillHash`. This ensures the fill matches the original intent parameters.

---

## RozoIntents Integration

### Destination Chain

```solidity
contract RozoIntentsDestination {
    mapping(uint8 => IMessengerAdapter) public messengerAdapters;
    mapping(bytes32 => bool) public filledIntents;

    function fillAndNotify(
        IntentData calldata intentData,
        bytes32 repaymentAddress,
        uint8 messengerId // 0=Rozo (default), 1=Axelar, etc.
    ) external {
        // 1. Verify assigned relayer
        if (intentData.relayer != bytes32(0)) {
            require(bytes32(uint256(uint160(msg.sender))) == intentData.relayer, "NotAssignedRelayer");
        }

        // 2. Check double-fill
        bytes32 fillHash = keccak256(abi.encode(intentData));
        require(!filledIntents[fillHash], "AlreadyFilled");
        filledIntents[fillHash] = true;

        // 3. Transfer tokens to receiver
        address receiver = address(uint160(uint256(intentData.receiver)));
        address token = address(uint160(uint256(intentData.destinationToken)));
        IERC20(token).safeTransferFrom(msg.sender, receiver, intentData.destinationAmount);

        // 4. Get messenger adapter (default to ID 0 if not specified)
        IMessengerAdapter adapter = messengerAdapters[messengerId];
        if (address(adapter) == address(0)) revert InvalidMessenger();

        // 5. Build payload: intentId, fillHash, repaymentAddress
        bytes memory payload = abi.encode(
            intentData.intentId,
            fillHash,
            repaymentAddress
        );

        adapter.sendMessage(intentData.sourceChainId, payload);

        emit FillAndNotifySent(intentData.intentId, msg.sender, repaymentAddress, fillHash, messengerId);
    }
}
```

### Source Chain

```solidity
contract RozoIntentsSource {
    mapping(uint8 => IMessengerAdapter) public messengerAdapters;
    mapping(bytes32 => Intent) public intents;
    
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
            relayer: bytes32(uint256(uint160(intent.relayer)))
        });

        return keccak256(abi.encode(intentData));
    }

    function notify(
        uint8 messengerId,
        uint256 sourceChainId,
        bytes calldata messageData
    ) external {
        // 1. Verify adapter exists
        IMessengerAdapter adapter = messengerAdapters[messengerId];
        if (address(adapter) == address(0)) revert InvalidMessenger();

        // 2. Adapter verifies message authenticity and decodes
        bytes memory payload = adapter.verifyMessage(sourceChainId, messageData);

        // 3. Decode: intentId, fillHash, repaymentAddress
        (bytes32 intentId, bytes32 fillHash, bytes32 repaymentAddress) =
            abi.decode(payload, (bytes32, bytes32, bytes32));

        // 4. Get intent and verify state
        Intent storage intent = intents[intentId];
        if (intent.status != IntentStatus.PENDING) revert InvalidStatus();

        // 5. Recompute expected fillHash and verify
        bytes32 expectedFillHash = _computeFillHash(intent);
        if (fillHash != expectedFillHash) revert FillHashMismatch();

        // 6. Mark as filled and pay relayer
        intent.status = IntentStatus.FILLED;
        address payoutAddress = address(uint160(uint256(repaymentAddress)));

        uint256 feeAmount = (intent.sourceAmount * protocolFee) / 10000;
        uint256 payout = intent.sourceAmount - feeAmount;

        IERC20(intent.sourceToken).transfer(payoutAddress, payout);
        accumulatedFees[intent.sourceToken] += feeAmount;

        emit IntentFilled(intentId, payoutAddress, intent.destinationAmount);
    }

    function setMessengerAdapter(address adapter) external onlyOwner {
        uint8 id = IMessengerAdapter(adapter).messengerId();
        messengerAdapters[id] = IMessengerAdapter(adapter);
        emit MessengerAdapterSet(id, adapter);
    }
}
```

### Payload Security

1. **Minimal Payload**: Only `intentId`, `fillHash`, `repaymentAddress`, and `relayer` cross the messenger.
2. **Hash Verification**: Source chain recomputes `fillHash` from stored intent data and verifies match
3. **No Manipulation**: `fillHash` binds all intent parameters - any tampering will cause hash mismatch
4. **Messenger ID 0 = Default**: No need for explicit default setter - ID 0 (Rozo) is implicit default

---

## Security Model: Defense in Depth

The `notify()` function has no caller restrictions. Instead, security is ensured through multiple verification layers:

### Layer 1: Adapter Verification (Primary)

The adapter's `verifyMessage()` is where ALL security checks happen. Each messenger implements its own security model:

**Rozo Messenger:**
```solidity
function verifyMessage(...) external view returns (bytes memory) {
    // 1. Verify source contract is trusted
    if (sourceContract != trustedContracts[sourceChainId]) revert UntrustedSource();

    // 2. Verify ECDSA signature from trusted signer
    address signer = _recoverSigner(ethSignedMessageHash, signature);
    if (signer != trustedSigner) revert InvalidSignature();

    return payload;
}
```

**Axelar Messenger:**
```solidity
function verifyMessage(...) external view returns (bytes memory) {
    // 1. Verify Axelar Gateway approved message (75+ validators)
    if (!gateway.validateContractCall(...)) revert NotApproved();

    // 2. Verify source contract is trusted
    if (sourceAddr != trustedContracts[sourceChain]) revert UntrustedSource();

    return payload;
}
```

### Layer 2: FillHash Verification (Secondary)

Even if adapter verification somehow passes incorrectly, the fillHash check provides additional protection:

```solidity
// Recompute fillHash from stored intent data
bytes32 expectedFillHash = _computeFillHash(intent);

// Compare with fillHash from message
if (fillHash != expectedFillHash) revert FillHashMismatch();
```

This prevents:
- Parameter tampering (changing amounts, addresses, tokens)
- Replay attacks across different intents
- Malicious payload construction

### Layer 3: Status Check (Tertiary)

```solidity
if (intent.status != IntentStatus.PENDING) revert InvalidStatus();
```

This prevents:
- Double payment (intent already FILLED)
- Payment after refund (intent already REFUNDED)

### Attack Scenarios

| Attack | Result |
|--------|--------|
| Call `notify()` with random data | Adapter verification fails → revert |
| Replay same valid message | Status check fails on 2nd call → revert |
| Tamper with payload amounts | FillHash mismatch → revert |
| Submit before fill happens | No valid proof exists yet → verification fails |
| Front-run valid `notify()` call | Only first call succeeds, others revert → no impact |

---

## Rozo Relayer Off-Chain Logic

The Rozo relayer monitors `MessageSent` events and submits signed notifications:

```typescript
import { createPublicClient, createWalletClient, http, parseAbiItem, keccak256, encodePacked, encodeAbiParameters } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

// Monitor destination chain for MessageSent events
async function monitorFills() {
  const publicClient = createPublicClient({
    chain: destinationChain,
    transport: http()
  });

  const walletClient = createWalletClient({
    account: privateKeyToAccount(SIGNER_PRIVATE_KEY),
    chain: sourceChain,
    transport: http()
  });

  // Watch for MessageSent events
  publicClient.watchEvent({
    address: rozoAdapterAddress,
    event: parseAbiItem('event MessageSent(bytes32 indexed messageId, uint256 destinationChainId, bytes payload)'),
    onLogs: async (logs) => {
      for (const log of logs) {
        const { messageId, destinationChainId, payload } = log.args;

        // Get source contract address
        const sourceContract = await publicClient.readContract({
          address: rozoAdapterAddress,
          abi: rozoAdapterABI,
          functionName: 'trustedContracts',
          args: [destinationChainId]
        });

        // Create message hash
        const messageHash = keccak256(
          encodePacked(
            ['uint256', 'bytes32', 'bytes'],
            [destinationChainId, sourceContract, payload]
          )
        );

        // Sign message
        const signature = await walletClient.signMessage({
          message: { raw: messageHash }
        });

        // Encode messageData for notify()
        const messageData = encodeAbiParameters(
          [{ type: 'bytes32' }, { type: 'bytes' }, { type: 'bytes' }],
          [sourceContract, payload, signature]
        );

        // Submit notify() transaction
        const hash = await walletClient.writeContract({
          address: rozoIntentsSourceAddress,
          abi: rozoIntentsABI,
          functionName: 'notify',
          args: [0, destinationChainId, messageData]
        });

        console.log(`Notification submitted: ${hash}`);
      }
    }
  });
}
```

---

## Flow Diagrams

### Fast Fill with Rozo Messenger (Default)

```
Source Chain                 Destination Chain              Rozo Relayer
     │                              │                          │
1. createIntent(relayer)            │                          │
   status = PENDING                 │                          │
     │                              │                          │
     │                       2. fillAndNotify(intentData, repaymentAddress, 0)
     │                          verify: assigned relayer       │
     │                          transfer: relayer → receiver   │
     │                          emit FillEvent ───────────────►│
     │                              │                          │
     │                              │              3. Rozo relayer verifies
     │                              │                 (~1-3 seconds)
     │                              │                          │
     │◄────────────────────────────────────────────── 4. notify()
     │                              │                          │
5. status = FILLED                  │                          │
   pay relayer (repaymentAddress)   │                          │
```

### Fast Fill with Axelar Messenger

```
Source Chain                 Destination Chain              Axelar Network
     │                              │                          │
1. createIntent(relayer)            │                          │
   status = PENDING                 │                          │
     │                              │                          │
     │                       2. fillAndNotify(intentData, repaymentAddress, 1)
     │                          verify: assigned relayer       │
     │                          transfer: relayer → receiver   │
     │                          call Axelar Gateway ──────────►│
     │                              │                          │
     │                              │              3. 75+ validators verify
     │                              │                 (~5-10 seconds)
     │                              │                          │
     │◄────────────────────────────────────────────── 4. notify()
     │                              │                          │
5. status = FILLED                  │                          │
   pay relayer (repaymentAddress)   │                          │
```

---

## Trusted Contracts (Example)

| Chain | Contract |
|-------|----------|
| stellar | `RozoIntentsStellar` |
| ethereum | `RozoIntentsEthereum` |
| base | `RozoIntentsBase` |
| arbitrum | `RozoIntentsArbitrum` |

---

## Summary

1. **Adapters are unified verification layers** - Security is in the adapter's verification logic, not the caller's identity
2. **No caller restrictions on `notify()`** - The function uses adapter verification instead of `msg.sender` checks
3. **Defense in depth** - Multiple protection layers: adapter verification, fillHash verification, status checks
4. **Messenger flexibility** - Easy to add new messengers without modifying core contracts
5. **Relayer choice** - Relayers choose their preferred messenger based on speed vs decentralization tradeoffs

---

## References

- [Axelar GMP Docs](https://docs.axelar.dev/dev/general-message-passing/overview/)
- [Stellar GMP Example](https://github.com/axelarnetwork/stellar-gmp-example)
- [EIP-191: Signed Data Standard](https://eips.ethereum.org/EIPS/eip-191)
