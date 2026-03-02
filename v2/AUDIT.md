# Rozo Intents Contracts V2 - Audit Scope

## Overview

This document outlines the audit scope for Rozo Intents Contracts V2, a set of Soroban smart contracts for cross-chain intent-based token forwarding and bridging on Stellar.

## Audit Scope

### In Scope

**Only the `v2/` folder is in scope for this audit.**

```
v2/
├── stellar/
│   ├── forwarder/
│   │   └── src/
│   │       ├── lib.rs          # Token Forwarder contract
│   │       └── test.rs         # Unit tests
│   └── intent_bridge/
│       └── src/
│           ├── lib.rs          # Intent Bridge contract
│           └── test.rs         # Unit tests
```

### Contracts Summary

| Contract | File | Lines of Code | Description |
|----------|------|---------------|-------------|
| Token Forwarder | `stellar/forwarder/src/lib.rs` | ~150 | Minimal token forwarding with event-based destination tracking |
| Intent Bridge | `stellar/intent_bridge/src/lib.rs` | ~330 | Escrow-based cross-chain intent system with timeout protection |

### Out of Scope

- All files outside the `v2/` folder
- Documentation files (`*.md`)
- Configuration files (`Cargo.toml`)
- Build artifacts (`target/`)
- Test files (for informational purposes only, not security critical)

---

## Contract Details

### 1. Token Forwarder

**Purpose:** Minimal forwarding contract that transfers tokens to a proxy address and emits events for backend processing.

**Key Functions:**

| Function | Description | Access Control |
|----------|-------------|----------------|
| `__constructor(admin, proxy_address)` | Initialize contract | Deployment only |
| `forward(sender, token, amount, to, memo)` | Forward tokens to proxy | sender.require_auth() |
| `set_proxy_address(new_proxy_address)` | Update proxy address | admin.require_auth() |
| `flush(token, amount)` | Recover stuck tokens | admin.require_auth() |

**Storage:**
- `Admin` - Admin address (instance storage)
- `ProxyAddress` - Proxy address (instance storage)

**Events:**
- `ForwardEvent` - Emitted on each forward operation

---

### 2. Intent Bridge

**Purpose:** Escrow contract for cross-chain intents with 3-state state machine (PENDING → FILLED | REFUNDED).

**Key Functions:**

| Function | Description | Access Control |
|----------|-------------|----------------|
| `__constructor(messenger, relayer, deadline_duration)` | Initialize contract | Deployment only |
| `create_intent(sender, source_token, source_amount, dest_chain, dest_address, dest_amount, memo)` | Create intent and lock funds | sender.require_auth() |
| `fill(intent_id)` | Confirm cross-chain completion | messenger.require_auth() |
| `refund(intent_id)` | Reclaim funds after timeout | intent.sender.require_auth() |

**Storage:**
- `Messenger` - Messenger address (instance storage)
- `Relayer` - Relayer address (instance storage)
- `DeadlineDuration` - Default deadline duration (instance storage)
- `Intent(BytesN<32>)` - Intent data (persistent storage with TTL)

**Events:**
- `IntentCreatedEvent` - Emitted on intent creation
- `IntentFilledEvent` - Emitted on fill
- `IntentRefundedEvent` - Emitted on refund

**State Machine:**
```
PENDING ──► FILLED    (Messenger fill, before deadline)
    │
    └────► REFUNDED   (sender refund, after deadline)
```

---

## Security Considerations

### Areas of Focus

1. **Authorization**
   - Verify `require_auth()` is correctly enforced on all state-changing functions
   - Check role separation (admin, messenger, relayer, sender)

2. **Fund Safety**
   - Token Forwarder: Immediate transfer, no custody
   - Intent Bridge: Escrow model with timeout protection
   - Verify funds cannot be locked permanently

3. **State Machine Integrity**
   - Terminal state protection (FILLED/REFUNDED cannot transition)
   - Deadline enforcement (fill before deadline, refund after deadline)

4. **Arithmetic Safety**
   - Deadline overflow protection (`checked_add`)
   - Amount validation (> 0)

5. **Storage & TTL**
   - TTL management for persistent storage
   - Intent expiration handling

6. **Input Validation**
   - Memo length limit (28 bytes)
   - Empty destination check
   - Zero amount rejection

### Known Design Decisions

1. **Trusted Backend Model**: Messenger/Relayer are trusted entities controlled by Rozo
2. **No Admin Upgrade**: Contracts use `__constructor` pattern, no upgradability
3. **Single Messenger/Relayer**: No multi-sig or decentralized confirmation (planned for V3)

---

## Build & Test

```bash
cd v2/stellar

# Build
cargo build --release --target wasm32-unknown-unknown

# Test
cargo test
```

## Dependencies

| Dependency | Version |
|------------|---------|
| soroban-sdk | 22.0.0 |

## Documentation

- [Token Forwarder Design](docs/DESIGN_FORWARDER.md)
- [Intent Bridge Design](docs/DESIGN_INTENT_BRIDGE.md)

## Contact

For questions regarding this audit scope, please contact hi@rozo.ai
