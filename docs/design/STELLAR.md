# Stellar Integration

This document covers Stellar-specific implementation details for RozoIntents.

## Address Encoding

### Stellar Address Format

Stellar uses **strkey** encoding for addresses. The common format is `G...` (56 characters) which represents an Ed25519 public key.

```
G... address (strkey) ←→ 32-byte public key ←→ bytes32 (Solidity/ABI)
```

### Converting Stellar Address to bytes32

Stellar G... addresses are already 32 bytes internally. The strkey encoding just adds a version byte and checksum.

**Soroban (Rust):**
```rust
use soroban_sdk::{Address, BytesN, Env};

// G... address string → bytes32
fn stellar_address_to_bytes32(env: &Env, addr: &Address) -> BytesN<32> {
    // Address internally stores 32-byte public key
    addr.to_bytes()
}

// bytes32 → Stellar Address
fn bytes32_to_stellar_address(env: &Env, bytes: &BytesN<32>) -> Address {
    Address::from_bytes(bytes)
}
```

**JavaScript/TypeScript (stellar-sdk):**
```typescript
import { StrKey } from '@stellar/stellar-sdk';

// G... address → bytes32 (hex string)
function stellarAddressToBytes32(gAddress: string): string {
  // Decode G... address to raw 32-byte public key
  const publicKey = StrKey.decodeEd25519PublicKey(gAddress);
  return '0x' + Buffer.from(publicKey).toString('hex');
}

// bytes32 (hex) → G... address
function bytes32ToStellarAddress(bytes32: string): string {
  const bytes = Buffer.from(bytes32.replace('0x', ''), 'hex');
  return StrKey.encodeEd25519PublicKey(bytes);
}

// Example
const gAddress = 'GABC...XYZ';
const bytes32 = stellarAddressToBytes32(gAddress);
// bytes32 = '0x...' (64 hex characters = 32 bytes)
```

### EVM Address to bytes32

EVM addresses are 20 bytes, so they need left-padding with zeros:

```solidity
// Solidity: EVM address → bytes32
bytes32 receiver = bytes32(uint256(uint160(evmAddress)));

// bytes32 → EVM address
address evmAddress = address(uint160(uint256(receiver)));
```

```typescript
// TypeScript: EVM address → bytes32
function evmAddressToBytes32(evmAddress: string): string {
  // Remove 0x, pad to 64 hex chars (32 bytes)
  return '0x' + evmAddress.slice(2).padStart(64, '0');
}

// bytes32 → EVM address (take last 40 hex chars)
function bytes32ToEvmAddress(bytes32: string): string {
  return '0x' + bytes32.slice(-40);
}
```

---

## Token Encoding

### Stellar Token (Asset) Format

Stellar tokens are identified by a **contract address** (for Soroban tokens) or **asset code + issuer** (for classic assets wrapped in SAC).

For RozoIntents, we use the **token contract address** which is also a 32-byte value.

**Stellar USDC (Mainnet):**
```
Contract: CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA
```

**Converting Token Contract to bytes32:**
```typescript
import { StrKey } from '@stellar/stellar-sdk';

// Contract address (C...) → bytes32
function stellarContractToBytes32(contractAddress: string): string {
  const bytes = StrKey.decodeContract(contractAddress);
  return '0x' + Buffer.from(bytes).toString('hex');
}

// Example
const usdcContract = 'CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA';
const bytes32Token = stellarContractToBytes32(usdcContract);
```

### Token Decimals

| Chain | USDC Decimals |
|-------|---------------|
| Stellar | 7 |
| Base | 6 |
| Ethereum | 6 |

**Important:** Contract does NOT convert decimals. Frontend must handle conversion.

```typescript
// Example: 100 USDC
const stellarAmount = 100_0000000n;  // 7 decimals
const baseAmount = 100_000000n;      // 6 decimals
```

---

## Soroban Contract Interface

### RozoIntents Stellar Functions

```rust
// Create intent (sender deposits funds)
pub fn create_intent(
    env: Env,
    intent_id: BytesN<32>,
    source_token: Address,           // Stellar token contract
    source_amount: i128,
    destination_chain_id: u64,       // e.g., 8453 for Base
    destination_token: BytesN<32>,   // EVM token as bytes32
    receiver: BytesN<32>,            // EVM address as bytes32
    destination_amount: i128,
    deadline: u64,
    refund_address: Address,
) -> Result<(), Error>;

// Fill intent (relayer claims)
pub fn fill(env: Env, intent_id: BytesN<32>) -> Result<(), Error>;

// Refund expired intent
pub fn refund(env: Env, intent_id: BytesN<32>) -> Result<(), Error>;

// Receive notification from Axelar (destination → source)
pub fn notify(
    env: Env,
    source_chain: String,
    source_address: String,
    payload: Bytes,
) -> Result<(), Error>;
```

