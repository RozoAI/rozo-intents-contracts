# ROZO Intents Contracts

## Almanax Security Scan Report

---

# 1️⃣ Overview

**Project Name:** rozo-intents-contracts
**Network:** Stellar (Soroban)
**Project Type:** Rust (Soroban)
**Scan Mode:** Default

**Repository:** RozoAI/rozo-intents-contracts
**Commit:** d59c380
**Initiated By:** [shawn@rozo.ai](mailto:shawn@rozo.ai)
**Completion Time:** March 3, 2026 – 06:40:01 AM

---

# 3️⃣ Files Scanned

The following files were analyzed:

### 📂 v2/

#### 📂 stellar/

##### 📂 forwarder/

###### 📂 src/

* `lib.rs` — COMPLETE
* `test.rs` — COMPLETE

##### 📂 intent_bridge/

###### 📂 src/

* `lib.rs` — COMPLETE
* `test.rs` — COMPLETE

**Total Files Scanned:** 4
**Total Directories:** v2

---

# 4️⃣ Findings Summary

| ID | Title                                                          | Severity |
| -- | -------------------------------------------------------------- | -------- |
| 1  | Resource Management: State can expire due to missing TTL bumps | Low      |

**Total Findings:** 1

* Critical: 0
* High: 0
* Medium: 0
* Low: 1
* Informational: 0

---

# 5️⃣ Finding Detail

## Finding #1

### Resource Management: State can expire due to missing TTL bumps

**Severity:** Low
**File:** `v2/stellar/forwarder/src/lib.rs`

---

## Description

The contract writes critical configuration values:

* `Admin`
* `ProxyAddress`

to **instance storage**, and memo routing data to **persistent storage**, but does not extend (bump) their TTL.

On Soroban:

* Instance and persistent ledger entries expire unless periodically extended.
* Once expired:

  * `forward()` may fail with `NotInitialized`
  * `get_memo_destination()` may return `None`
  * Routing logic may break

This introduces potential **Denial-of-Service (DoS)** risks during inactivity periods.

---

## Exploitation Scenario

An attacker (or normal user) can:

1. Wait until TTL expiration.
2. Call forward or memo lookup.
3. Contract fails due to missing state.

Impact:

* Forwarding stops
* Memo mappings vanish
* Off-chain routing relying on memo lookups breaks

---

## Impacted Code

```rust
pub fn __constructor(env: Env, admin: Address, proxy_address: Address) {
    env.storage().instance().set(&DataKey::Admin, &admin);
    env.storage().instance().set(&DataKey::ProxyAddress, &proxy_address);
}

pub fn set_memo_mapping(env: Env, memo: String, destination: Address) -> Result<(), Error> {
    env.storage().persistent().set(&DataKey::MemoMapping(memo.clone()), &destination);
}

pub fn get_memo_destination(env: Env, memo: String) -> Option<Address> {
    env.storage().persistent().get(&DataKey::MemoMapping(memo))
}
```

---

## Recommendation

Extend TTL for critical storage entries.

### Option 1 — Extend Instance Storage TTL

```rust
env.storage().instance().extend_ttl(threshold, extend);
```

### Option 2 — Extend Persistent Storage TTL

```rust
env.storage()
    .persistent()
    .extend_ttl(&DataKey::MemoMapping(memo.clone()), threshold, extend);
```

### Option 3 — Admin Refresh Function

Provide an admin function to refresh TTLs for:

* Admin configuration
* ProxyAddress
* Memo mappings

---

# 6️⃣ Scan Configuration Snapshot

```
Scan Mode: DEFAULT  
Project Type: RUST_SOROBAN  

Include:
  v2/**

Exclude:
  evm/**
  relayer/**
  stellar/**
  v1/**

GitHub Integration:
  Severity Threshold: MEDIUM
  Count Limit: 10
  Trigger: EVERY_COMMIT
  Comments Enabled: true
```

---

# 7️⃣ Conclusion

The scan identified **no Critical, High, or Medium severity issues**.

The only finding concerns Soroban-specific TTL management.
Extending TTL values for critical entries will prevent operational failure after inactivity.

After remediation, a re-scan is recommended.

---

**Report Generated:** March 3, 2026
**Scanner:** Almanax
**Project Owner:** ROZO

---

*End of Report*
