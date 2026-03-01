# ROZO Intents

**Website:** [https://www.rozo.ai/](https://www.rozo.ai/)

ROZO Intents is a stablecoin abstraction that lets users express what they want to do—pay or earn—without worrying about how it's executed onchain.

**Non-Custodial**: Our contracts never hold user funds. USDC flows directly from sender to destination—no asset breach risk. Users receive funds within seconds.

## V2: Cross-Chain Intent Bridge (NEW)

V2 introduces a simplified cross-chain intent system with two contracts:

| Contract | Purpose | Description |
|----------|---------|-------------|
| **Token Forwarder** | Intra-chain forwarding | Minimal forwarding with event-based destination tracking |
| **Intent Bridge** | Cross-chain escrow | 3-state escrow (PENDING → FILLED/REFUNDED) with timeout protection |

### V2 Features

- **Simplified architecture**: ~100 lines (Forwarder) + ~200 lines (Bridge)
- **Timeout protection**: Users can always refund after deadline
- **Event-driven**: Backend monitors events for cross-chain execution
- **Stellar-native**: Built on Soroban SDK 22.0.0

See [v2/](./v2/) for implementation and [v2/AUDIT.md](./v2/AUDIT.md) for audit scope.

## V1: Stellar Payment Wrapper

We are starting with **V1**, a simplified version focused on Stellar that addresses two key considerations:

### Why V1 First?

1. **Privacy Matters**: Users don't want bridge transaction details exposed on-chain publicly. V1 provides a way to record payment information on-chain while maintaining privacy through memo-based routing.

2. **Circle CCTP Not Yet Available**: The full cross-chain architecture (EVM ↔ Stellar with CCTP) is designed but Circle's CCTP for Stellar is not yet launched. We will activate the full `evm/`, `relayer/`, and `stellar/` components when CCTP becomes available.

### V1 Architecture

V1 leverages multiple cross-chain liquidity sources to provide the best user experience:

- **Instant fulfillment** when we have liquidity (within seconds)
- **Multiple fallback providers** for reliability and cost optimization

**Current Integrations:**
- [Near Intents](https://near.org/intents) - Supports Stellar routes
- [Across Protocol](https://across.to/) - EVM chains (does not support Stellar yet)

**Our smart contract wrapper on Stellar:**
- Accepts payments with **destination address** and **memo** for routing
- Records payment events on-chain for transparency
- Routes to the optimal liquidity source automatically

**Goal**: Integrate more liquidity sources to reduce costs and provide faster, better user experience.

### V1 Contract

| Network | Contract Address | Verification |
|---------|-----------------|--------------|
| Stellar Mainnet | `CAC5SKP5FJT2ZZ7YLV4UCOM6Z5SQCCVPZWHLLLVQNQG2RWWOOSP3IYRL` | [StellarExpert](https://stellar.expert/explorer/public/contract/CAC5SKP5FJT2ZZ7YLV4UCOM6Z5SQCCVPZWHLLLVQNQG2RWWOOSP3IYRL) |

See [v1/](./v1/) for the Stellar payment contract implementation.

## Repository Structure

```
rozo-intents-contracts/
├── v1/                    # Stellar payment wrapper (ACTIVE)
│   └── stellar/           # Soroban payment contract
├── v2/                    # Cross-chain intent bridge (NEW)
│   ├── docs/              # Design documentation
│   ├── stellar/           # Soroban contracts (Forwarder + Intent Bridge)
│   ├── AUDIT.md           # Audit scope
│   └── README.md          # V2 overview
├── evm/                   # Future: EVM contracts (when CCTP launches)
├── stellar/               # Future: Full Stellar intents (when CCTP launches)
├── relayer/               # Future: Relayer service (when CCTP launches)
└── docs/                  # Design documentation
```

## Documentation

- **V2 Design**: See [v2/docs/](./v2/docs/) for Token Forwarder and Intent Bridge designs
- **Full Cross-Chain Design** (when CCTP launches): See [docs/DESIGN_README.md](./docs/DESIGN_README.md)

## Links

- **Website**: [https://www.rozo.ai/](https://www.rozo.ai/)
- **Transaction Status**: [https://intents.rozo.ai/status](https://intents.rozo.ai/status)