### Destination Chain Functions (Stellar as destination)

```rust
pub fn fill_and_notify(
    env: Env,
    intent_data: IntentData,
    repayment_address: BytesN<32>,
    messenger_id: u8
) -> Result<(), Error>;

// Relayer retries sending notification if initial messenger fails
pub fn retry_notify(
    env: Env,
    intent_data: IntentData,
    messenger_id: u8
) -> Result<(), Error>;
```

---

## Stellar Token Operations

### Transfer Tokens (SEP-41)

```rust
use soroban_sdk::token;

fn transfer_tokens(
    env: &Env,
    token_address: &Address,
    from: &Address,
    to: &Address,
    amount: i128,
) {
    let token_client = token::Client::new(env, token_address);
    token_client.transfer(from, to, &amount);
}
```

### Check Balance

```rust
fn get_balance(env: &Env, token_address: &Address, account: &Address) -> i128 {
    let token_client = token::Client::new(env, token_address);
    token_client.balance(account)
}
```

### Approve Spending

```rust
fn approve_tokens(
    env: &Env,
    token_address: &Address,
    from: &Address,
    spender: &Address,
    amount: i128,
    expiration_ledger: u32,
) {
    let token_client = token::Client::new(env, token_address);
    token_client.approve(from, spender, &amount, &expiration_ledger);
}
```

---

## Axelar Integration on Stellar

### Axelar Gateway

Stellar uses Axelar's GMP (General Message Passing) for cross-chain messaging.

```rust
use axelar_soroban_interfaces::gateway::GatewayClient;

fn send_axelar_message(
    env: &Env,
    gateway: &Address,
    destination_chain: String,
    destination_address: String,
    payload: Bytes,
) {
    let gateway_client = GatewayClient::new(env, gateway);
    gateway_client.call_contract(
        &env.current_contract_address(),
        &destination_chain,
        &destination_address,
        &payload,
    );
}
```

### Receiving Axelar Messages

```rust
// Called by Axelar Gateway when message arrives
pub fn execute(
    env: Env,
    source_chain: String,
    source_address: String,
    payload: Bytes,
) -> Result<(), Error> {
    // Verify caller is Axelar Gateway
    let gateway = env.storage().instance().get(&DataKey::Gateway)?;
    gateway.require_auth();

    // Verify source is trusted
    let trusted = env.storage().instance().get(&DataKey::TrustedContract(source_chain.clone()))?;
    if trusted != source_address {
        return Err(Error::UntrustedSource);
    }

    // Process payload...
    Ok(())
}
```

---

## Cross-Chain Message Format

### Payload Encoding

Messages between chains use **Solidity ABI encoding** format. Each value must occupy exactly **32 bytes**.

> **Important:** Solidity's `abi.encode` pads all values to 32 bytes. Stellar code must match this format exactly, or `notify()` on EVM will fail to decode.

### ABI Encoding Rules

| Type | Size | Padding |
|------|------|---------|
| `bytes32` | 32 bytes | None needed |
| `uint256` | 32 bytes | Left-pad with zeros |
| `i128` (Stellar) | 16 bytes | **Must left-pad to 32 bytes** |
| `address` (EVM) | 20 bytes | Left-pad to 32 bytes |

### Encoding Payload (Stellar → EVM)

This function encodes the `notify` payload to match Solidity's `abi.encode` format, which is required for the EVM contract to decode it correctly.

```rust
use soroban_sdk::{Bytes, BytesN, Env};

/// Encode i128 as 32-byte big-endian (ABI uint256 compatible)
/// i128 is 16 bytes, must left-pad with 16 zero bytes
fn i128_to_abi_bytes(env: &Env, value: i128) -> Bytes {
    let mut result = Bytes::new(env);
    for _ in 0..16 { result.push_back(0u8); } // Left-pad with 16 zeros
    for byte in value.to_be_bytes() { result.push_back(byte); }
    result
}

/// Encode notify payload matching Solidity's abi.encode format
/// Total: 4 * 32 = 128 bytes
fn encode_notify_payload(
    env: &Env,
    intent_id: BytesN<32>,
    fill_hash: BytesN<32>,
    repayment_address: BytesN<32>,
    relayer: BytesN<32>
) -> Bytes {
    let mut payload = Bytes::new(env);

    // Each field must be exactly 32 bytes
    payload.append(&Bytes::from_slice(env, &intent_id.to_array()));
    payload.append(&Bytes::from_slice(env, &fill_hash.to_array()));
    payload.append(&Bytes::from_slice(env, &repayment_address.to_array()));
    payload.append(&Bytes::from_slice(env, &relayer.to_array()));

    payload
}
```

