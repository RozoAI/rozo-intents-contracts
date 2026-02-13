# ROZO Intents V1: Stellar Payment Wrapper

**Website:** [https://www.rozo.ai/](https://www.rozo.ai/)

A simple Soroban smart contract that wraps cross-chain payments on Stellar, providing on-chain transparency while leveraging existing intent infrastructure.

ROZO Intents is a stablecoin abstraction that lets users express what they want to do—pay or earn—without worrying about how it's executed onchain.

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

Users interact through the ROZO frontend ([rozo.ai](https://www.rozo.ai/)) which:
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

## Contract Verification

This contract uses [stellar-expert/soroban-build-workflow](https://github.com/stellar-expert/soroban-build-workflow) for reproducible builds and verification.

### Verify on StellarExpert

1. Go to [StellarExpert Contract Validation](https://stellar.expert/explorer/public/contract/validation)
2. Enter contract address: `CAC5SKP5FJT2ZZ7YLV4UCOM6Z5SQCCVPZWHLLLVQNQG2RWWOOSP3IYRL`
3. The validator will compare the deployed WASM with our GitHub release artifacts

### Build Reproducibility

Our GitHub Actions workflow (`.github/workflows/release.yml`) automatically:
- Compiles contracts into optimized WebAssembly
- Creates GitHub releases with artifacts
- Generates SHA256 hashes for verification
- Produces build attestations

To trigger a release:
- Push a git tag: `git tag v1.0.0 && git push origin v1.0.0`
- Or manually trigger via GitHub Actions UI

## Future Roadmap

V1 is a stepping stone. When Circle CCTP launches on Stellar, we will:

1. Activate the full cross-chain architecture in `evm/`, `stellar/`, `relayer/`
2. Enable direct Base <-> Stellar transfers without intermediaries
3. Keep V1 running as an alternative simple path

See [../DESIGN_README.md](../DESIGN_README.md) for the full cross-chain design.

## Links

- **Website**: [https://www.rozo.ai/](https://www.rozo.ai/)
- **Transaction Status**: [https://intents.rozo.ai/status](https://intents.rozo.ai/status)
- **Main Repository**: [../README.md](../README.md)
- **Contract Verification**: [StellarExpert](https://stellar.expert/explorer/public/contract/validation)
