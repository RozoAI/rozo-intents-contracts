# Token Forwarder Contract Design

> Minimal forwarding contract, approximately 150 lines of code

---

## 0. Problem statements

Stellar Smart Wallets (C Accounts) cannot transfer or receive USDC with memo. For example, users from Coinbase cannot withdraw or deposit via Smart Wallets. 
https://developers.stellar.org/docs/build/guides/contract-accounts/smart-wallets

## 1. Overview


The Token Forwarder supports **bidirectional forwarding** between C Wallets (Smart Accounts) and G Wallets (Stellar Accounts).

### Flow 1: C Wallets → G Wallets

Smart Accounts cannot set memo directly, so the contract forwards tokens to a proxy which then pays with memo.

```
Stellar Smart Account (C Address)
         │
         ▼
Payer ──► forward(token, amount, to, memo) ──► Proxy (G Address)
                    │                               │
                    ▼                               ▼
            ForwardEvent(to, memo)           Pay with memo
                    │                               │
                    ▼                               ▼
            Backend processes              CEX User (Binance, Coinbase)
```

### Flow 2: G Wallets → C Wallets (Memo Mapping)

CEXs/Wallets can send to Proxy with memo, and the contract uses **memo mapping** to route to the correct Smart Account.

```
CEX User (Binance, Coinbase)
         │
         ▼
Send $1000 with memo ──► Proxy (G Address)
                              │
                              ▼
                    Forwarder Contract
                    (memo Mapping lookup)
                              │
                              ▼
                    Smart Account (C Address)
```

**Key Features:**
- **No user fund custody** - Immediate forwarding
- **Memo Mapping** - Maps memo string to destination address for reverse flow
- **Bidirectional** - Supports both C→G and G→C transfers

---

## 2. Interface

```rust
/// Constructor: Automatically called during deployment, only deployer can set initial config
pub fn __constructor(env: Env, admin: Address, proxy_address: Address);

/// Forward tokens (C Wallets → G Wallets)
pub fn forward(env: Env, sender: Address, token: Address, amount: i128, to: String, memo: String) -> Result<(), Error>;

/// Admin: Set memo mapping (for G Wallets → C Wallets)
pub fn set_memo_mapping(env: Env, memo: String, destination: Address) -> Result<(), Error>;

/// Admin: Remove memo mapping
pub fn remove_memo_mapping(env: Env, memo: String) -> Result<(), Error>;

/// Admin: Update proxy address
pub fn set_proxy_address(env: Env, new_proxy_address: Address) -> Result<(), Error>;

/// Admin: Flush stuck tokens
pub fn flush(env: Env, token: Address, amount: i128) -> Result<(), Error>;

/// Query functions
pub fn get_proxy_address(env: Env) -> Option<Address>;
pub fn get_admin(env: Env) -> Option<Address>;
pub fn get_memo_destination(env: Env, memo: String) -> Option<Address>;
```

---

## 3. Storage

```rust
pub enum DataKey {
    Admin,              // Address
    ProxyAddress,       // Address
    MemoMapping(String), // Address - maps memo to destination address
}
```

---

## 4. Events

```rust
/// Emitted when forwarding C → G
pub struct ForwardEvent {
    pub sender: Address,
    pub proxy_address: Address,
    pub token: Address,
    pub amount: i128,
    pub to: String,           // The actual destination address
    pub memo: String,
    pub timestamp: u64,
}

/// Emitted when memo mapping is set
pub struct MemoMappingSetEvent {
    pub memo: String,
    pub destination: Address,
    pub timestamp: u64,
}

/// Emitted when memo mapping is removed
pub struct MemoMappingRemovedEvent {
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
    MemoNotFound = 5,      // memo mapping doesn't exist
    EmptyMemo = 6,         // memo is empty for mapping
}
```

---

## 6. Security Checks

