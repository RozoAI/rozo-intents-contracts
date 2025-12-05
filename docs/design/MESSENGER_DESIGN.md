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
import {IAxelarGateway} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";
import {IAxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarExecutable.sol";

contract RozoIntents is IAxelarExecutable {

    IAxelarGateway public immutable gateway;

    // chainName => trusted contract address
    mapping(string => string) public trustedContracts;

    constructor(address gateway_) {
        gateway = IAxelarGateway(gateway_);
    }

    /// @notice Called by Axelar Gateway to deliver cross-chain message
    /// @dev Implements IAxelarExecutable interface
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external override {
        // Step 1: Verify caller is Axelar Gateway
        require(msg.sender == address(gateway), "NotGateway");

        // Step 2: Validate the contract call with Axelar Gateway
        // This confirms the message was actually approved by Axelar validators
        bytes32 payloadHash = keccak256(payload);
        require(
            gateway.validateContractCall(commandId, sourceChain, sourceAddress, payloadHash),
            "NotApprovedByGateway"
        );

        // Step 3: Verify source contract is trusted for this chain
        require(
            keccak256(bytes(sourceAddress)) ==
            keccak256(bytes(trustedContracts[sourceChain])),
            "UntrustedSource"
        );

        // Step 4: Decode payload (5 parameters for verification)
        (
            bytes32 intentId,
            uint256 amountPaid,
            bytes32 relayer,
            bytes32 receiver,
            bytes32 destinationToken
        ) = abi.decode(payload, (bytes32, uint256, bytes32, bytes32, bytes32));

        // Step 5: Complete the fill
        _completeFill(intentId, relayer, amountPaid, receiver, destinationToken);
    }

    // Admin
    function setTrustedContract(string calldata chain, string calldata addr) external onlyOwner {
        trustedContracts[chain] = addr;
    }
}
```

### Axelar Validation Explained

The `gateway.validateContractCall()` is the critical security check:

| Check | Purpose |
|-------|---------|
| `msg.sender == gateway` | Ensures call comes from Axelar Gateway contract |
| `validateContractCall()` | Confirms Axelar validators approved this specific message |
| `trustedContracts[sourceChain]` | Verifies source contract is our trusted RozoIntents |

**Without `validateContractCall()`**, anyone could call `execute()` directly with fake payloads. The Gateway validates that:
1. The `commandId` corresponds to a real cross-chain message
2. The message originated from `sourceChain` / `sourceAddress`
3. The `payloadHash` matches what was sent

### Alternative: AxelarExecutable Base Contract

Axelar provides a base contract that handles validation automatically:

```solidity
import {AxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";

contract RozoIntents is AxelarExecutable {

    constructor(address gateway_) AxelarExecutable(gateway_) {}

    // Override _execute instead of execute
    // Gateway validation is handled by parent contract
    function _execute(
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal override {
        // Verify trusted source
        require(
            keccak256(bytes(sourceAddress)) ==
            keccak256(bytes(trustedContracts[sourceChain])),
            "UntrustedSource"
        );

        // Decode and process...
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
