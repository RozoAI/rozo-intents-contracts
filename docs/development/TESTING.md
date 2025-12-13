# RozoIntents Testing Guide

This guide covers testing strategies, test cases, and mock data for RozoIntents contracts.

## Testing Overview

| Test Type | Scope | Tools |
|-----------|-------|-------|
| Unit Tests | Individual functions | Foundry (EVM), cargo test (Stellar) |
| Integration Tests | Cross-function flows | Foundry fork tests |
| E2E Tests | Cross-chain flows | Testnet deployment |

---

## Unit Tests

### createIntent Tests

```solidity
function test_createIntent_success() public {
    bytes32 intentId = keccak256("test-intent-1");

    // Approve tokens
    token.approve(address(rozoIntents), 1000e6);

    // Create intent
    rozoIntents.createIntent(
        intentId,
        address(token),
        1000e6,                                    // sourceAmount
        1500,                                      // destinationChainId (Stellar)
        bytes32(uint256(uint160(stellarToken))),  // destinationToken
        receiverBytes32,                           // receiver
        995e6,                                     // destinationAmount
        uint64(block.timestamp + 1 hours),         // deadline
        address(this),                             // refundAddress
        address(0)                                 // relayer (open intent)
    );

    // Verify
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.PENDING));
}

function test_createIntent_revert_duplicateId() public {
    bytes32 intentId = keccak256("test-intent-1");

    // Create first intent
    _createTestIntent(intentId);

    // Second creation should revert
    vm.expectRevert(IntentAlreadyExists.selector);
    _createTestIntent(intentId);
}

function test_createIntent_revert_insufficientBalance() public {
    bytes32 intentId = keccak256("test-intent-1");

    // No token balance
    vm.expectRevert();
    rozoIntents.createIntent(...);
}
```

### fillAndNotify Tests (Destination Chain)

```solidity
function test_fillAndNotify_success() public {
    // Create intent on source chain first
    IntentData memory intentData = _createTestIntentData();

    // Relayer approves tokens on destination chain
    vm.prank(relayer);
    destinationToken.approve(address(rozoIntentsDestination), intentData.destinationAmount);

    // Relayer fills on destination chain
    vm.prank(relayer);
    rozoIntentsDestination.fillAndNotify(
        intentData,
        bytes32(uint256(uint160(relayer))),  // repaymentAddress (relayer's source chain address)
        0                                      // messengerId (0=Rozo)
    );

    // Verify fill is recorded
    bytes32 fillHash = keccak256(abi.encode(intentData));
    (address recordedRelayer,) = rozoIntentsDestination.filledIntents(fillHash);
    assertEq(recordedRelayer, relayer);
}

function test_fillAndNotify_revert_notAssignedRelayer() public {
    // Create intent with specific assigned relayer
    IntentData memory intentData = _createTestIntentData();
    intentData.relayer = bytes32(uint256(uint160(assignedRelayer)));

    // Different relayer tries to fill
    vm.prank(otherRelayer);
    vm.expectRevert(NotAssignedRelayer.selector);
    rozoIntentsDestination.fillAndNotify(intentData, repaymentAddress, 0);
}

function test_fillAndNotify_revert_expired() public {
    IntentData memory intentData = _createTestIntentData();

    // Warp past deadline
    vm.warp(intentData.deadline + 1);

    vm.prank(relayer);
    vm.expectRevert(IntentExpired.selector);
    rozoIntentsDestination.fillAndNotify(intentData, repaymentAddress, 0);
}

function test_fillAndNotify_revert_alreadyFilled() public {
    IntentData memory intentData = _createTestIntentData();

    // First fill succeeds
    vm.prank(relayer);
    rozoIntentsDestination.fillAndNotify(intentData, repaymentAddress, 0);

    // Second fill reverts
    vm.prank(relayer);
    vm.expectRevert(AlreadyFilled.selector);
    rozoIntentsDestination.fillAndNotify(intentData, repaymentAddress, 0);
}
```

### notify Tests (Source Chain)

