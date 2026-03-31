# Frequently Asked Questions (FAQ)

## General

### What is Rozo Intents V2?

Rozo Intents V2 is a set of Soroban smart contracts that enable cross-chain token forwarding and bridging on Stellar. It consists of two contracts:
- **Token Forwarder**: Enables bidirectional transfers between Smart Wallets (C Accounts) and Stellar Accounts (G Accounts)
- **Intent Bridge**: Escrow-based cross-chain intent system with timeout protection

### Why do we need these contracts?

Stellar Smart Wallets (C Accounts) cannot transfer or receive tokens with memo. This creates problems for users who want to:
- Deposit to centralized exchanges (Binance, Coinbase) which require memos
- Receive funds from exchanges to their Smart Wallets
- Use cross-chain liquidity providers that don't support contract invocation

See: [Stellar Smart Wallets Documentation](https://developers.stellar.org/docs/build/guides/contract-accounts/smart-wallets)

### What tokens are supported?

The contracts support any Stellar token (SEP-41 compatible), including:

| Token | Mainnet Address | Decimals |
|-------|-----------------|----------|
| XLM (Native) | `CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA` | 7 |
| USDC (Circle) | `CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75` | 7 |
| EURC (Circle) | `CDTKPWPLOURQA2SGTKTUQOWRCBFJ2LFVGWAGDOCKIQTYUEDTPLAPMFKQ` | 7 |

---

## Token Forwarder

### How does the C Wallet → G Wallet flow work?

1. User calls `forward(token, amount, to, memo)` from their Smart Wallet
2. Contract transfers tokens to the proxy address (G Account)
3. Contract emits a `ForwardEvent` with the destination address and memo
4. Backend monitors the event and sends tokens to the final destination with memo

### How does the G Wallet → C Wallet flow work?

1. Admin pre-registers memo mappings: `set_memo_mapping("user123", C_ADDRESS)`
2. Exchange user sends tokens to Proxy with memo "user123"
3. Backend detects payment to Proxy
4. Backend calls `get_memo_destination("user123")` to get the destination
5. Backend transfers tokens to the Smart Wallet

### Why is there a 28-byte memo limit?

Stellar's native memo field has a 28-byte limit for text memos. We enforce this limit to ensure compatibility with Stellar's memo system and prevent excessive storage costs.

### Can I send to any address?

Yes, the `to` field in `forward()` accepts any string - it can be a Stellar address, EVM address, or any destination identifier. The backend interprets this field based on the routing logic.

### What happens if I send to the wrong address?

Tokens are transferred immediately to the proxy address. If the `to` address is incorrect, the backend may not be able to complete the transfer. Always double-check addresses before sending.

---

## Intent Bridge

### What is an "intent"?

An intent is a user's request to transfer tokens cross-chain. It includes:
- Source token and amount
- Destination chain, address, and amount
- A deadline for completion
- Optional memo

### What are the possible intent states?

| State | Description |
|-------|-------------|
| PENDING | Intent created, funds locked |
| FILLED | Cross-chain transfer confirmed, funds released to Relayer |
| REFUNDED | Deadline passed, funds returned to user |

### What happens if my intent is not filled?

If the Messenger doesn't call `fill()` before the deadline, you can call `refund()` to reclaim your tokens. The contract guarantees you can always get your funds back after the deadline.

### How long is the deadline?

The default deadline is 24 hours (86400 seconds), configurable during contract deployment via `deadline_duration`. `deadline_duration` must be greater than 0; the constructor returns `Error::InvalidDeadlineDuration` if zero is provided.

### Who are the Messenger and Relayer?

| Role | Responsibility |
|------|----------------|
| **Messenger** | Confirms cross-chain message completion, calls `fill()` |
| **Relayer** | Receives locked funds, executes on destination chain |

In early stages, both roles may be the same address operated by Rozo.

### Can anyone call fill() or refund()?

- `fill()` - Only the Messenger can call this
- `refund()` - Only the original sender can call this (after deadline)

---

## Security

### Are the contracts audited?

The contracts have been audited by Hacken (March 2026). All findings have been remediated. The contracts were also scanned with [Scout Soroban](https://github.com/CoinFabrik/scout-soroban) by CoinFabrik. See [audits/scout-report.md](../audits/scout-report.md) for details.

### Can my funds get stuck?

**Token Forwarder**: No custody - tokens transfer immediately to proxy.

**Intent Bridge**: Funds are locked until either:
- Messenger calls `fill()` (before deadline)
- You call `refund()` (after deadline)

The contract guarantees you can always recover funds after the deadline.

### What if the Messenger/Relayer goes offline?

Your funds are protected by the deadline mechanism. If the Messenger doesn't fill your intent, you can refund after the deadline. No trusted party can permanently lock your funds.

### Is the admin privileged?

The admin can:
- Update the proxy address
- Set/remove memo mappings
- Flush stuck tokens (for recovery purposes)

The admin **cannot**:
- Access user funds in transit
- Prevent refunds after deadline
- Modify intent data

---

## Technical

### What Soroban SDK version is used?

Currently using **soroban-sdk v22.0.11**.

### How is the intent_id generated?

The intent_id is a SHA256 hash of:
- sender address
- timestamp
- ledger sequence
- source token
- source amount
- destination chain
- destination address
- destination amount
- memo

This ensures collision resistance and uniqueness.

### What is TTL management?

Soroban persistent storage has a time-to-live (TTL). The Intent Bridge extends TTL on every operation to prevent intent data from expiring and causing fund lockout.

- **Threshold**: 7 days (~120,960 ledgers)
- **Extension**: 14 days (~241,920 ledgers)

### How do I integrate with these contracts?

1. **For C→G transfers**: Call `forward()` with your token, amount, destination, and memo
2. **For G→C transfers**: Contact Rozo to set up a memo mapping for your Smart Wallet
3. **For cross-chain intents**: Call `create_intent()` with your transfer details

See the design docs for detailed interface specifications:
- [Token Forwarder Design](DESIGN_FORWARDER.md)
- [Intent Bridge Design](DESIGN_INTENT_BRIDGE.md)

---

## Contact

For more questions, please contact: **hi@rozo.ai**
