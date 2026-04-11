# Intent Bridge Contract Design

> Simplified escrow contract, approximately 200 lines of code

---

## 1. Overview

Users create intents to lock funds. The Messenger confirms cross-chain completion by calling `fill()`. If timeout occurs, users can call `refund()`.

```
User ──► create_intent() ──► Lock funds (PENDING)
                                │
              ┌─────────────────┴─────────────────┐
              │                                   │
              ▼                                   ▼
      fill() (Messenger)                  refund() after timeout
              │                                   │
              ▼                                   ▼
           FILLED                             REFUNDED
         (Transfer to Relayer)
```

**3-state state machine, no intermediate states.**

### Role Definitions

| Role | Responsibility | Permission |
|------|----------------|------------|
| **Messenger** | Confirms cross-chain message completion | Calls `fill()` |
| **Relayer** | Receives locked funds, executes on destination chain | Receives `fill()` transfer |

> **Note:** In early stages, Messenger and Relayer can be the same address.

---

## 2. State Machine

```
PENDING ──► FILLED    (Terminal state, Messenger fill, before deadline)
    │
    └────► REFUNDED   (Terminal state, sender refund, after deadline)
```

| Current | Operation | Condition | Next State |
|---------|-----------|-----------|------------|
| - | `create_intent()` | - | PENDING |
| PENDING | `fill()` | Messenger, now < deadline | FILLED |
| PENDING | `refund()` | sender, now >= deadline | REFUNDED |

**Terminal State Protection:** No changes allowed after FILLED or REFUNDED.

---

## 3. Data Structures

```rust
pub struct Intent {
    pub intent_id: BytesN<32>,
    pub sender: Address,
    pub source_token: Address,
    pub source_amount: i128,           // Actual escrowed amount (balance delta after transfer)
    pub destination_chain: String,
    pub destination_address: String,
    pub destination_amount: i128,
    pub memo: String,
    pub status: IntentStatus,
    pub created_at: u64,
    pub deadline: u64,
}

pub enum IntentStatus {
    Pending = 0,
    Filled = 1,
    Refunded = 2,
}
```

**Removed Fields:**
- ~~source_chain~~ (Fixed to Stellar)
- ~~mode~~ (Backend decides routing)

---

## 4. Interface

```rust
/// Constructor: Automatically called during deployment.
///
/// All roles (Messenger, Relayer) and parameters (deadline_duration) are immutable
/// after deployment. This is intentional — the bridge is a fast solver that does
/// not hold long-term user liquidity. If key rotation or parameter changes are
/// needed, the contract is redeployed. No user asset migration is required.
///
/// deadline_duration must be greater than 0.
/// Returns Error::InvalidDeadlineDuration if zero is provided.
///
/// Redeployment procedure: deploy a new contract instance with updated parameters.
/// Pending intents in the old contract remain accessible for fill/refund until
/// their TTL expires.
pub fn __constructor(
    env: Env,
    messenger: Address,         // Confirms cross-chain messages
    relayer: Address,           // Receives funds
    deadline_duration: u64,     // Default 86400 (24h), must be > 0
) -> Result<(), Error>;

/// Create intent and lock funds
pub fn create_intent(
    env: Env,
    sender: Address,
    source_token: Address,
    source_amount: i128,
    destination_chain: String,
    destination_address: String,
    destination_amount: i128,
    memo: String,
) -> Result<BytesN<32>, Error>;

/// Messenger: Confirm cross-chain completion, transfer funds to Relayer
pub fn fill(env: Env, intent_id: BytesN<32>) -> Result<(), Error>;

/// User: Timeout refund
pub fn refund(env: Env, intent_id: BytesN<32>) -> Result<(), Error>;

/// Query functions
pub fn get_intent(env: Env, intent_id: BytesN<32>) -> Option<Intent>;
pub fn get_messenger(env: Env) -> Option<Address>;
pub fn get_relayer(env: Env) -> Option<Address>;
pub fn get_deadline_duration(env: Env) -> Option<u64>;
```

**Removed Interfaces:**
- ~~fail()~~ (No intermediate states needed)
- ~~emergency_withdraw_stuck()~~ (refund is sufficient)
- ~~rozo_address / get_rozo_address()~~ (Not needed after removing mode)

