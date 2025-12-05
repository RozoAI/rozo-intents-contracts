# Messenger Design

Messengers verify cross-chain fills and call `fillNotify()` on RozoIntents.

## Interface

```solidity
interface IMessenger {
    /// @notice Called by destination chain to notify fill completion
    function notifyFill(
        bytes32 intentId,
        uint256 amountPaid,
        address relayer
    ) external;
}
```

RozoIntents implements `fillNotify()` which only accepts calls from registered messengers.

## Multi-Chain Support

```solidity
contract RozoIntents {

    // chainName => trusted contract address
    mapping(string => string) public trustedContracts;

    // messenger address => allowed
    mapping(address => bool) public messengers;

    modifier onlyMessenger() {
        require(messengers[msg.sender], "Not messenger");
        _;
    }

    function fillNotify(
        string calldata sourceChain,
        string calldata sourceContract,
        bytes calldata payload
    ) external onlyMessenger {
        // Verify source contract is trusted for this chain
        require(
            keccak256(bytes(sourceContract)) ==
            keccak256(bytes(trustedContracts[sourceChain])),
            "Untrusted source"
        );

        (bytes32 intentId, uint256 amountPaid, address relayer) =
            abi.decode(payload, (bytes32, uint256, address));

        _completeFill(intentId, relayer, amountPaid);
    }

    // Admin
    function setTrustedContract(string calldata chain, string calldata addr) external onlyOwner {
        trustedContracts[chain] = addr;
    }

    function setMessenger(address messenger, bool allowed) external onlyOwner {
        messengers[messenger] = allowed;
    }
}
```

## Supported Messengers

| Messenger | Status | Speed |
|-----------|--------|-------|
| Axelar | Live | ~5-10 sec |
| LayerZero | Planned | - |
| CCTP | Planned | - |

## Trusted Contracts (Example)

| Chain | Contract |
|-------|----------|
| stellar | `RozoStellar address` |
| ethereum | `RozoEthereum address` |
| base | `RozoBase address` |
| arbitrum | `RozoArbitrum address` |

---

## Axelar Implementation

### Flow

```
EVM (Base)                           Stellar

1. Sender: createIntent()
   └── status = NEW

2. Relayer: fill()
   └── status = FILLING

3.                                   Relayer pays receiver

4.                                   Relayer calls RozoStellar.fill()
                                     └── Axelar sends message

5. Axelar Network
   └── Validators verify tx
   └── Relay message (~5-10 sec)

6. Axelar Gateway calls fillNotify()
   └── status = FILLED
   └── Relayer paid
```

### Stellar Contract (Soroban)

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

## Security

| Check | Purpose |
|-------|---------|
| `onlyMessenger` | Only registered messengers can call fillNotify |
| `trustedContracts[chain]` | Verify source contract per chain |

---

## References

- [Axelar GMP Docs](https://docs.axelar.dev/dev/general-message-passing/overview/)
- [Stellar GMP Example](https://github.com/axelarnetwork/stellar-gmp-example)
