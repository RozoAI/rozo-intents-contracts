# V1: Stellar Payment Wrapper

A simple Soroban smart contract that wraps cross-chain payments on Stellar, providing on-chain transparency while leveraging existing intent infrastructure.

## Deployed Contract

| Network | Contract Address |
|---------|-----------------|
| Stellar Mainnet | `CAC5SKP5FJT2ZZ7YLV4UCOM6Z5SQCCVPZWHLLLVQNQG2RWWOOSP3IYRL` |

## Overview

V1 is designed as a simple wrapper that:

1. **Accepts USDC payments** with a destination address and memo
2. **Emits on-chain events** for transparency and tracking
3. **Routes funds** to our liquidity pool for fulfillment

### How It Works

```
User                    Payment Contract              Rozo Backend
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

- **Privacy**: Transaction details encoded in memo, not exposed on-chain
- **Speed**: Instant fulfillment when liquidity is available
- **Multi-provider**: Routes to optimal liquidity source (Near Intent for Stellar, Across for EVM, more coming)
- **Cost optimization**: Aggregates multiple sources for best rates
- **Simplicity**: Minimal contract surface area

## Contract Functions

### `init(destination: Address)`

Initialize the contract with a destination address (our liquidity pool).

- Can only be called once
- Sets the destination for all payments
- Configures USDC token address

### `pay(from: Address, amount: i128, memo: String)`

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

### `flush(token_contract: Address, amount: i128)`

Recover tokens accidentally sent to the contract.

### `get_destination() -> Address`

Returns the configured destination address.

### `get_usdc() -> Address`

Returns the USDC token contract address.

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

Users interact through the Rozo frontend which:
1. Calculates fees and exchange rates
2. Encodes the memo with destination details
3. Submits the payment transaction

### For Developers

```rust
// Example: Pay 100 USDC to Base address
let memo = String::from_str(&env, "base:0x1234...abcd:");
payment_client.pay(&user_address, &100_0000000, &memo);
```

## Building

```bash
cd v1/stellar/payment
cargo build --target wasm32-unknown-unknown --release
```

## Testing

```bash
cd v1/stellar/payment
cargo test
```

## Future Roadmap

V1 is a stepping stone. When Circle CCTP launches on Stellar, we will:

1. Activate the full cross-chain architecture in `evm/`, `stellar/`, `relayer/`
2. Enable direct Base <-> Stellar transfers without intermediaries
3. Keep V1 running as an alternative simple path

See [../DESIGN_README.md](../DESIGN_README.md) for the full cross-chain design.
