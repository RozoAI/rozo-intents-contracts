# RozoIntents Glossary

## Supported Chains (Bidirectional)

| Chain | Chain ID | Chain Name (Axelar) | Notes |
|-------|----------|---------------------|-------|
| Base | 8453 | `base` | EVM chain (official chain ID) |
| Stellar | 1500 | `stellar` | Soroban smart contracts (internal-defined, Stellar has no EVM chain ID) |

> **Note:** Stellar does not have an official EVM chain ID. We use `1500` as a self-defined identifier for internal routing. This value is used in `destinationChainId` parameter and `chainIdToAxelarName` mapping.

Both chains can be source or destination. Flows work in both directions.

### Chain Identification

- **Smart contracts** use numeric `chainId` (uint256) for chain identification and security
- **Axelar GMP** uses string chain names for message routing
- Contracts maintain a mapping: `chainId → Axelar chain name`

```solidity
// Example mapping in contract
mapping(uint256 => string) public chainIdToAxelarName;
// 8453 => "base"
// 1500 => "stellar"
```

## Supported Tokens

**Currently: Stablecoins only (USDC).**

| Chain | Supported Token Types | Native Asset |
|-------|----------------------|--------------|
| EVM (Base) | ERC-20 tokens only | ETH **NOT supported** |
| Stellar | Soroban tokens (SEP-41) only | XLM **NOT supported** |

### Current Support

| Token | Base | Stellar | Notes |
|-------|------|---------|-------|
| USDC | ✅ | ✅ | Primary supported token |

### Why ERC-20 / Soroban Tokens Only?

- Contract uses `transferFrom()` to pull tokens from sender
- Native assets (ETH, XLM) require different handling (`msg.value`, native transfers)
- Stablecoins simplify relayer operations (predictable value)

### Future Expansion

Other stablecoins (USDT, etc.) may be added. Exotic tokens technically work but:
- Relayers may not have liquidity
- Price volatility increases risk
- No guarantee of fills

## Core Terms

| Term | Description |
|------|-------------|
| **Source Chain** | Where sender deposits |
| **Destination Chain** | Where receiver gets paid |
| **Sender** | User who initiates payment |
| **Receiver** | Recipient on destination chain |
| **Relayer** | Service that pays on destination, gets repaid on source (aka Solver/Filler) |
| **Messenger** | Cross-chain verification (Axelar) |

## Amount Terms

| Term | Description |
|------|-------------|
| **sourceAmount** | Amount sender deposits (locked in contract) |
| **destinationAmount** | Amount receiver gets (calculated by frontend) |

Frontend calculates fees upfront. Sender specifies both amounts when creating intent.

## Intent Status

| Status | Description |
|--------|-------------|
| **PENDING** | Sender deposited, waiting for fill |
| **FILLED** | Fill completed (via `notify()`) |
| **FAILED** | Fill verification failed, admin must investigate |
| **REFUNDED** | Sender refunded |

## Functions

### Source Chain

| Function | Caller | Description |
|----------|--------|-------------|
| `createIntent()` | Sender | Deposit funds, optionally assign relayer from RFQ |
| `notify()` | Messenger only | Confirm fast fill → FILLED, pay relayer |
| `refund()` | Sender or refundAddress | Refund expired intent |

### Destination Chain

| Function | Caller | Description |
|----------|--------|-------------|
| `fillAndNotify()` | Relayer | Pay receiver, specify repayment address, send Axelar message |

## Fill Modes

| Mode | Status Flow | Relayer Profit |
|------|-------------|----------------|
| **Fast Fill** | PENDING → FILLED | Yes (spread) |

## RFQ Terms

| Term | Description |
|------|-------------|
| **Quote Request** | User's request for price quote from relayers |
| **Quote Bid** | Relayer's price offer for filling an intent |
| **Auction Window** | Time period for relayers to submit bids (3 seconds) |
| **Fulfillment Threshold** | Maximum time for winning relayer to fulfill (10 seconds) |
| **Rozo Relayer Fallback** | Rozo relayer executes fill if winner doesn't fulfill within 10 seconds |
| **Relayer Deposit** | Funds deposited by relayers as collateral for whitelisting |
| **Penalty System** | Relayers who win but fail to fulfill are penalized from their deposits |
| **Open Intent** | Intent with `relayer = address(0)`, any whitelisted relayer can fill |
| **Assigned Intent** | Intent with specific relayer address, only that relayer can fill |

## Security Terms

| Term | Description |
|------|-------------|
| **filledIntents** | Mapping on destination chain tracking filled intents (prevents double-fill) |
| **Relayer Whitelist** | Admin-managed list of allowed relayers |
| **Trusted Contracts** | Cross-chain contract addresses verified for Axelar messages |
| **Repayment Address** | Relayer's address on source chain where payout is sent |
| **IntentData** | Struct containing all intent parameters, passed to destination chain |
| **Fill Hash** | Hash of IntentData used to track fills on destination chain |