```solidity
function test_notify_success() public {
    bytes32 intentId = _createTestIntent();

    // Compute expected fillHash
    Intent storage intent = rozoIntents.intents(intentId);
    bytes32 fillHash = _computeFillHash(intent);

    // Build payload (4 parameters: intentId, fillHash, repaymentAddress, relayer)
    bytes memory payload = abi.encode(
        intentId,
        fillHash,
        bytes32(uint256(uint160(relayer))),        // repaymentAddress
        bytes32(uint256(uint160(relayer)))         // relayer
    );

    // Prepare messageData for adapter
    bytes memory messageData = _prepareMessageData(payload);

    // Call notify via messenger adapter
    vm.prank(address(rozoAdapter));
    rozoIntents.notify(0, STELLAR_CHAIN_ID, messageData);

    // Verify status changed to FILLED
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.FILLED));

    // Verify relayer received payment (sourceAmount - protocolFee)
    assertEq(token.balanceOf(relayer), 1000e6 - protocolFee);
}

function test_notify_setsFailed_onFillHashMismatch() public {
    bytes32 intentId = _createTestIntent();

    // Build payload with wrong fillHash
    bytes memory payload = abi.encode(
        intentId,
        bytes32(uint256(12345)),                   // Wrong fillHash!
        bytes32(uint256(uint160(relayer))),
        bytes32(uint256(uint160(relayer)))
    );

    bytes memory messageData = _prepareMessageData(payload);

    vm.prank(address(rozoAdapter));
    rozoIntents.notify(0, STELLAR_CHAIN_ID, messageData);

    // Should be FAILED due to fillHash mismatch
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.FAILED));
}

function test_notify_revert_invalidMessenger() public {
    bytes32 intentId = _createTestIntent();

    bytes memory messageData = abi.encode(...);

    // Invalid messengerId
    vm.expectRevert(InvalidMessenger.selector);
    rozoIntents.notify(99, STELLAR_CHAIN_ID, messageData);
}

function test_notify_revert_alreadyFilled() public {
    bytes32 intentId = _createTestIntent();
    bytes32 fillHash = _computeFillHash(rozoIntents.intents(intentId));

    bytes memory payload = abi.encode(intentId, fillHash, repaymentAddress, relayerBytes32);
    bytes memory messageData = _prepareMessageData(payload);

    // First notify succeeds
    vm.prank(address(rozoAdapter));
    rozoIntents.notify(0, STELLAR_CHAIN_ID, messageData);

    // Second notify reverts (status no longer PENDING)
    vm.prank(address(rozoAdapter));
    vm.expectRevert();
    rozoIntents.notify(0, STELLAR_CHAIN_ID, messageData);
}
```

### refund Tests

```solidity
function test_refund_success() public {
    bytes32 intentId = _createTestIntent();

    // Warp past deadline
    vm.warp(block.timestamp + 2 hours);

    uint256 balanceBefore = token.balanceOf(sender);

    rozoIntents.refund(intentId);

    // Verify full refund
    assertEq(token.balanceOf(sender), balanceBefore + 1000e6);

    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.REFUNDED));
}

function test_refund_revert_notExpired() public {
    bytes32 intentId = _createTestIntent();

    // Before deadline
    vm.expectRevert(IntentNotExpired.selector);
    rozoIntents.refund(intentId);
}

function test_refund_whilePending() public {
    bytes32 intentId = _createTestIntent();

    // Intent stays PENDING (relayer never filled on destination)
    // Warp past deadline
    vm.warp(block.timestamp + 2 hours);

    // Sender can refund
    rozoIntents.refund(intentId);

    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.REFUNDED));
}
```

### Admin Tests

```solidity
function test_admin_setIntentStatus() public {
    bytes32 intentId = _createTestIntent();

    // Set to FAILED manually
    vm.prank(owner);
    rozoIntents.setIntentStatus(intentId, IntentStatus.FAILED);

    // Recover to PENDING (allow retry)
    vm.prank(owner);
    rozoIntents.setIntentStatus(intentId, IntentStatus.PENDING);

    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.PENDING));
}

function test_admin_setIntentRelayer() public {
    bytes32 intentId = _createTestIntent();

    // Admin changes relayer (for recovery scenarios)
    vm.prank(owner);
    rozoIntents.setIntentRelayer(intentId, newRelayer);

    (,,,, address recordedRelayer) = rozoIntents.intents(intentId);
    assertEq(recordedRelayer, newRelayer);
}

function test_admin_setMessengerAdapter() public {
    // Deploy new adapter
    RozoMessengerAdapter newAdapter = new RozoMessengerAdapter(trustedSigner);

    // Register adapter (auto-assigns by messengerId)
    vm.prank(owner);
    rozoIntents.setMessengerAdapter(address(newAdapter));

    // Verify adapter is registered at ID 0 (Rozo)
    assertEq(address(rozoIntents.messengerAdapters(0)), address(newAdapter));
}

function test_admin_revert_notOwner() public {
    vm.prank(randomUser);
    vm.expectRevert("Ownable: caller is not the owner");
    rozoIntents.setProtocolFee(10);
}
```

---

## Integration Tests

### Full Fast Fill Flow

