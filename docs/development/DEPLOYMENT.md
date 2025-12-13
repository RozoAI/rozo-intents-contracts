# RozoIntents Deployment Guide

This guide covers deploying and configuring RozoIntents contracts on supported chains.

## Prerequisites

- Node.js 18+ and npm/yarn
- Foundry (for EVM) or Soroban CLI (for Stellar)
- Private keys for deployer accounts
- Funded accounts on target chains

## Contract Overview

| Chain | Contract | Description |
|-------|----------|-------------|
| Base | `RozoIntents.sol` | Source chain contract (also destination for Stellar→Base) |
| Stellar | `rozo_intents.rs` | Source chain contract (also destination for Base→Stellar) |

Both contracts serve as both source and destination depending on flow direction.

---

## EVM Deployment (Base)

### 1. Environment Setup

Create `.env` file:
```bash
PRIVATE_KEY=0x...
BASE_RPC_URL=https://mainnet.base.org
ETHERSCAN_API_KEY=...
```

### 2. Deploy Contract

```bash
# Using Foundry
forge create src/RozoIntents.sol:RozoIntents \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args $OWNER_ADDRESS
```

### 3. Configure Contract

After deployment, run these admin functions:

```solidity
// ============ 1. Fee Configuration ============
rozoIntents.setFeeRecipient(feeRecipientAddress);
rozoIntents.setProtocolFee(3);  // 3 bps = 0.03%

// ============ 2. Deploy & Register Messenger Adapters ============
// Deploy Rozo adapter (fast, ~1-3 sec)
RozoMessengerAdapter rozoAdapter = new RozoMessengerAdapter(ROZO_TRUSTED_SIGNER);

// Deploy Axelar adapter (decentralized, ~5-10 sec)
AxelarMessengerAdapter axelarAdapter = new AxelarMessengerAdapter(AXELAR_GATEWAY_ADDRESS);

// Register adapters (auto-assigns by messengerId from adapter)
rozoIntents.setMessengerAdapter(address(rozoAdapter));   // ID 0 (Rozo)
rozoIntents.setMessengerAdapter(address(axelarAdapter)); // ID 1 (Axelar)

// ============ 3. Configure Adapters ============
// Rozo adapter: set trusted contracts per chain
rozoAdapter.setTrustedContract(1500, bytes32(STELLAR_CONTRACT_ADDRESS));  // Stellar
rozoAdapter.setTrustedContract(8453, bytes32(BASE_CONTRACT_ADDRESS));     // Base

// Axelar adapter: set chain name mapping and trusted contracts
axelarAdapter.setChainMapping(8453, "base");
axelarAdapter.setChainMapping(1500, "stellar");
axelarAdapter.setTrustedContract("stellar", "STELLAR_CONTRACT_ADDRESS");
axelarAdapter.setTrustedContract("base", "0x...");

// ============ 4. Relayer Management ============
// RelayerType: 0=NONE, 1=ROZO, 2=EXTERNAL
rozoIntents.addRelayer(rozoRelayerAddress, 1);      // ROZO relayer (can fill as fallback)
rozoIntents.addRelayer(externalRelayerAddress, 2); // External relayer

// ============ 5. Rozo Fallback Configuration ============
rozoIntents.setRozoRelayer(rozoRelayerAddress);
rozoIntents.setRozoRelayerThreshold(10);  // 10 seconds
```

**Important:** Messenger adapters must be configured with trusted contracts before they can verify cross-chain messages.

### 4. Axelar Gateway Addresses

| Network | Gateway Address |
|---------|-----------------|
| Base Mainnet | `0xe432150cce91c13a887f7D836923d5597adD8E31` |
| Base Sepolia | `0xe432150cce91c13a887f7D836923d5597adD8E31` |

