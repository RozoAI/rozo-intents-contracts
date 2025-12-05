# Messenger Design

Messengers verify cross-chain fills and call `notify()` on RozoIntents.

## How It Works

1. Relayer calls `fillAndNotify()` on RozoIntents (destination chain)
2. RozoIntents contract transfers tokens from relayer to receiver
3. RozoIntents contract calls Axelar Gateway with payload
4. Axelar validators verify the contract event actually happened
5. Axelar Gateway calls `notify()` on RozoIntents (source chain)
6. RozoIntents releases funds to relayer

**Key:** The destination contract executes the payment, so Axelar verifies a real on-chain event - not just a relayer's claim.

## Why Contract Must Execute Payment

Axelar GMP verifies **contract events**, not arbitrary data:

| Approach | Security |
|----------|----------|
| Relayer pays directly, submits txHash | Unsafe - contract can't verify txHash |
| Relayer pays via contract | Safe - Axelar verifies contract event |

The RozoIntents contract on destination chain must:
1. Execute the token transfer (relayer → receiver)
2. Emit event / call Axelar Gateway
3. Axelar validators confirm this event happened

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

    function notify(
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

        // Relayer is bytes32 for cross-chain compatibility
        (bytes32 intentId, uint256 amountPaid, bytes32 relayer) =
            abi.decode(payload, (bytes32, uint256, bytes32));

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
| stellar | `RozoIntentsStellar` |
| ethereum | `RozoIntentsEthereum` |
| base | `RozoIntentsBase` |
| arbitrum | `RozoIntentsArbitrum` |

---

## Axelar Implementation

### Flow (Base → Stellar)

```
Base (Source)                        Stellar (Destination)

1. Sender: createIntent()
   └── status = NEW
   └── funds locked

2. Relayer: fill()
   └── status = FILLING
   └── relayer recorded

3.                                   Relayer: fillAndNotify()
                                     └── contract transfers tokens
                                         relayer → receiver
                                     └── contract calls Axelar Gateway

4. Axelar Network
   └── Validators verify Stellar contract event
   └── Relay message (~5-10 sec)

5. Axelar Gateway calls notify() on RozoIntentsBase
   └── validateContractCall() confirms Axelar approval
   └── status = FILLED
   └── Relayer paid (sourceAmount - protocolFee)
```

### Flow (Stellar → Base)

```
Stellar (Source)                     Base (Destination)

1. Sender: createIntent()
   └── status = NEW
   └── funds locked

2. Relayer: fill()
   └── status = FILLING
   └── relayer recorded

3.                                   Relayer: fillAndNotify()
                                     └── contract transfers tokens
                                         relayer → receiver
                                     └── contract calls Axelar Gateway

4. Axelar Network
   └── Validators verify Base contract event
   └── Relay message (~5-10 sec)

5. Axelar Gateway calls notify() on RozoIntentsStellar
   └── status = FILLED
   └── Relayer paid (sourceAmount - protocolFee)
```

**Key:** Both directions are symmetric. Destination contract always executes payment and sends Axelar message.

---

## Security

| Check | Purpose |
|-------|---------|
| `onlyMessenger` | Only registered messengers can call notify |
| `trustedContracts[chain]` | Verify source contract per chain |

---

## References

- [Axelar GMP Docs](https://docs.axelar.dev/dev/general-message-passing/overview/)
- [Stellar GMP Example](https://github.com/axelarnetwork/stellar-gmp-example)
