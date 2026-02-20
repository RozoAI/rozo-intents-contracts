# ROZO Intents V1: Cross-Chain Payment Contracts

**Website:** [https://www.rozo.ai/](https://www.rozo.ai/)

Smart contracts for cross-chain payments on Stellar and EVM chains, providing on-chain transparency while leveraging existing intent infrastructure.

ROZO Intents is a stablecoin abstraction that lets users express what they want to do—pay or earn—without worrying about how it's executed onchain.

## Deployed Contracts

### Stellar

| Network | Contract Address | Verification |
|---------|-----------------|--------------|
| Mainnet | `CAC5SKP5FJT2ZZ7YLV4UCOM6Z5SQCCVPZWHLLLVQNQG2RWWOOSP3IYRL` | [StellarExpert](https://stellar.expert/explorer/public/contract/CAC5SKP5FJT2ZZ7YLV4UCOM6Z5SQCCVPZWHLLLVQNQG2RWWOOSP3IYRL) |
| Testnet | `CAAAPVRAQWPZXRHQS2F44HWL7K3ZFDJJOPKG6WM4RAZ2VYDT63LQVROF` | [StellarExpert](https://stellar.expert/explorer/testnet/contract/CAAAPVRAQWPZXRHQS2F44HWL7K3ZFDJJOPKG6WM4RAZ2VYDT63LQVROF) |

### EVM (Base)

| Network | Contract | Address | Verification |
|---------|----------|---------|--------------|
| Base Mainnet | MPForwarderV2 | *Coming soon* | - |
| Base Sepolia | MPForwarderV2 | *Coming soon* | - |

## Overview

V1 is designed as a simple wrapper that:

1. **Accepts USDC payments** with a destination address and memo
2. **Emits on-chain events** for transparency and tracking
3. **Routes funds** to our liquidity pool for fulfillment

### How It Works

```
User                    Payment Contract              ROZO Backend
  |                           |                            |
  |-- pay(amount, memo) ----->|                            |
  |                           |-- PaymentEvent ----------->|
  |                           |                            |
  |                           |                    Check liquidity
  |                           |                            |
  |                           |              If liquidity: Instant fill
  |                           |              Else: Route to best provider
  |                           |                    (Near Intent, Across, etc.)
  |                           |                            |
  |<------------------- Receive funds on destination ------|
```

### Key Features

- **Non-Custodial**: Contract never holds user funds—USDC flows directly to destination, no asset breach risk
- **Privacy**: Transaction details encoded in memo, not exposed on-chain
- **Speed**: Users receive funds within seconds
- **Multi-provider**: Routes to optimal liquidity source (Near Intent for Stellar, Across for EVM, more coming)
- **Cost optimization**: Aggregates multiple sources for best rates
- **Simplicity**: Minimal contract surface area
- **Transparent**: Track any transaction status at [intents.rozo.ai/status](https://intents.rozo.ai/status)

---

## Stellar Contract

### Contract Functions

#### `init(destination: Address)`

Initialize the contract with a destination address (our liquidity pool).

- Can only be called once
- Sets the destination for all payments
- Configures USDC token address

#### `pay(from: Address, amount: i128, memo: String)`

Submit a payment for cross-chain transfer.

**Parameters:**
- `from`: The sender's address (must authorize the transaction)
- `amount`: Amount of USDC to send (in stroops, 1 USDC = 10^7 stroops)
- `memo`: Encoded destination information (chain, address, etc.)

**Events Emitted:**
```rust
PaymentEvent {
    from: Address,      // Sender
    destination: Address, // Liquidity pool
    amount: i128,       // Amount in stroops
    memo: String,       // Routing information
}
```

#### `flush(token_contract: Address, amount: i128)`

Recover tokens accidentally sent to the contract.

#### `get_destination() -> Address`

Returns the configured destination address.

#### `get_usdc() -> Address`

Returns the USDC token contract address.

### Building

```bash
cd v1/stellar/payment
cargo build --target wasm32-unknown-unknown --release
stellar contract optimize --wasm target/wasm32-unknown-unknown/release/payment.wasm
```

### Testing

```bash
cd v1/stellar/payment
cargo test
```

---

## EVM Contract (MPForwarderV2)

The EVM contract is a payment forwarder that receives funds and routes them to the destination address.

### Contract Functions

#### `init(destination: address, relayer: address)`

Initialize the contract with destination and relayer addresses.

- Can only be called once
- Sets the destination for all flushes
- Sets the relayer for controlled transfers

#### `initAndFlush(destination, relayer, initType, tokenAddress, to, amount)`

Initialize and immediately perform a transfer/flush operation.

**InitType enum:**
- `NONE`: No action
- `TRANSFER_ETH`: Transfer ETH amount to `to`, flush remainder
- `TRANSFER_ERC20`: Transfer ERC20 amount to `to`, flush remainder
- `TRANSFER_USDT`: Transfer USDT amount to `to`, flush remainder
- `FLUSH_ETH`: Flush all ETH to destination
- `FLUSH_ERC20`: Flush all ERC20 to destination
- `FLUSH_USDT`: Flush all USDT to destination

#### `transferETH(to: address, amount: uint256)` (relayer only)

Transfer ETH to recipient, flush remainder to destination.

#### `transferERC20(tokenContractAddress, to, amount)` (relayer only)

Transfer ERC20 tokens to recipient, flush remainder to destination.

#### `transferUSDT(tokenContractAddress, to, amount)` (relayer only)

Transfer USDT to recipient (uses non-standard transfer), flush remainder.

#### `flushETH()` (public)

Flush all ETH balance to destination.

#### `flushERC20(tokenContractAddress)` (public)

Flush all ERC20 balance to destination.

#### `flushUSDT(tokenContractAddress)` (public)

Flush all USDT balance to destination.

### Building

```bash
cd v1/evm
forge build
```

### Testing

```bash
cd v1/evm
forge test
```

### Deploying

```bash
cd v1/evm
forge script script/CreateAccounts.s.sol --rpc-url <RPC_URL> --broadcast
```

---

## Memo Format

The memo field encodes the cross-chain routing information:

```
{destination_chain}:{destination_address}:{additional_data}
```

Example:
```
base:0x1234...abcd:
```

## Integration

### For Users (via Frontend)

Users interact through the ROZO frontend ([rozo.ai](https://www.rozo.ai/)) which:
1. Calculates fees and exchange rates
2. Encodes the memo with destination details
3. Submits the payment transaction

### For Developers

**Stellar:**
```rust
// Example: Pay 100 USDC to Base address
let memo = String::from_str(&env, "base:0x1234...abcd:");
payment_client.pay(&user_address, &100_0000000, &memo);
```

**EVM:**
```solidity
// Funds are sent to the forwarder address
// Relayer calls transferERC20 to route to user
forwarder.transferERC20(usdcAddress, userAddress, amount);
```

## Build & Verification

This contract uses [stellar-expert/soroban-build-workflow](https://github.com/stellar-expert/soroban-build-workflow) for reproducible builds.

To trigger a new release:
```bash
git tag v1.0.1 && git push origin v1.0.1
```

## Links

- **Website**: [https://www.rozo.ai/](https://www.rozo.ai/)
- **Transaction Status**: [https://intents.rozo.ai/status](https://intents.rozo.ai/status)
- **Full Cross-Chain Design**: [DESIGN_README.md](../DESIGN_README.md)