```solidity
function test_fullFastFillFlow() public {
    // 1. Sender creates intent on SOURCE CHAIN
    bytes32 intentId = keccak256("integration-test-1");
    vm.prank(sender);
    token.approve(address(rozoIntents), 1000e6);

    vm.prank(sender);
    rozoIntents.createIntent(
        intentId,
        address(token),
        1000e6,
        1500,                        // destinationChainId (Stellar)
        destinationTokenBytes32,
        receiverBytes32,
        995e6,
        uint64(block.timestamp + 1 hours),
        sender,
        address(0)                   // open intent (any relayer can fill)
    );

    // 2. Build IntentData for destination chain
    IntentData memory intentData = IntentData({
        intentId: intentId,
        sender: bytes32(uint256(uint160(sender))),
        refundAddress: bytes32(uint256(uint160(sender))),
        sourceToken: bytes32(uint256(uint160(address(token)))),
        sourceAmount: 1000e6,
        sourceChainId: BASE_CHAIN_ID,
        destinationChainId: 1500,
        destinationToken: destinationTokenBytes32,
        receiver: receiverBytes32,
        destinationAmount: 995e6,
        deadline: uint64(block.timestamp + 1 hours),
        createdAt: uint64(block.timestamp),
        relayer: bytes32(0)
    });

    // 3. Relayer fills on DESTINATION CHAIN
    vm.prank(relayer);
    stellarToken.approve(address(rozoIntentsDestination), 995e6);

    bytes32 repaymentAddress = bytes32(uint256(uint160(relayer)));
    vm.prank(relayer);
    rozoIntentsDestination.fillAndNotify(intentData, repaymentAddress, 0);  // messengerId=0 (Rozo)

    // 4. Simulate messenger callback on SOURCE CHAIN
    bytes32 fillHash = keccak256(abi.encode(intentData));
    bytes memory payload = abi.encode(
        intentId,
        fillHash,
        repaymentAddress,
        bytes32(uint256(uint160(relayer)))
    );

    bytes memory messageData = _prepareMessageData(payload);
    vm.prank(address(rozoAdapter));
    rozoIntents.notify(0, 1500, messageData);

    // Verify final state
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.FILLED));
    assertEq(token.balanceOf(relayer), 1000e6 - 3e6); // minus protocol fee
}
```

### Refund After Timeout

```solidity
function test_refundAfterTimeout() public {
    bytes32 intentId = _createTestIntent();

    // Intent stays PENDING (relayer never fills on destination)
    // Time passes, deadline expires
    vm.warp(block.timestamp + 2 hours);

    // Sender refunds
    uint256 balanceBefore = token.balanceOf(sender);
    rozoIntents.refund(intentId);

    // Full refund (no fee deducted)
    assertEq(token.balanceOf(sender), balanceBefore + 1000e6);

    // Verify status
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.REFUNDED));
}
```

---

## Test Data

### Mock Intent Data

```solidity
// Standard test intent
bytes32 constant TEST_INTENT_ID = keccak256("test-intent-001");
address constant SENDER = 0x1111111111111111111111111111111111111111;
address constant RECEIVER = 0x2222222222222222222222222222222222222222;
address constant RELAYER = 0x3333333333333333333333333333333333333333;
uint256 constant SOURCE_AMOUNT = 1000e6;  // 1000 USDC (6 decimals)
uint256 constant DEST_AMOUNT = 995e6;     // 995 USDC
uint64 constant DEADLINE = 1700000000;    // Fixed timestamp for tests

// Chain IDs
uint256 constant BASE_CHAIN_ID = 8453;
uint256 constant STELLAR_CHAIN_ID = 1500;

// Helper to create bytes32 receiver
bytes32 constant RECEIVER_BYTES32 = bytes32(uint256(uint160(RECEIVER)));
```

### Mock Tokens

```solidity
// Deploy mock ERC20 for testing
MockERC20 token = new MockERC20("Mock USDC", "USDC", 6);
token.mint(sender, 10000e6);
```

### Mock Axelar Gateway

```solidity
// Simple mock for testing
contract MockAxelarGateway {
    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external pure returns (bool) {
        return true;
    }
}
```

---

## Running Tests

### EVM (Foundry)

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/RozoIntents.t.sol

# Run with verbosity
forge test -vvv

# Run with gas report
forge test --gas-report

# Run fork tests (mainnet state)
forge test --fork-url $BASE_RPC_URL
```

### Stellar (Cargo)

```bash
# Run all tests
cargo test

# Run specific test
cargo test test_create_intent

# Run with output
cargo test -- --nocapture
```

---

## Test Coverage Requirements

| Component | Minimum Coverage |
|-----------|------------------|
| createIntent | 100% |
| fill | 100% |
| notify | 100% |
| refund | 100% |
| Admin functions | 90% |

### Generate Coverage Report

```bash
# Foundry
forge coverage --report lcov

