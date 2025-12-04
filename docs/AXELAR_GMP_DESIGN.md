# Axelar GMP Integration

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         FLOW                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. User: createIntent() on EVM                                  │
│                                                                  │
│  2. Relayer pays receiver on Stellar                             │
│                                                                  │
│  3. Relayer calls RozoStellar.fill()                             │
│     └── Calls Axelar Gateway                                     │
│                                                                  │
│  4. Axelar Network                                               │
│     └── Validators verify tx on Stellar                          │
│     └── Relay message to EVM (~1-2 min)                          │
│                                                                  │
│  5. Axelar Gateway calls RozoBridge.fillRelay()                  │
│     └── Relayer gets paid                                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Stellar Contract (Soroban)

```rust
pub fn fill(
    env: Env,
    caller: Address,
    intent_id: BytesN<32>,
    receiver: Address,
    token: Address,
    amount: i128,
    destination_chain: String,
    destination_contract: String,
) {
    caller.require_auth();

    // Transfer payment atomically
    token::transfer(&env, &caller, &receiver, amount);

    // Send confirmation via Axelar
    let payload = encode(intent_id, amount, caller);
    gas_service.pay_gas(...);
    axelar_gateway.call_contract(destination_chain, destination_contract, payload);
}
```

---

## EVM Contract

```solidity
contract RozoBridge is AxelarExecutable {

    string public trustedSourceChain;      // e.g., "stellar"
    string public trustedSourceContract;   // RozoStellar address

    function _execute(
        bytes32 /*commandId*/,
        string calldata sourceChain,
        string calldata sourceContract,
        bytes calldata payload
    ) internal override {
        // Verify source
        require(keccak256(bytes(sourceChain)) == keccak256(bytes(trustedSourceChain)));
        require(keccak256(bytes(sourceContract)) == keccak256(bytes(trustedSourceContract)));

        // Decode and process
        (bytes32 intentId, uint256 amountPaid, address relayer) =
            abi.decode(payload, (bytes32, uint256, address));

        _fillRelay(intentId, relayer, amountPaid);
    }
}
```

---

## Security

| Check | Purpose |
|-------|---------|
| `sourceChain` | Verify message from correct chain |
| `sourceContract` | Verify message from trusted contract |
| Axelar `commandId` | Replay protection |

---

## No Backend Needed

| Service | Needed? |
|---------|---------|
| Validator service | No |
| Messenger service | No |
| Key management | No |

Axelar handles validation, consensus, and message relay.

---

## References

- [Axelar GMP Docs](https://docs.axelar.dev/dev/general-message-passing/overview/)
- [Stellar GMP Example](https://github.com/axelarnetwork/stellar-gmp-example)
