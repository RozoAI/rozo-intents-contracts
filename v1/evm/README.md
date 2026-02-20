# ROZO Intents EVM Contracts V1

EVM smart contracts for ROZO payment forwarding system.

## Contracts

### MPForwarderV2.sol

Payment forwarder contract that supports:
- ETH transfers and flushing
- ERC20 token transfers and flushing
- USDT-style token transfers (non-standard ERC20)
- Minimal proxy (clone) pattern support via `init()` and `initAndFlush()`
- Relayer-controlled transfers

## Build

```bash
forge build
```

## Test

```bash
forge test
```

## License

BSD-2-Clause
