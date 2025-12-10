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
        address(this)                              // refundAddress
    );

    // Verify
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.NEW));
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

### fill Tests

```solidity
function test_fill_success() public {
    bytes32 intentId = _createTestIntent();

    // Relayer fills
    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // Verify status changed
    (,, IntentStatus status,, address recordedRelayer) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.FILLING));
    assertEq(recordedRelayer, relayer);
}

function test_fill_revert_notRelayer() public {
    bytes32 intentId = _createTestIntent();

    // Non-relayer tries to fill
    vm.prank(randomUser);
    vm.expectRevert(NotRelayer.selector);
    rozoIntents.fill(intentId);
}

function test_fill_revert_expired() public {
    bytes32 intentId = _createTestIntent();

    // Warp past deadline
    vm.warp(block.timestamp + 2 hours);

    vm.prank(relayer);
    vm.expectRevert(IntentExpired.selector);
    rozoIntents.fill(intentId);
}

function test_fill_revert_wrongStatus() public {
    bytes32 intentId = _createTestIntent();

    // Fill once
    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // Try to fill again
    vm.prank(relayer2);
    vm.expectRevert();
    rozoIntents.fill(intentId);
}
```

### notify Tests

```solidity
function test_notify_success_fromFilling() public {
    bytes32 intentId = _createTestIntent();

    // Relayer fills
    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // Build payload
    bytes memory payload = abi.encode(
        intentId,
        995e6,                                     // amountPaid
        bytes32(uint256(uint160(relayer))),        // relayer
        receiverBytes32,                           // receiver
        destinationTokenBytes32                    // destToken
    );

    // Messenger calls notify
    vm.prank(axelarGateway);
    rozoIntents.notify("stellar", stellarContract, payload);

    // Verify
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.FILLED));

    // Verify relayer received payment
    assertEq(token.balanceOf(relayer), 1000e6 - protocolFee);
}

function test_notify_success_fromNew() public {
    bytes32 intentId = _createTestIntent();

    // Skip fill(), notify directly
    bytes memory payload = abi.encode(
        intentId,
        995e6,
        bytes32(uint256(uint160(relayer))),
        receiverBytes32,
        destinationTokenBytes32
    );

    vm.prank(axelarGateway);
    rozoIntents.notify("stellar", stellarContract, payload);

    // Verify - should still work
    (,, IntentStatus status,, address recordedRelayer) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.FILLED));
    assertEq(recordedRelayer, relayer); // Recorded from payload
}

function test_notify_setsFailed_onMismatch() public {
    bytes32 intentId = _createTestIntent();

    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // Wrong receiver in payload
    bytes memory payload = abi.encode(
        intentId,
        995e6,
        bytes32(uint256(uint160(relayer))),
        bytes32(uint256(uint160(wrongReceiver))),  // Wrong!
        destinationTokenBytes32
    );

    vm.prank(axelarGateway);
    rozoIntents.notify("stellar", stellarContract, payload);

    // Should be FAILED, not FILLED
    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.FAILED));
}

function test_notify_revert_notMessenger() public {
    bytes32 intentId = _createTestIntent();

    bytes memory payload = abi.encode(...);

    vm.prank(randomUser);
    vm.expectRevert(NotMessenger.selector);
    rozoIntents.notify("stellar", stellarContract, payload);
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

function test_refund_fromFilling() public {
    bytes32 intentId = _createTestIntent();

    // Relayer fills but never completes
    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // Warp past deadline
    vm.warp(block.timestamp + 2 hours);

    // Sender can still refund
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

    // Recover to NEW
    vm.prank(owner);
    rozoIntents.setIntentStatus(intentId, IntentStatus.NEW);

    (,, IntentStatus status,,) = rozoIntents.intents(intentId);
    assertEq(uint(status), uint(IntentStatus.NEW));
}

function test_admin_setIntentRelayer() public {
    bytes32 intentId = _createTestIntent();

    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // Admin changes relayer
    vm.prank(owner);
    rozoIntents.setIntentRelayer(intentId, newRelayer);

    (,,,, address recordedRelayer) = rozoIntents.intents(intentId);
    assertEq(recordedRelayer, newRelayer);
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
    // 1. Sender creates intent
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
        sender
    );

    // 2. Relayer fills
    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // 3. Simulate Axelar callback
    bytes memory payload = abi.encode(
        intentId,
        995e6,
        bytes32(uint256(uint160(relayer))),
        receiverBytes32,
        destinationTokenBytes32
    );

    vm.prank(axelarGateway);
    rozoIntents.notify("stellar", stellarContract, payload);

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

    // Relayer fills but never completes
    vm.prank(relayer);
    rozoIntents.fill(intentId);

    // Time passes, deadline expires
    vm.warp(block.timestamp + 2 hours);

    // Sender refunds
    uint256 balanceBefore = token.balanceOf(sender);
    rozoIntents.refund(intentId);

    // Full refund (no fee deducted)
    assertEq(token.balanceOf(sender), balanceBefore + 1000e6);
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
    token = new MockERC20("USDC", "USDC", 6);

    // Configure
    vm.startPrank(owner);
    rozoIntents.setMessenger(axelarGateway, true);
    rozoIntents.setTrustedContract("stellar", stellarContract);
    rozoIntents.addRelayer(relayer);
    rozoIntents.setProtocolFee(3); // 3 bps
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
        sender
    );
    vm.stopPrank();
    return intentId;
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
