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
| **Messenger** | Cross-chain verification service. Multiple options: Rozo (default, ~1-3 sec) or Axelar (~5-10 sec) |
| **Messenger Adapter** | Contract implementing `IMessengerAdapter` interface to support different messengers |
| **messengerId** | Identifier for messenger selection: 0=Rozo (default), 1=Axelar |

## Rozo Terminology (Important Distinction)

> ⚠️ **Don't confuse these two concepts:**

| Term | What it is | Purpose | When used |
|------|------------|---------|-----------|
| **Rozo Messenger** | Cross-chain messaging service | Delivers `notify()` from destination → source | When relayer calls `fillAndNotify(..., messengerId=0)` |
| **Rozo Relayer** | A **single designated address** | Fallback fill when assigned relayer fails | When `block.timestamp > createdAt + rozoRelayerThreshold` |

### Rozo Messenger (messengerId = 0)
- **Role:** Fast cross-chain message delivery (~1-3 sec)
- **How it works:** Rozo-operated network verifies destination chain events and triggers `notify()` on source chain
- **Alternative:** Axelar (messengerId = 1, ~5-10 sec)
- **Who chooses:** Relayer (via `messengerId` parameter in `fillAndNotify()`)

### Rozo Relayer (Single Address Fallback)
- **Role:** Fallback relayer to ensure intents get filled
- **Storage:** Single address stored in `rozoRelayer` state variable
- **How it works:** If assigned relayer doesn't fill within `rozoRelayerThreshold` (e.g., 10 sec), the designated `rozoRelayer` address can fill
- **Configured via:** `setRozoRelayer(address)` and `setRozoRelayerThreshold(uint256)`
- **Why needed:** Guarantees fast fulfillment even if assigned relayer fails

> **Note:** `RelayerType.ROZO` in the relayer registry is used to identify Rozo-operated relayers for tracking/reporting purposes. The fallback mechanism specifically checks against the single `rozoRelayer` address, not all ROZO-type relayers.

```
Example flow:
1. User creates intent with assigned relayer = 0xABC
2. 0xABC has 10 seconds to fill (rozoRelayerThreshold)
3. If 0xABC doesn't fill within 10 sec → rozoRelayer (single address) can fill
4. When filling, relayer chooses messenger (Rozo or Axelar) for repayment
```

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
| `notify()` | Messenger adapter only | Confirm fast fill → FILLED, pay relayer |
| `refund()` | Sender or refundAddress | Refund expired intent |

### Destination Chain

| Function | Caller | Description |
|----------|--------|-------------|
| `fillAndNotify()` | Relayer | Pay receiver, specify repayment address and messengerId, send notification via selected messenger |

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
| **Fulfillment Threshold** | The configurable window of time (`rozoRelayerThreshold`, e.g., 10 seconds) during which only the assigned relayer can fulfill an intent. After this period, the Rozo Relayer Fallback is activated. |
| **Rozo Relayer Fallback** | A capability where the designated `rozoRelayer` address (single address, not all ROZO-type relayers) is permitted to fill an intent if the assigned relayer fails within the `rozoRelayerThreshold`. |
| **Open Intent** | Intent with `relayer = address(0)`, any whitelisted relayer can fill |
| **Assigned Intent** | Intent with specific relayer address, only that relayer can fill |

> **Interested in becoming a relayer?** Contact us at [hi@rozo.ai](mailto:hi@rozo.ai) to learn about requirements and onboarding.

## Security Terms

| Term | Description |
|------|-------------|
| **FillRecord** | Struct storing relayer and repayment address for each fill (enables retries) |
| **filledIntents** | Mapping on destination chain storing FillRecord for each fill (prevents double-fill, enables retries) |
| **Relayer Whitelist** | Admin-managed list of allowed relayers |
| **Trusted Contracts** | Cross-chain contract addresses verified for messenger messages |
| **Repayment Address** | Relayer's address on source chain where payout is sent |
| **IntentData** | Struct containing all intent parameters, passed to destination chain |
| **Fill Hash** | Hash of IntentData used to track fills and verify integrity on source chain |
| **IMessengerAdapter** | Interface for messenger adapters (`sendMessage`, `verifyMessage`, `messengerId`) |
