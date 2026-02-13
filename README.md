# ROZO Intents

**Website:** [https://www.rozo.ai/](https://www.rozo.ai/)

ROZO Intents is a stablecoin abstraction that lets users express what they want to do—pay or earn—without worrying about how it's executed onchain.

**Non-Custodial**: Our contracts never hold user funds. USDC flows directly from sender to destination—no asset breach risk. Users receive funds within seconds.

## Current Version: V1 (Stellar Payment Wrapper)

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
├── v1/                    # Current: Stellar payment wrapper (ACTIVE)
│   └── stellar/          # Soroban payment contract
├── evm/                   # Future: EVM contracts (when CCTP launches)
├── stellar/               # Future: Full Stellar intents (when CCTP launches)
├── relayer/               # Future: Relayer service (when CCTP launches)
└── docs/                  # Design documentation
```

## Documentation

For the full cross-chain design (when CCTP launches), see [DESIGN_README.md](./DESIGN_README.md).

## Links

- **Website**: [https://www.rozo.ai/](https://www.rozo.ai/)
- **Transaction Status**: [https://intents.rozo.ai/status](https://intents.rozo.ai/status)