---

## 5. Storage

```rust
pub enum DataKey {
    Messenger,        // Address - Confirms cross-chain messages
    Relayer,          // Address - Receives funds
    DeadlineDuration, // u64
    Intent(BytesN<32>),
    // Note: Removed Initialized, using __constructor pattern
}
```

---

## 6. Events

```rust
pub struct IntentCreatedEvent {
    pub intent_id: BytesN<32>,
    pub sender: Address,
    pub source_token: Address,
    pub source_amount: i128,           // Actual escrowed amount, not requested amount
    pub destination_chain: String,
    pub destination_address: String,
    pub destination_amount: i128,
    pub deadline: u64,
}

pub struct IntentFilledEvent {
    pub intent_id: BytesN<32>,
    pub timestamp: u64,
}

pub struct IntentRefundedEvent {
    pub intent_id: BytesN<32>,
    pub sender: Address,
    pub source_amount: i128,
    pub timestamp: u64,
}
```

---

## 7. Error Codes

```rust
pub enum Error {
    NotInitialized = 2,
    ZeroAmount = 3,            // Input amount is zero OR effective escrowed amount is zero
    IntentNotFound = 4,
    InvalidStatus = 5,         // Terminal state cannot be changed
    DeadlineNotReached = 6,    // Early refund attempt
    MemoTooLong = 7,
    IntentAlreadyExists = 8,   // intent_id already exists
    DeadlineExceeded = 9,      // fill() timeout
    DeadlineOverflow = 10,     // Deadline calculation overflow
    InvalidDeadlineDuration = 11,  // Constructor: deadline_duration == 0
    EmptyDestination = 12,     // destination_chain or destination_address is empty
}
```

---

## 8. Security Checks

| Function | Checks |
|----------|--------|
| `__constructor` | deadline_duration > 0 (Error::InvalidDeadlineDuration). Only called during deployment (guaranteed by Soroban) |
| `create_intent` | Initialized, source_amount > 0, destination_amount > 0, destination_chain non-empty, destination_address non-empty, memo <= 28 bytes, sender.require_auth(), intent_id doesn't exist, deadline doesn't overflow, actual_received > 0 |
| `fill` | messenger.require_auth(), status == PENDING, now < deadline |
| `refund` | sender.require_auth(), status == PENDING, now >= deadline |

**TTL Management:**
- Instance TTL: extended on every create/fill/refund (7-day threshold, 14-day extension)
- Intent TTL: extended on every create/fill/refund (7-day threshold, 14-day extension)
- Prevents contract archival and intent expiration causing fund lockout

---

## 9. Test Checklist

- [ ] Constructor correctly sets messenger/relayer/deadline_duration
- [ ] Constructor rejects deadline_duration == 0 with Error::InvalidDeadlineDuration
- [ ] create_intent requires sender authorization
- [ ] create_intent rejects source_amount <= 0
- [ ] create_intent rejects destination_amount <= 0
- [ ] create_intent rejects empty destination_chain
- [ ] create_intent rejects empty destination_address
- [ ] create_intent rejects memo > 28 bytes
- [ ] create_intent rejects duplicate intent_id
- [ ] create_intent locks funds to contract
- [ ] create_intent with zero effective escrowed amount fails with ZeroAmount
- [ ] IntentCreatedEvent.source_amount matches stored intent.source_amount
- [ ] fill requires Messenger only
- [ ] fill requires PENDING status only
- [ ] fill requires before deadline (now < deadline)
- [ ] fill transfers to Relayer
- [ ] refund requires original sender only
- [ ] refund requires PENDING status only
- [ ] refund requires after deadline only
- [ ] refund precisely returns source_amount
- [ ] Cannot fill/refund after FILLED
- [ ] Cannot fill/refund after REFUNDED

---

## 10. Pseudocode Implementation