> **Note:** Verify addresses at [Axelar Docs](https://docs.axelar.dev/resources/contract-addresses/mainnet/)

### 5. Deployed Contract Addresses

<!-- TODO: Fill in addresses after mainnet deployment -->

| Network | Contract | Address |
|---------|----------|---------|
| **Base Mainnet** | RozoIntents | `TODO` |
| **Base Mainnet** | RozoMessengerAdapter | `TODO` |
| **Base Mainnet** | AxelarMessengerAdapter | `TODO` |
| **Base Sepolia** | RozoIntents | `TODO` |
| **Stellar Mainnet** | RozoIntents | `TODO` |
| **Stellar Testnet** | RozoIntents | `TODO` |

| Token | Network | Address |
|-------|---------|---------|
| USDC | Base Mainnet | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| USDC | Base Sepolia | `TODO` |
| USDC | Stellar Mainnet | `CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA` |
| USDC | Stellar Testnet | `TODO` |

> **Note:** Contract addresses will be published after mainnet deployment. For testnet access, contact [hi@rozo.ai](mailto:hi@rozo.ai).

---

## Stellar Deployment

### 1. Environment Setup

```bash
# Install Soroban CLI
cargo install soroban-cli

# Configure network
soroban config network add mainnet \
  --rpc-url https://soroban-rpc.mainnet.stellar.gateway.fm \
  --network-passphrase "Public Global Stellar Network ; September 2015"
```

### 2. Build Contract

```bash
cd stellar-contracts
cargo build --release --target wasm32-unknown-unknown
```

### 3. Deploy Contract

```bash
soroban contract deploy \
  --wasm target/wasm32-unknown-unknown/release/rozo_intents.wasm \
  --source $SECRET_KEY \
  --network mainnet
```

### 4. Initialize Contract

```bash
soroban contract invoke \
  --id $CONTRACT_ID \
  --source $SECRET_KEY \
  --network mainnet \
  -- \
  initialize \
  --owner $OWNER_ADDRESS
```

### 5. Configure Contract

```bash
# ============ Fee Configuration ============
soroban contract invoke --id $CONTRACT_ID -- set_fee_recipient --recipient $FEE_RECIPIENT
soroban contract invoke --id $CONTRACT_ID -- set_protocol_fee --fee_bps 3

# ============ Messenger Adapter Configuration ============
# Deploy and register Rozo adapter
soroban contract invoke --id $CONTRACT_ID -- set_messenger_adapter --adapter $ROZO_ADAPTER_ADDRESS

# Deploy and register Axelar adapter
soroban contract invoke --id $CONTRACT_ID -- set_messenger_adapter --adapter $AXELAR_ADAPTER_ADDRESS

# ============ Configure Adapters (on adapter contracts) ============
# Rozo adapter: set trusted signer and contracts
soroban contract invoke --id $ROZO_ADAPTER_ID -- set_trusted_signer --signer $ROZO_SIGNER
soroban contract invoke --id $ROZO_ADAPTER_ID -- set_trusted_contract --chain_id 8453 --address $BASE_CONTRACT

# Axelar adapter: set chain mapping and trusted contracts
soroban contract invoke --id $AXELAR_ADAPTER_ID -- set_chain_mapping --chain_id 8453 --axelar_name "base"
soroban contract invoke --id $AXELAR_ADAPTER_ID -- set_chain_mapping --chain_id 1500 --axelar_name "stellar"
soroban contract invoke --id $AXELAR_ADAPTER_ID -- set_trusted_contract --chain "base" --address "0x..."

# ============ Relayer Management ============
# RelayerType: 0=NONE, 1=ROZO, 2=EXTERNAL
soroban contract invoke --id $CONTRACT_ID -- add_relayer --relayer $ROZO_RELAYER_ADDRESS --relayer_type 1
soroban contract invoke --id $CONTRACT_ID -- add_relayer --relayer $EXTERNAL_RELAYER_ADDRESS --relayer_type 2

# ============ Rozo Fallback Configuration ============
soroban contract invoke --id $CONTRACT_ID -- set_rozo_relayer --relayer $ROZO_RELAYER_ADDRESS
soroban contract invoke --id $CONTRACT_ID -- set_rozo_relayer_threshold --threshold 10
```

### Stellar-Specific Configuration Notes

| Config | Purpose | Required? |
|--------|---------|-----------|
| `set_messenger_adapter` | Registers messenger adapters (Rozo, Axelar) | **Yes** |
| `set_trusted_contract` (on adapters) | Verifies source of incoming messages | **Yes** |
| `add_relayer` | Whitelists relayer addresses | **Yes** |
| `set_rozo_relayer` | Configures fallback relayer | **Yes** |
| `set_fee_recipient` | Where protocol fees go | Yes |
| `set_protocol_fee` | Fee percentage (max 30 bps) | Yes |

> **Warning:** Without configured messenger adapters, your contract cannot receive cross-chain fill notifications. Intents will be stuck in PENDING status.

---

## Cross-Chain Configuration

### Trusted Contracts Setup

Each chain must trust the other chain's contract:

```
Base Contract:
  trustedContracts["stellar"] = "STELLAR_CONTRACT_ADDRESS"

Stellar Contract:
  trustedContracts["base"] = "0xBASE_CONTRACT_ADDRESS"
```

### Chain Name Reference

| Chain | Axelar Chain Name |
|-------|-------------------|
| Base | `base` |
| Stellar | `stellar` |
| Ethereum | `ethereum` |
| Arbitrum | `arbitrum` |

---

## Verification

### Verify Deployment

```bash
# EVM - Check contract state
cast call $CONTRACT_ADDRESS "owner()(address)"
cast call $CONTRACT_ADDRESS "protocolFee()(uint256)"
cast call $CONTRACT_ADDRESS "feeRecipient()(address)"

# Check messenger adapters are registered
cast call $CONTRACT_ADDRESS "messengerAdapters(uint8)(address)" 0  # Rozo
cast call $CONTRACT_ADDRESS "messengerAdapters(uint8)(address)" 1  # Axelar

# Check Rozo fallback configuration
cast call $CONTRACT_ADDRESS "rozoRelayer()(address)"
cast call $CONTRACT_ADDRESS "rozoRelayerThreshold()(uint256)"
```

### Verify Messenger Adapters

1. Check Rozo adapter has trusted signer configured
2. Check Axelar adapter has gateway address configured
3. Verify trusted contracts are configured on both adapters
4. Test with small amount before production use

---

## Post-Deployment Checklist

- [ ] Contract deployed and verified on block explorer
- [ ] Owner address is correct (multisig recommended)
- [ ] Fee recipient set
- [ ] Protocol fee set (max 30 bps)
- [ ] **Messenger adapters deployed and registered** (Rozo + Axelar)
- [ ] **Rozo adapter trusted signer configured**
- [ ] **Axelar adapter chain mappings configured**
- [ ] Trusted contracts configured on all adapters
- [ ] Rozo fallback relayer and threshold configured
- [ ] Relayers whitelisted on both source and destination chains
- [ ] Test transaction completed successfully

---

## Security Considerations

1. **Owner should be multisig** - Use Gnosis Safe or similar
2. **Verify all addresses** - Double-check before setting trusted contracts
3. **Start with testnet** - Deploy to testnets first
4. **Monitor events** - Set up event monitoring for admin actions
5. **Limit initial relayers** - Start with trusted relayers only

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `InvalidMessenger` error | Verify messenger adapters are registered (`messengerAdapters[id]`) |
| `UntrustedSource` error | Check adapter's trustedContracts mapping |
| `InvalidSignature` error (Rozo) | Verify Rozo adapter has correct trusted signer |
| `NotApproved` error (Axelar) | Message not approved by Axelar validators; check Axelar explorer |
| Cross-chain message not arriving | Check Rozo dashboard or Axelar explorer for message status |
| Relayer cannot fill | Verify relayer is whitelisted on both chains |
| `NotAssignedRelayer` error | Only assigned relayer (or Rozo fallback after threshold) can fill |

---

## See Also

### Design
- [DESIGN.md](../design/DESIGN.md) - Architecture overview
- [DATA_STRUCTURES.md](../design/DATA_STRUCTURES.md) - Contract interfaces

### Development
- [TESTING.md](./TESTING.md) - Testing guide
- [RELAYER.md](./RELAYER.md) - Relayer guide

### External
- [Axelar Docs](https://docs.axelar.dev/) - Axelar GMP documentation