### Decoding Payload (EVM → Stellar)

This is the reverse process for when Stellar is the source chain and needs to decode a payload sent from an EVM chain.

```rust
/// Decode payload from EVM's abi.encode format
fn decode_payload(env: &Env, payload: &Bytes) -> Result<(BytesN<32>, BytesN<32>, BytesN<32>, BytesN<32>), Error> {
    if payload.len() != 128 {
        return Err(Error::InvalidPayloadLength);
    }

    let intent_id = BytesN::from_slice(env, &payload.slice(0..32).to_array());
    let fill_hash = BytesN::from_slice(env, &payload.slice(32..64).to_array());
    let repayment_address = BytesN::from_slice(env, &payload.slice(64..96).to_array());
    let relayer = BytesN::from_slice(env, &payload.slice(96..128).to_array());

    Ok((intent_id, fill_hash, repayment_address, relayer))
}
```

### Payload Structure Diagram

```
Offset    Field              Size     Notes
──────────────────────────────────────────────────────
0-31      intentId           32       bytes32
32-63     fillHash           32       bytes32
64-95     repaymentAddress   32       bytes32
96-127    relayer      32       bytes32
──────────────────────────────────────────────────────
Total:                       128 bytes
```

### Verification Example

```rust
// Test that encoding produces correct length
#[test]
fn test_payload_encoding() {
    let env = Env::default();

    let payload = encode_notify_payload(
        &env,
        BytesN::from_array(&env, &[1u8; 32]),  // intentId
        1000_0000000i128,                       // 1000 USDC (7 decimals)
        BytesN::from_array(&env, &[2u8; 32]),  // relayer
        BytesN::from_array(&env, &[3u8; 32]),  // receiver
        BytesN::from_array(&env, &[4u8; 32]),  // destToken
    );

    assert_eq!(payload.len(), 160);  // Must be exactly 160 bytes
}
```

---

## Common Patterns

### Intent ID Generation

Same pattern as EVM - generate off-chain:

```typescript
import { keccak256, toUtf8Bytes } from 'ethers';
import { v4 as uuidv4 } from 'uuid';

function generateIntentId(): string {
  const uuid = uuidv4();
  return keccak256(toUtf8Bytes(uuid));
}
```

### Deadline Handling

Stellar uses **ledger sequence numbers** internally, but for cross-chain compatibility, use Unix timestamps:

```rust
// Check deadline (Unix timestamp in seconds)
fn is_expired(env: &Env, deadline: u64) -> bool {
    let current_time = env.ledger().timestamp();
    current_time >= deadline
}
```

---

## Testing on Stellar

### Testnet Configuration

```bash
# Add Stellar testnet
soroban config network add testnet \
  --rpc-url https://soroban-rpc.testnet.stellar.gateway.fm \
  --network-passphrase "Test SDF Network ; September 2015"

# Get testnet funds
curl "https://friendbot.stellar.org?addr=YOUR_PUBLIC_KEY"
```

### Deploy and Test

```bash
# Build
cargo build --release --target wasm32-unknown-unknown

# Deploy
soroban contract deploy \
  --wasm target/wasm32-unknown-unknown/release/rozo_intents.wasm \
  --source $SECRET_KEY \
  --network testnet

# Invoke function
soroban contract invoke \
  --id $CONTRACT_ID \
  --source $SECRET_KEY \
  --network testnet \
  -- \
  create_intent \
  --intent_id $INTENT_ID \
  --source_token $USDC_ADDRESS \
  ...
```

---

## See Also

### Design
- [DESIGN.md](./DESIGN.md) - Architecture overview
- [DATA_STRUCTURES.md](./DATA_STRUCTURES.md) - Contract interfaces
- [GLOSSARY.md](./GLOSSARY.md) - Terms and chain IDs

### Development
- [DEPLOYMENT.md](../development/DEPLOYMENT.md) - Deployment guide
- [TESTING.md](../development/TESTING.md) - Testing guide

### External
- [Soroban Docs](https://soroban.stellar.org/docs)
- [Stellar SDK](https://stellar.github.io/js-stellar-sdk/)
- [Axelar Stellar GMP](https://github.com/axelarnetwork/axelar-cgp-soroban)
