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
// 1. Set fee recipient
rozoIntents.setFeeRecipient(feeRecipientAddress);

// 2. Set protocol fee (e.g., 3 bps = 0.03%)
rozoIntents.setProtocolFee(3);

// 3. Add Axelar Gateway as messenger
rozoIntents.setMessenger(AXELAR_GATEWAY_ADDRESS, true);

// 4. Set chain ID to Axelar name mapping (REQUIRED for cross-chain routing)
rozoIntents.setChainIdToAxelarName(8453, "base");      // Base
rozoIntents.setChainIdToAxelarName(1500, "stellar");   // Stellar
rozoIntents.setChainIdToAxelarName(42161, "arbitrum"); // Arbitrum (if needed)

// 5. Set trusted contracts for each chain
rozoIntents.setTrustedContract("stellar", "STELLAR_CONTRACT_ADDRESS");
rozoIntents.setTrustedContract("arbitrum", "0x...");

// 6. Add relayers
rozoIntents.addRelayer(relayerAddress1);
rozoIntents.addRelayer(relayerAddress2);
```

**Important:** Step 4 (`setChainIdToAxelarName`) is required for `fillAndNotify()` to route messages correctly. Without this mapping, cross-chain messages will fail.

### 4. Axelar Gateway Addresses

| Network | Gateway Address |
|---------|-----------------|
| Base Mainnet | `0xe432150cce91c13a887f7D836923d5597adD8E31` |
| Base Sepolia | `0xe432150cce91c13a887f7D836923d5597adD8E31` |

> **Note:** Verify addresses at [Axelar Docs](https://docs.axelar.dev/resources/contract-addresses/mainnet/)

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
# Set fee recipient
soroban contract invoke --id $CONTRACT_ID -- set_fee_recipient --recipient $FEE_RECIPIENT

# Set protocol fee (3 bps = 0.03%)
soroban contract invoke --id $CONTRACT_ID -- set_protocol_fee --fee_bps 3

# ============ Axelar Gateway Configuration (REQUIRED) ============
# Set Axelar Gateway address - allows Gateway to call notify()
soroban contract invoke --id $CONTRACT_ID -- set_gateway --gateway $AXELAR_GATEWAY_ADDRESS

# ============ Cross-Chain Routing (REQUIRED) ============
# Map chain IDs to Axelar chain names - required for fillAndNotify() routing
soroban contract invoke --id $CONTRACT_ID -- set_chain_id_to_axelar_name --chain_id 8453 --axelar_name "base"
soroban contract invoke --id $CONTRACT_ID -- set_chain_id_to_axelar_name --chain_id 1500 --axelar_name "stellar"

# Set trusted contracts - verify incoming cross-chain messages
soroban contract invoke --id $CONTRACT_ID -- set_trusted_contract --chain "base" --address "0x..."

# ============ Relayer Management ============
# Add relayers (must be whitelisted on BOTH chains)
soroban contract invoke --id $CONTRACT_ID -- add_relayer --relayer $RELAYER_ADDRESS
```

### Stellar-Specific Configuration Notes

| Config | Purpose | Required? |
|--------|---------|-----------|
| `set_gateway` | Allows Axelar Gateway to call `notify()` | **Yes** |
| `set_chain_id_to_axelar_name` | Routes cross-chain messages correctly | **Yes** |
| `set_trusted_contract` | Verifies source of incoming messages | **Yes** |
| `add_relayer` | Whitelists relayer addresses | **Yes** |
| `set_fee_recipient` | Where protocol fees go | Yes |
| `set_protocol_fee` | Fee percentage (max 30 bps) | Yes |

> **Warning:** Without `set_gateway` and `set_chain_id_to_axelar_name`, your contract cannot receive cross-chain fill notifications. Intents will be stuck in FILLING status forever.

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

# Check messenger is set
cast call $CONTRACT_ADDRESS "messengers(address)(bool)" $AXELAR_GATEWAY

# Check trusted contract
cast call $CONTRACT_ADDRESS "trustedContracts(string)(string)" "stellar"
```

### Verify Axelar Integration

1. Check Axelar Gateway is set as messenger
2. Verify trusted contracts are configured on both chains
3. Test with small amount before production use

---

## Post-Deployment Checklist

- [ ] Contract deployed and verified on block explorer
- [ ] Owner address is correct (multisig recommended)
- [ ] Fee recipient set
- [ ] Protocol fee set (max 30 bps)
- [ ] Axelar Gateway set as messenger
- [ ] **Chain ID to Axelar name mapping configured** (`setChainIdToAxelarName`)
- [ ] Trusted contracts configured for all supported chains
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
| `NotMessenger` error | Verify Axelar Gateway is set as messenger |
| `UntrustedSource` error | Check trustedContracts mapping |
| Cross-chain message not arriving | Check Axelar explorer for message status |
| Relayer cannot fill | Verify relayer is whitelisted on both chains |

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