```rust
#![no_std]
use soroban_sdk::{
    contract, contractimpl, contracttype, symbol_short,
    token, Address, Bytes, BytesN, Env, String,
};

#[contract]
pub struct IntentBridge;

#[contractimpl]
impl IntentBridge {
    pub fn __constructor(
        env: Env,
        messenger: Address,
        relayer: Address,
        deadline_duration: u64
    ) -> Result<(), Error> {
        if deadline_duration == 0 {
            return Err(Error::InvalidDeadlineDuration);
        }
        env.storage().instance().set(&DataKey::Messenger, &messenger);
        env.storage().instance().set(&DataKey::Relayer, &relayer);
        env.storage().instance().set(&DataKey::DeadlineDuration, &deadline_duration);
        Ok(())
    }

    pub fn create_intent(
        env: Env,
        sender: Address,
        source_token: Address,
        source_amount: i128,
        destination_chain: String,
        destination_address: String,
        destination_amount: i128,
        memo: String,
    ) -> Result<BytesN<32>, Error> {
        if !env.storage().instance().has(&DataKey::Messenger) {
            return Err(Error::NotInitialized);
        }
        if source_amount <= 0 {
            return Err(Error::ZeroAmount);
        }
        if destination_amount <= 0 {
            return Err(Error::ZeroAmount);
        }
        if destination_chain.len() == 0 || destination_address.len() == 0 {
            return Err(Error::EmptyDestination);
        }
        if memo.len() > 28 {
            return Err(Error::MemoTooLong);
        }

        sender.require_auth();

        // Generate collision-resistant intent_id: sha256(sender + timestamp + ledger_sequence + source_token + amount + dest_chain + dest_address + dest_amount + memo)
        let now = env.ledger().timestamp();
        let mut preimage = Bytes::new(&env);
        preimage.append(&sender.clone().to_xdr(&env));
        preimage.append(&Bytes::from_slice(&env, &now.to_be_bytes()));
        preimage.append(&Bytes::from_slice(&env, &env.ledger().sequence().to_be_bytes()));
        preimage.append(&source_token.clone().to_xdr(&env));
        preimage.append(&Bytes::from_slice(&env, &source_amount.to_be_bytes()));
        preimage.append(&destination_chain.to_xdr(&env));
        preimage.append(&destination_address.to_xdr(&env));
        preimage.append(&Bytes::from_slice(&env, &destination_amount.to_be_bytes()));
        preimage.append(&memo.to_xdr(&env));
        let intent_id: BytesN<32> = env.crypto().sha256(&preimage).into();

        // Check intent_id doesn't exist
        if env.storage().persistent().has(&DataKey::Intent(intent_id.clone())) {
            return Err(Error::IntentAlreadyExists);
        }

        let deadline_duration: u64 = env.storage().instance()
            .get(&DataKey::DeadlineDuration)
            .ok_or(Error::NotInitialized)?;

        // Check deadline overflow
        let deadline = now.checked_add(deadline_duration)
            .ok_or(Error::DeadlineOverflow)?;

        let intent = Intent {
            intent_id: intent_id.clone(),
            sender: sender.clone(),
            source_token: source_token.clone(),
            source_amount,
            destination_chain: destination_chain.clone(),
            destination_address: destination_address.clone(),
            destination_amount,
            memo: memo.clone(),
            status: IntentStatus::Pending,
            created_at: now,
            deadline,
        };

        // Lock funds to contract — measure actual received amount
        let token_client = token::Client::new(&env, &source_token);
        let balance_before = token_client.balance(&env.current_contract_address());
        token_client.transfer(&sender, &env.current_contract_address(), &source_amount);
        let balance_after = token_client.balance(&env.current_contract_address());
        let actual_received = balance_after - balance_before;
        if actual_received <= 0 {
            return Err(Error::ZeroAmount);
        }

        // Store intent with actual escrowed amount
        let intent = Intent { source_amount: actual_received, ..intent };
        env.storage().persistent().set(&DataKey::Intent(intent_id.clone()), &intent);

        // Extend TTL
        extend_ttl(&env, &intent_id);

        // Emit event with actual escrowed amount
        env.events().publish(
            (symbol_short!("created"),),
            IntentCreatedEvent {
                intent_id: intent_id.clone(),
                sender,
                source_token,
                source_amount: actual_received,
                destination_chain,
                destination_address,
                destination_amount,
                deadline,
            }
        );

        Ok(intent_id)
    }

    pub fn fill(env: Env, intent_id: BytesN<32>) -> Result<(), Error> {
        let messenger: Address = env.storage().instance()
            .get(&DataKey::Messenger)
            .ok_or(Error::NotInitialized)?;
        messenger.require_auth();

        let mut intent: Intent = env.storage().persistent()
            .get(&DataKey::Intent(intent_id.clone()))
            .ok_or(Error::IntentNotFound)?;

        if intent.status != IntentStatus::Pending {
            return Err(Error::InvalidStatus);
        }

        // fill must be before deadline
        let now = env.ledger().timestamp();
        if now >= intent.deadline {
            return Err(Error::DeadlineExceeded);
        }

        // Update status first
        intent.status = IntentStatus::Filled;
        env.storage().persistent().set(&DataKey::Intent(intent_id.clone()), &intent);

        // Extend TTL
        extend_ttl(&env, &intent_id);

        // Transfer to Relayer
        let relayer: Address = env.storage().instance()
            .get(&DataKey::Relayer)
            .ok_or(Error::NotInitialized)?;
        let token_client = token::Client::new(&env, &intent.source_token);
        token_client.transfer(&env.current_contract_address(), &relayer, &intent.source_amount);

        // Emit event
        env.events().publish(
            (symbol_short!("filled"),),
            IntentFilledEvent { intent_id, timestamp: now }
        );

        Ok(())
    }

    pub fn refund(env: Env, intent_id: BytesN<32>) -> Result<(), Error> {
        let mut intent: Intent = env.storage().persistent()
            .get(&DataKey::Intent(intent_id.clone()))
            .ok_or(Error::IntentNotFound)?;

        intent.sender.require_auth();

        if intent.status != IntentStatus::Pending {
            return Err(Error::InvalidStatus);
        }

        let now = env.ledger().timestamp();
        if now < intent.deadline {
            return Err(Error::DeadlineNotReached);
        }

        // Update status first
        intent.status = IntentStatus::Refunded;
        env.storage().persistent().set(&DataKey::Intent(intent_id.clone()), &intent);

        // Extend TTL
        extend_ttl(&env, &intent_id);

        // Refund
        let token_client = token::Client::new(&env, &intent.source_token);
        token_client.transfer(&env.current_contract_address(), &intent.sender, &intent.source_amount);

        // Emit event
        env.events().publish(
            (symbol_short!("refunded"),),
            IntentRefundedEvent {
                intent_id,
                sender: intent.sender,
                source_amount: intent.source_amount,
                timestamp: now,
            }
        );

        Ok(())
    }

    pub fn get_intent(env: Env, intent_id: BytesN<32>) -> Option<Intent> {
        env.storage().persistent().get(&DataKey::Intent(intent_id))
    }

    pub fn get_messenger(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::Messenger)
    }

    pub fn get_relayer(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::Relayer)
    }

    pub fn get_deadline_duration(env: Env) -> Option<u64> {
        env.storage().instance().get(&DataKey::DeadlineDuration)
    }
}

// TTL constants
const INTENT_TTL_THRESHOLD: u32 = 120960;  // ~7 days
const INTENT_TTL_EXTEND: u32 = 241920;     // ~14 days
const INSTANCE_TTL_THRESHOLD: u32 = 120960;
const INSTANCE_TTL_EXTEND: u32 = 241920;

fn extend_ttl(env: &Env, intent_id: &BytesN<32>) {
    env.storage().persistent().extend_ttl(
        &DataKey::Intent(intent_id.clone()),
        INTENT_TTL_THRESHOLD,
        INTENT_TTL_EXTEND,
    );
}
```

---

## 11. Centralization Considerations

The current design uses a **Trusted Backend Model**:

| Aspect | Description |
|--------|-------------|
| Centralization Risk | If Messenger doesn't call fill, user waits for timeout |
| User Protection | Timeout refund guaranteed by contract |
| Trust Basis | Rozo as a known entity |
| Role Separation | Messenger (confirmation) and Relayer (funds) can be independent |

**Early Stage:**
- Messenger and Relayer can be the same address
- Simplified operations, preserves future expansion capability

**Future Decentralization Path:**
- V3 introduces decentralized Messenger (Axelar/Wormhole)
- Anyone can submit cross-chain proof to fill
- On-chain verification, no need to trust single party
- Relayer network can compete for execution
