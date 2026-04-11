# Rozo Intents Contracts V2

Cross-chain intent-based token forwarding and bridging contracts for Stellar/Soroban.

We are building V2 contracts to bring liquidity from other chains to Stellar. Current cross-chain services have limitations when interacting with Stellar:

### Current Problems

Stellar Smart Wallets (C Accounts) cannot transfer or receive USDC with memo. For example, users from Binance / Coinbase cannot withdraw or deposit via Smart Wallets. 
https://developers.stellar.org/docs/build/guides/contract-accounts/smart-wallets

1. **Address + Memo Limitation**: Some services cannot send to a Stellar address with a memo. For example, if a user wants to send to their Binance deposit address (which requires a memo), this is not supported.

2. **No Contract Invoke Support**: Many cross-chain services do not support contract invocation on Stellar. Users can only send to regular accounts, not interact with smart contracts.

### Our Solution

V2 introduces a **forwarder (proxy) contract** that:

- **Enables address + memo routing**: Users can specify any destination address with memo through events
- **Supports contract invocation**: The proxy pattern allows invoking any Stellar contract through our forwarder


V2 introduces an **intent based bridge contract** that:

- **Service agnostic**: Works as a universal adapter for any liquidity provider (Near Intents, Circle CCTP, and future services)

```
External Liquidity Provider
            │
            ▼
    ┌───────────────┐
    │  V2 Forwarder │ ──► Emit event with (to, memo)
    │    (Proxy)    │
    └───────────────┘
            │
            ▼
    Backend processes event
            │
            ▼
    Send to destination (address + memo supported)
```

## Supported Tokens

The contracts support any Stellar token (SEP-41 compatible), including:

| Token | Mainnet Address | Decimals |
|-------|-----------------|----------|
| XLM (Native) | `CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA` | 7 |
| USDC (Circle) | `CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75` | 7 |
| EURC (Circle) | `CDTKPWPLOURQA2SGTKTUQOWRCBFJ2LFVGWAGDOCKIQTYUEDTPLAPMFKQ` | 7 |

## Overview

This repository contains two Soroban smart contracts:

| Contract | Purpose | Code Size |
|----------|---------|-----------|
| **Token Forwarder** | Minimal token forwarding with event-based destination tracking | ~150 lines |
| **Intent Bridge** | Escrow-based cross-chain intent system with timeout protection | ~200 lines |

## Architecture

### Token Forwarder

```
User ──► forward(token, amount, to, memo) ──► proxy_address
                    │
                    ▼
            ForwardEvent(to, memo)
                    │
                    ▼
            Backend listens to events, transfers to `to`
```

- **No custody**: Tokens transfer immediately to proxy address
- **Event-driven**: Backend monitors events to complete transfers
- **Admin controls**: Proxy address updates and emergency flush

### Intent Bridge

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
```

- **Escrow model**: Funds locked until cross-chain confirmation
- **Timeout protection**: Users can refund after deadline
- **3-state machine**: PENDING → FILLED or REFUNDED (terminal states)

## Project Structure

```
v2/
├── README.md                     # This file
├── docs/
│   ├── DESIGN_FORWARDER.md       # Token Forwarder design specification
│   └── DESIGN_INTENT_BRIDGE.md   # Intent Bridge design specification
└── stellar/
    ├── Cargo.toml                # Workspace configuration
    ├── forwarder/
    │   ├── Cargo.toml
    │   └── src/
    │       ├── lib.rs            # Contract implementation
    │       └── test.rs           # Unit tests
    └── intent_bridge/
        ├── Cargo.toml
        └── src/
            ├── lib.rs            # Contract implementation
            └── test.rs           # Unit tests
```

## Prerequisites

- Rust 1.74+
- Soroban CLI
- Stellar account for deployment

## Build

```bash
cd stellar

# Build all contracts
cargo build --release --target wasm32-unknown-unknown

# Build specific contract
cargo build --release --target wasm32-unknown-unknown -p forwarder
cargo build --release --target wasm32-unknown-unknown -p intent_bridge
```

## Test

```bash
cd stellar

# Run all tests
cargo test

# Run specific contract tests
cargo test -p forwarder
cargo test -p intent_bridge
```

## Deploy

### Token Forwarder

```bash
soroban contract deploy \
  --wasm target/wasm32-unknown-unknown/release/forwarder.wasm \
  --source <DEPLOYER_SECRET> \
  --network testnet \
  -- \
  --admin <ADMIN_ADDRESS> \
  --proxy_address <PROXY_ADDRESS>
```

### Intent Bridge

```bash
soroban contract deploy \
  --wasm target/wasm32-unknown-unknown/release/intent_bridge.wasm \
  --source <DEPLOYER_SECRET> \
  --network testnet \
  -- \
  --messenger <MESSENGER_ADDRESS> \
  --relayer <RELAYER_ADDRESS> \
  --deadline_duration 86400
```

> **Note:** `deadline_duration` must be greater than 0. The constructor returns
> `Error::InvalidDeadlineDuration` if zero is provided. There is no enforced
> upper bound — use a value appropriate for your cross-chain settlement flow.

## Contract Interfaces

### Token Forwarder

| Function | Description | Access |
|----------|-------------|--------|
| `forward(sender, token, amount, to, memo)` | Forward tokens to proxy, emit event | User (requires auth) |
| `set_proxy_address(new_proxy_address)` | Update proxy address | Admin only |
| `flush(token, amount)` | Recover stuck tokens | Admin only |
| `get_proxy_address()` | Query proxy address | Public |
| `get_admin()` | Query admin address | Public |

### Intent Bridge

| Function | Description | Access |
|----------|-------------|--------|
| `create_intent(sender, source_token, source_amount, dest_chain, dest_address, dest_amount, memo)` | Create intent, lock funds | User (requires auth) |
| `fill(intent_id)` | Confirm cross-chain, release to relayer | Messenger only |
| `refund(intent_id)` | Reclaim funds after timeout | Original sender only |
| `get_intent(intent_id)` | Query intent details | Public |
| `get_messenger()` | Query messenger address | Public |
| `get_relayer()` | Query relayer address | Public |
| `get_deadline_duration()` | Query default deadline | Public |

## Security Considerations

### Authorization
- All state-changing functions require explicit `require_auth()`
- Admin functions protected by admin authorization
- Messenger/Relayer roles enforce separation of concerns

### Fund Safety
- Intent Bridge: Timeout refund guarantees user fund recovery
- Token Forwarder: No custody - immediate transfer to proxy
- TTL management prevents intent expiration fund lockout

### Validation
- Amount > 0 checks on all transfers (source and destination)
- Destination chain and address must be non-empty for intents
- Actual escrowed amount verified via balance delta (handles fee-on-transfer tokens)
- Memo length limit (28 bytes) prevents excessive storage
- Deadline overflow protection with checked arithmetic

## Documentation

- [Token Forwarder Design](docs/DESIGN_FORWARDER.md) - Detailed specification
- [Intent Bridge Design](docs/DESIGN_INTENT_BRIDGE.md) - Detailed specification
- [FAQ](docs/FAQ.md) - Frequently asked questions

## License

BSD-2-Clause