| Function | Checks |
|----------|--------|
| `__constructor` | Only called during deployment (guaranteed by Soroban) |
| `forward` | Initialized, amount > 0, `to` not empty, memo <= 28 bytes, sender.require_auth() |
| `set_memo_mapping` | admin.require_auth(), memo not empty, memo <= 28 bytes |
| `remove_memo_mapping` | admin.require_auth() |
| `set_proxy_address` | admin.require_auth() |
| `flush` | admin.require_auth(), amount > 0 |

---

## 7. Test Checklist

### Forward (C → G)
- [ ] Constructor correctly sets admin/proxy_address
- [ ] forward requires sender authorization
- [ ] forward rejects amount <= 0
- [ ] forward rejects empty `to`
- [ ] forward rejects memo > 28 bytes
- [ ] forward event contains correct `to` address
- [ ] forward precisely transfers sender → proxy_address

### Memo Mapping (G → C)
- [ ] set_memo_mapping requires admin only
- [ ] set_memo_mapping rejects empty memo
- [ ] set_memo_mapping rejects memo > 28 bytes
- [ ] set_memo_mapping emits event
- [ ] get_memo_destination returns correct address
- [ ] remove_memo_mapping requires admin only
- [ ] remove_memo_mapping emits event

### Admin Functions
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

    /// Forward tokens (C Wallets → G Wallets)
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

    /// Admin: Set memo mapping (for G Wallets → C Wallets)
    pub fn set_memo_mapping(env: Env, memo: String, destination: Address) -> Result<(), Error> {
        let admin: Address = env.storage().instance()
            .get(&DataKey::Admin)
            .ok_or(Error::NotInitialized)?;
        admin.require_auth();

        if memo.len() == 0 {
            return Err(Error::EmptyMemo);
        }
        if memo.len() > 28 {
            return Err(Error::MemoTooLong);
        }

        env.storage().persistent().set(&DataKey::MemoMapping(memo.clone()), &destination);

        // Emit event
        env.events().publish(
            (symbol_short!("memo_set"),),
            MemoMappingSetEvent { memo, destination, timestamp: env.ledger().timestamp() }
        );

        Ok(())
    }

    /// Admin: Remove memo mapping
    pub fn remove_memo_mapping(env: Env, memo: String) -> Result<(), Error> {
        let admin: Address = env.storage().instance()
            .get(&DataKey::Admin)
            .ok_or(Error::NotInitialized)?;
        admin.require_auth();

        env.storage().persistent().remove(&DataKey::MemoMapping(memo.clone()));

        // Emit event
        env.events().publish(
            (symbol_short!("memo_rm"),),
            MemoMappingRemovedEvent { memo, timestamp: env.ledger().timestamp() }
        );

        Ok(())
    }

    /// Query memo destination
    pub fn get_memo_destination(env: Env, memo: String) -> Option<Address> {
        env.storage().persistent().get(&DataKey::MemoMapping(memo))
    }

    pub fn set_proxy_address(env: Env, new_proxy_address: Address) -> Result<(), Error> {
        let admin: Address = env.storage().instance()
            .get(&DataKey::Admin)
            .ok_or(Error::NotInitialized)?;
        admin.require_auth();
        env.storage().instance().set(&DataKey::ProxyAddress, &new_proxy_address);

        // Emit event for proxy address change
        env.events().publish(
            (symbol_short!("proxy_set"),),
            (new_proxy_address, env.ledger().timestamp())
        );

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

---

## 9. Memo Mapping Usage

### Setting Up Memo Mapping

Admin sets up a mapping between memo and destination Smart Account:

```rust
// Map memo "user123" to Smart Account C...Bob
forwarder.set_memo_mapping("user123", Address("C...Bob"));
```

### G → C Flow (Backend)

1. CEX user sends $1000 with memo "user123" to Proxy (G Address)
2. Backend detects payment to Proxy
3. Backend calls `get_memo_destination("user123")` → returns `C...Bob`
4. Backend transfers $1000 to `C...Bob`

### Memo Best Practices

- Use unique, non-guessable memos
- Keep memos short (max 28 bytes for Stellar compatibility)
- Consider using UUIDs or hashed identifiers