# View in browser
genhtml lcov.info -o coverage
open coverage/index.html
```

---

## E2E Testing (Testnet)

### Testnet Deployment

| Chain | Network | Faucet |
|-------|---------|--------|
| Base | Sepolia | [Base Sepolia Faucet](https://www.alchemy.com/faucets/base-sepolia) |
| Stellar | Testnet | [Stellar Friendbot](https://friendbot.stellar.org) |

### E2E Test Script

```bash
# 1. Deploy to testnets
./scripts/deploy-testnet.sh

# 2. Configure cross-chain
./scripts/configure-testnet.sh

# 3. Run E2E test
./scripts/e2e-test.sh

# Expected output:
# - Create intent on Base Sepolia
# - Relayer fills via fillAndNotify on Stellar testnet
# - Axelar delivers notify to Base Sepolia
# - Verify FILLED status
```

---

## Common Test Patterns

### Setup Helper

```solidity
function setUp() public {
    // Deploy contracts
    rozoIntents = new RozoIntents(owner);
    rozoIntentsDestination = new RozoIntentsDestination(owner);
    token = new MockERC20("USDC", "USDC", 6);

    // Deploy messenger adapters
    rozoAdapter = new RozoMessengerAdapter(trustedSigner);
    axelarAdapter = new AxelarMessengerAdapter(axelarGateway);

    // Configure SOURCE CHAIN
    vm.startPrank(owner);
    rozoIntents.setMessengerAdapter(address(rozoAdapter));     // ID 0 (Rozo)
    rozoIntents.setMessengerAdapter(address(axelarAdapter));   // ID 1 (Axelar)
    rozoIntents.setTrustedContract("stellar", stellarContract);
    rozoIntents.addRelayer(relayer, 1);  // RelayerType.ROZO
    rozoIntents.setProtocolFee(3);       // 3 bps
    vm.stopPrank();

    // Configure DESTINATION CHAIN
    vm.startPrank(owner);
    rozoIntentsDestination.setMessengerAdapter(address(rozoAdapter));
    rozoIntentsDestination.setMessengerAdapter(address(axelarAdapter));
    rozoIntentsDestination.addRelayer(relayer, 1);
    vm.stopPrank();

    // Fund sender
    token.mint(sender, 10000e6);
}
```

### Intent Creation Helper

```solidity
function _createTestIntent() internal returns (bytes32) {
    return _createTestIntent(keccak256(abi.encodePacked(block.timestamp, msg.sender)));
}

function _createTestIntent(bytes32 intentId) internal returns (bytes32) {
    vm.startPrank(sender);
    token.approve(address(rozoIntents), SOURCE_AMOUNT);
    rozoIntents.createIntent(
        intentId,
        address(token),
        SOURCE_AMOUNT,
        1500,                  // destinationChainId (Stellar)
        DEST_TOKEN_BYTES32,
        RECEIVER_BYTES32,
        DEST_AMOUNT,
        uint64(block.timestamp + 1 hours),
        sender,
        address(0)             // open intent (any relayer can fill)
    );
    vm.stopPrank();
    return intentId;
}

function _createTestIntentData() internal view returns (IntentData memory) {
    return IntentData({
        intentId: keccak256(abi.encodePacked(block.timestamp, msg.sender)),
        sender: bytes32(uint256(uint160(sender))),
        refundAddress: bytes32(uint256(uint160(sender))),
        sourceToken: bytes32(uint256(uint160(address(token)))),
        sourceAmount: SOURCE_AMOUNT,
        sourceChainId: BASE_CHAIN_ID,
        destinationChainId: 1500,
        destinationToken: DEST_TOKEN_BYTES32,
        receiver: RECEIVER_BYTES32,
        destinationAmount: DEST_AMOUNT,
        deadline: uint64(block.timestamp + 1 hours),
        createdAt: uint64(block.timestamp),
        relayer: bytes32(0)
    });
}

function _prepareMessageData(bytes memory payload) internal view returns (bytes memory) {
    // Prepare message data for Rozo adapter (includes signature)
    bytes32 sourceContract = bytes32(uint256(uint160(address(rozoIntentsDestination))));
    bytes32 messageHash = keccak256(abi.encodePacked(1500, sourceContract, payload));
    bytes memory signature = _signMessage(messageHash, trustedSignerPrivateKey);
    return abi.encode(sourceContract, payload, signature);
}
```

---

## See Also

### Design
- [DESIGN.md](../design/DESIGN.md) - Architecture overview
- [DATA_STRUCTURES.md](../design/DATA_STRUCTURES.md) - Contract interfaces

### Development
- [DEPLOYMENT.md](./DEPLOYMENT.md) - Deployment guide
- [RELAYER.md](./RELAYER.md) - Relayer guide
