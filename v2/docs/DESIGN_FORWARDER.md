# Token Forwarder Contract Design

> Minimal forwarding contract, approximately 100 lines of code

---

## 1. Overview

Users call `forward()`, and the contract immediately transfers tokens to `proxy_address`, recording the final destination address `to` and memo in events.

```
User ──► forward(token, amount, to, memo) ──► proxy_address
                    │
                    ▼
            ForwardEvent(to, memo)
                    │
                    ▼
            Backend listens to events, transfers to `to`
```

**No user fund custody - immediate forwarding.** (Contract only stores configuration, does not hold user funds)

- `proxy_address`: Temporary relay address (contract configuration)
- `to`: The actual destination address the user wants to transfer to (recorded in events)

---

## 2. Interface

```rust
/// Constructor: Automatically called during deployment, only deployer can set initial config
pub fn __constructor(env: Env, admin: Address, proxy_address: Address);

/// Forward tokens
pub fn forward(env: Env, sender: Address, token: Address, amount: i128, to: String, memo: String) -> Result<(), Error>;

/// Admin: Update proxy address
pub fn set_proxy_address(env: Env, new_proxy_address: Address) -> Result<(), Error>;

/// Admin: Flush stuck tokens
pub fn flush(env: Env, token: Address, amount: i128) -> Result<(), Error>;

/// Query functions
pub fn get_proxy_address(env: Env) -> Option<Address>;
pub fn get_admin(env: Env) -> Option<Address>;
```

---

## 3. Storage

```rust
pub enum DataKey {
    Admin,        // Address
    ProxyAddress, // Address
    // Note: Removed Initialized, using __constructor pattern
}
```

---

## 4. Events

```rust
pub struct ForwardEvent {
    pub sender: Address,
    pub proxy_address: Address,
    pub token: Address,
    pub amount: i128,
    pub to: String,           // The actual destination address
    pub memo: String,
    pub timestamp: u64,
}
```

---

## 5. Error Codes

```rust
pub enum Error {
    NotInitialized = 1,
    ZeroAmount = 2,
    EmptyDestination = 3,  // `to` is empty
    MemoTooLong = 4,       // > 28 bytes
}
```

---

## 6. Security Checks

| Function | Checks |
|----------|--------|
| `__constructor` | Only called during deployment (guaranteed by Soroban) |
| `forward` | Initialized, amount > 0, `to` not empty, memo <= 28 bytes, sender.require_auth() |
| `set_proxy_address` | admin.require_auth() |
| `flush` | admin.require_auth(), amount > 0 |

---

## 7. Test Checklist

- [ ] Constructor correctly sets admin/proxy_address
- [ ] forward requires sender authorization
- [ ] forward rejects amount <= 0
- [ ] forward rejects empty `to`
- [ ] forward rejects memo > 28 bytes
- [ ] forward event contains correct `to` address
- [ ] forward precisely transfers sender → proxy_address
- [ ] set_proxy_address requires admin only
- [ ] flush requires admin only

---

## 8. Pseudocode Implementation

```rust
#![no_std]
use soroban_sdk::{contract, contractimpl, symbol_short, token, Address, Env, String};

#[contract]
pub struct TokenForwarder;

#[contractimpl]
impl TokenForwarder {
    /// Constructor: Automatically called during deployment
    pub fn __constructor(env: Env, admin: Address, proxy_address: Address) {
        env.storage().instance().set(&DataKey::Admin, &admin);
        env.storage().instance().set(&DataKey::ProxyAddress, &proxy_address);
    }

    pub fn forward(env: Env, sender: Address, token_addr: Address, amount: i128, to: String, memo: String) -> Result<(), Error> {
        if !env.storage().instance().has(&DataKey::Admin) {
            return Err(Error::NotInitialized);
        }
        if amount <= 0 {
            return Err(Error::ZeroAmount);
        }
        if to.len() == 0 {
            return Err(Error::EmptyDestination);
        }
        if memo.len() > 28 {
            return Err(Error::MemoTooLong);
        }

        sender.require_auth();

        let proxy_address: Address = env.storage().instance()
            .get(&DataKey::ProxyAddress)
            .ok_or(Error::NotInitialized)?;

        // Transfer to proxy_address
        let token_client = token::Client::new(&env, &token_addr);
        token_client.transfer(&sender, &proxy_address, &amount);

        // Emit event (contains the actual destination address `to`)
        env.events().publish(
            (symbol_short!("forward"), sender.clone()),
            ForwardEvent { sender, proxy_address, token: token_addr, amount, to, memo, timestamp: env.ledger().timestamp() }
        );

        Ok(())
    }

    pub fn set_proxy_address(env: Env, new_proxy_address: Address) -> Result<(), Error> {
        let admin: Address = env.storage().instance()
            .get(&DataKey::Admin)
            .ok_or(Error::NotInitialized)?;
        admin.require_auth();
        env.storage().instance().set(&DataKey::ProxyAddress, &new_proxy_address);
        Ok(())
    }

    pub fn flush(env: Env, token_addr: Address, amount: i128) -> Result<(), Error> {
        if amount <= 0 {
            return Err(Error::ZeroAmount);
        }
        let admin: Address = env.storage().instance()
            .get(&DataKey::Admin)
            .ok_or(Error::NotInitialized)?;
        admin.require_auth();
        let proxy_address: Address = env.storage().instance()
            .get(&DataKey::ProxyAddress)
            .ok_or(Error::NotInitialized)?;

        let token_client = token::Client::new(&env, &token_addr);
        token_client.transfer(&env.current_contract_address(), &proxy_address, &amount);
        Ok(())
    }

    pub fn get_proxy_address(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::ProxyAddress)
    }

    pub fn get_admin(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::Admin)
    }
}
```
