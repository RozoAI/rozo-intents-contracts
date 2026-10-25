# ROZO forwarder factory V2 (EVM)

Ownerless CREATE2 factory for payment forwarders, deployed to the **same address on every EVM chain**
through Nick's deterministic deployment proxy. Spec: ainative
`docs/design/20261024-forwarder-factory-v2-same-address-arc.zh.md` (§4 is normative for this directory).

| Contract | Purpose |
| --- | --- |
| `src/MPForwarderFactoryV2.sol` | No owner, no constructor. `createForwarder` / `cloneForwarder` / `cloneForwarderAndFlush` / `getCloneAddress` / `getForwarderAddress`, events `ForwarderCreated`, `CloneCreated`. Only parents it created (`isParent`) can be cloned. |
| `src/MPForwarderV2.sol` | Clone implementation. Based on `v1/evm/src/MPForwarderV1.sol` with two changes: safe ERC-20 transfer (`transfer()` returning `false` reverts, no-return tokens accepted, token must have code) and Arc USDC reachable through both interfaces (`flushETH` for the native 18-dec balance, `flushERC20(0x3600…)` for the 6-dec view). |
| `script/DeployV2.s.sol` | Deploys F2 via Nick's factory, creates P2, verifies everything, idempotent, testnet broadcast allowlist, Arc fee floor. |
| `script/FlushDrill.s.sol` | Small-amount pay + flush drill on a testnet (native and ERC-20 legs). |
| `script/deploy-testnet.sh` | Wrapper: RPC chain-id check, fee mode per chain, key only from env. |
| `script/check-nick-factory.sh` | Read-only `eth_getCode` of Nick's factory on all target chains. |

## Frozen build (addresses depend on every line of this table)

| Setting | Value |
| --- | --- |
| Toolchain | Arc Foundry **v0.8.0-2** (`circlefin/arc-foundry`, forge 1.7.1-dev, commit `d497beea…`), see `.foundry-version`. Upstream Foundry is not used: it has no Arc execution semantics. |
| `solc` | 0.8.20 (`0.8.20+commit.a1b79de6`) |
| `optimizer` / `optimizer_runs` | true / 200 |
| `via_ir` | false |
| `evm_version` | paris |
| `bytecode_hash` / `cbor_metadata` | none / false (no metadata appended at all) |
| Dependencies | `lib/forge-std` v1.15.0 `0844d7e1…`, pinned in `foundry.lock` (tests/scripts only, not part of the creation code) |
| Factory salt `SALT_F2` | `keccak256("rozo.forwarder.factory.v2")` = `0xfc06dd9534232f0de0b835a22a8f232d5df908f59b95b36c2e9fb13dbb30ac7c` |
| Nick's factory | `0x4e59b44847b379578588920cA78FbF26c0B4956C`, calldata = `bytes32 salt ‖ initcode` (no selector) |
| EIP-1167 clone code | `3d602d80600a3d3981f3363d3d373d3d3d363d73<parent20>5af43d82803e903d91602b57fd5bf3` (55 bytes) |

**Changing any single item above, or any byte of `src/`, changes `keccak256(creation bytecode)` and
therefore F2, P2 and every payment address derived from them.** Re-run the prediction before trusting
any address: `arc-forge script script/DeployV2.s.sol --rpc-url <any rpc>` prints F2 / P2 / both hashes.

## Predicted addresses and hashes (from the frozen build above)

| Item | Value |
| --- | --- |
| **F2** `MPForwarderFactoryV2` | `0xcfa4aff9A884F51997ceE2916b7D31aEE9aFb9f7` |
| **P2** parent forwarder = `F2.createForwarder(hub, 0)` | `0x7E9b8B4662EBB74Ad488E8F69705A27Bfb6EcFD8` |
| hub (P2 `destination()`) | `0x05c84533299625Df3Ace2215742124C1644E2705` (production EVM hub, same on every chain) |
| `keccak256(F2 creation bytecode)` (4325 bytes; = the part of Nick's calldata after the salt) | `0x46d6f8de6a89d4f6f2310335bf207c5b691c4a3e6363ad77fe53d73531627903` |
| `keccak256(F2 deployed runtime)` (4293 bytes) | `0x4a6726a2a9012bb4f1bfe84bf7c12edb0b0aebb5a343e657db54a806ff0564de` |
| `keccak256(P2 deployed runtime)` (1528 bytes, immutable `factory` = F2 baked in) | `0x4c384edb455d22a16677307549341859f4a877b37fd6fa7928eed1c896d83641` |

Derivation: `F2 = CREATE2(0x4e59…956C, SALT_F2, keccak256(creationCode))`;
`P2 = CREATE2(F2, 0, keccak256(MPForwarderV2.creationCode ‖ abi.encode(F2, hub)))`;
`clone = CREATE2(F2, salt, keccak256(cloneCode(P2)))`. None of the three depends on the chain or on the deployer.

## Nick's factory on every target chain (read-only, 2026-10-25, `script/check-nick-factory.sh`)

All 9 mainnets and the 3 testnets return the same 69-byte runtime, byte-identical to Ethereum mainnet
(`keccak256 = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989`):

| chainId | chain | code bytes | identical to Ethereum |
| --- | --- | --- | --- |
| 1 | Ethereum | 69 | yes |
| 8453 | Base | 69 | yes |
| 56 | BNB Chain | 69 | yes |
| 42161 | Arbitrum One | 69 | yes |
| 137 | Polygon | 69 | yes |
| 999 | HyperEVM | 69 | yes |
| 480 | World Chain | 69 | yes |
| 5042 | Arc | 69 | yes |
| 42220 | Celo | 69 | yes |
| 84532 | Base Sepolia | 69 | yes |
| 5042002 | Arc testnet | 69 | yes |
| 11142220 | Celo Sepolia | 69 | yes |

`DeployV2.s.sol` re-checks this on every run and aborts on any difference.

## Mainnet deploy

```bash
# dry run (any key value works for estimation; broadcast refused without MAINNET_CHAIN_ID)
DEPLOYER_PRIVATE_KEY=0x1 script/deploy-mainnet.sh base
# broadcast: the key comes from the environment only (e.g. a Keychain read in the same command), one chain per run
DEPLOYER_PRIVATE_KEY=$(security find-generic-password -s ai.rozo.forwarder-v2-deployer -a D2 -w) script/deploy-mainnet.sh base --broadcast
```

Networks: `ethereum base bnb arbitrum polygon hyperevm world arc celo` (override the RPC with `RPC_URL=`). BNB uses
`--legacy`; Arc uses `--legacy --with-gas-price` with the 25 gwei floor; everything else uses EIP-1559 estimation.

## Mainnet deployments (2026-10-25, deployer D2 `0xF54C…22cd`, main `a64708a` + this PR's wrapper fixes)

All 9 chains read back after broadcast with `arc-cast code` / `arc-cast call` from an independent RPC call:
F2 runtime hash `0x4a6726a2…64de`, P2 runtime hash `0x4c384edb…3641`, `P2.destination()` = hub, `F2.isParent(P2)` = true.

| Chain | id | F2 tx (Nick's factory CREATE2) | P2 tx (`createForwarder(hub, 0)`) |
| --- | --- | --- | --- |
| Ethereum | 1 | `0x0034b3df38e4a15c1b1551da9884bb1f8fb58292785c7573d42f971a80380661` | `0x446e572a3e12903ce9792d57df25e00039ef508bff1cc19217b7e5f5737c676b` |
| Base | 8453 | `0x8baf09275a70b27cdb5068d369a1b389a77a1649a86b6a3ac3d07a5e62161e7f` | `0xc1119cc91c151811976ad66fe1bf73c4a4b6e1c8c89ea135796c5e4c0cdeb716` |
| BNB Chain | 56 | `0xea8225a085250f222fd99359898fc7467837beabda6f3387b6443275e351bf30` | `0xffe8dded653a7bf5f30d79532e12361f347e13673da896fa8b3b6ce53fbd9bbe` |
| Arbitrum | 42161 | `0x5517745808aaa326dc819da87a084c58fa7633d89007b07f39d0e3c45cdd82bd` | `0x06145e955d711e69bcf6c6d7e68dc5ff82ffb76afd0b6419115b00a5ed0e1963` |
| Polygon | 137 | `0xe950029f4820630c73b5039b6f0b0472f7507858241194430912095027848b1a` | `0x6c521e59b811f78b3ce399292cf30a5f73eea7a358deb3d03a14042af28cf785` |
| HyperEVM | 999 | `0xc96a22b5a1470264a780456d68769833e47c92e6f658f28cef6807b627483d68` | `0xad384badd9c60db1b8071aeae46a6f66da9c1ab6e361f4ab6235dca83c1b67ab` |
| World Chain | 480 | `0xf99faebf5861aa77729f6bab180e0f75c7d7df0122ccf064f39fb90cef452e42` | `0x21f741d8b699d86054d098e65e198f1bd7e08604ac90618114b15487870e5c87` |
| Arc | 5042 | `0xaff535e8a1a30f101e220f9c08f7ee51873c4370a65a4440e223aa1679346e29` | `0x630eae3b9ddc5506c8de45e0ea4abc5270b42a82746e50662b056ef4527b17e3` |
| Celo | 42220 | `0xf58236db5c758e048fd0f800bda1a30841e1cd8030ac4421b6be7088bb319b4c` | `0x11a00c006e6bbe4780910ffa9ea384efcd82de63930b20d8a18ffbe161073a0a` |

Mainnet flush probe (`script/FlushDrill.s.sol`, label `test:20261025-mainnet`, erc20 clone `0xf297E8b316e33A4F83b9C6C5910B59615819c3D2`,
native clone `0xa348F871b4c53A274b847153741F309360e917b2`, same on every chain):

| Chain | Leg | Pay tx | Flush tx | Hub received (Transfer log) |
| --- | --- | --- | --- | --- |
| Base | USDC `0x8335…2913` | `0x1b1722b44b13b2b966e466b2746dcc42939537bddc64b1ce52aa04e073dd0fb8` | `0x88a0a0e786c5163ce1c2d5d7cf392982bbb8c3b491aa68b92805beb052b6500b` | 1.000000 USDC (hub 13525.916327 → 13526.916327) |

Two wrapper fixes found during the deploy: a bare-hex key (no `0x`) was parsed as 0 by `vm.envOr` (`MissingDeployerKey`),
so the wrapper now normalises the prefix; and on Arc `--with-gas-price` only sets the broadcast price, the simulation's
`tx.gasprice` needs `--gas-price` too or `requireArcFee` rejects a valid run (`GasPriceTooLow(20.3 gwei, 25 gwei)`).

## Mainnet gas estimates (read-only `eth_estimateGas`, 2026-10-25; no mainnet broadcast was made)

F2 deployment through Nick's factory estimates at **998,908 gas** on every chain (1,000,657 on Arbitrum).
`createForwarder(hub, 0)` used **416,530 gas** on Arc testnet. Expect ~1.42M gas per chain for both.

| chainId | chain | `eth_gasPrice` at check | F2 deploy cost (native) | F2 + P2 (native, ×1.42) |
| --- | --- | --- | --- | --- |
| 1 | Ethereum | 0.031 gwei | 0.000031 ETH | ~0.000044 ETH |
| 8453 | Base | 0.006 gwei | 0.000006 ETH | ~0.000009 ETH |
| 56 | BNB Chain | 0.05 gwei | 0.00005 BNB | ~0.00007 BNB |
| 42161 | Arbitrum One | 0.02 gwei | 0.00002 ETH | ~0.00003 ETH |
| 137 | Polygon | 263.7 gwei | 0.263 POL | ~0.37 POL |
| 999 | HyperEVM | 0.1 gwei | 0.0001 HYPE | ~0.00014 HYPE |
| 480 | World Chain | 0.002 gwei | 0.000001 ETH | ~0.000002 ETH |
| 5042 | Arc | 25 gwei (floor used) | 0.025 USDC | ~0.035 USDC |
| 42220 | Celo | 202.5 gwei | 0.202 CELO | ~0.29 CELO |

Gas prices move; the design doc's funding table (§2) stays the budget of record.

## Testnet deployments (phase 10A)

The deployer was a throwaway testnet wallet `0xb050d86a998042736f23590d9e881883e69e38Bf` whose key lived
only in a process's memory for this drill (never on disk, never in argv). It has no privileges: F2 has no owner.

### Arc testnet (chainId 5042002) — PASSED, live

| Step | tx | result |
| --- | --- | --- |
| F2 via Nick's factory | `0x223fb372b10711bbac33a33bf55bd7d0aee3e7812d7865ec28fa45afa9daa2f4` | status 1, gasUsed 981,001, legacy gasPrice 25 gwei |
| P2 = `createForwarder(hub, 0)` | `0x35173ef9d80a5ae7b1b3ad003d09f0c47b89287ed4fb2bbdc2218574e06ce986` | status 1, gasUsed 416,530 |

Read-back after confirmation (`eth_getCode` / `eth_call`, not simulation):

| Check | On chain | Expected | ok |
| --- | --- | --- | --- |
| F2 address | `0xcfa4aff9A884F51997ceE2916b7D31aEE9aFb9f7` | same | ✅ |
| `keccak256(eth_getCode(F2))` | `0x4a6726a2…0564de` | `0x4a6726a2…0564de` | ✅ |
| P2 address = `F2.getForwarderAddress(hub, 0)` | `0x7E9b8B4662EBB74Ad488E8F69705A27Bfb6EcFD8` | same | ✅ |
| `P2.factory()` | `0xcfa4aff9…b9f7` | F2 | ✅ |
| `P2.destination()` | `0x05c84533…2705` | hub | ✅ |
| `F2.isParent(P2)` | true | true | ✅ |
| `keccak256(eth_getCode(P2))` | `0x4c384edb…3641` | `0x4c384edb…3641` | ✅ |

Flush drill with real testnet USDC (`script/FlushDrill.s.sol`, label `test:20261025-arc`), both Arc USDC interfaces:

| Leg | tx | hub delta (on chain) |
| --- | --- | --- |
| pay 1.000000000000000001 USDC **native** to clone `0xc58F3a93…cCfc` | `0x1c36e3ecdbc26e9b7d8f06bda25627487645c7a3ab5961881baf79564bbdd35a` | — |
| `cloneForwarderAndFlush(P2, salt, 0x0, false)` (native path) | `0xc71840ce3d4f4882c8b9c6565cdb43299b75c04ebbd47a20b7e94b60828c5e02` | hub native +1.000000000000000001 USDC (dust moved too) |
| pay 1 USDC via **ERC-20** `0x3600…` to clone `0xD9957979…733c` | `0x3dadf5dc85610a3c54c1a3ecd4c7141ede2fac832bf8c1068ad23d0808f3c23c` | — |
| `cloneForwarderAndFlush(P2, salt, 0x3600…, false)` (ERC-20 view path) | `0x43be76385241611a5e301a64265e9614a1e7104224624c783d3dd04474040d8a` | hub native +1 USDC; logs: system emitter `0xffff…fffe` Transfer 1e18 **and** `0x3600…` Transfer 1e6 (same money, count once) |

Final on-chain hub balance on Arc testnet after the drill: native `2000000000000000001` (18 dec), ERC-20 view `2000000` (6 dec).
Dust findings (fork tests `test/ArcFork.t.sol`, confirmed by the drill): the native path moves everything
including sub-micro-USDC dust; the ERC-20 view path moves `floor(balance / 1e12)` and leaves the dust on the
clone, which a later `flushETH` sweeps. Flushing both interfaces never double-pays.

### Base Sepolia (chainId 84532) — NOT YET BROADCAST (blocked on gas, see below)

Dry run against the live RPC passes (chain id read from RPC, Nick's runtime verified, F2 / P2 predicted and
simulated at the same addresses as Arc testnet). The throwaway wallet has 0 ETH on Base Sepolia and every
login-free faucet reachable from this machine was blocked on 2026-10-25:

| Faucet | Result |
| --- | --- |
| Google Cloud Web3 faucet | no Base Sepolia network offered (only Ethereum Sepolia, Celo Sepolia, …) and requires Google sign-in |
| Circle faucet | works for USDC only (no ETH) |
| Bware Labs | HTTP 530 |
| ethereum-ecosystem.com | HTTP 402 (paid) |
| Triangle | HTTP 503 |
| pk910 PoW faucet (Sepolia, then bridge) | Cloudflare Turnstile checkbox needs a human click |
| Alchemy / QuickNode | require ≥ 0.001 ETH on Ethereum mainnet on the address |

To finish: send ≥ 0.005 Base Sepolia ETH to the drill wallet (or any wallet, then run the deploy with that key) and run
`DEPLOYER_PRIVATE_KEY=… script/deploy-testnet.sh base_sepolia --broadcast`, then the read-back block above.

### Celo Sepolia (chainId 11142220) — 未验收 (not accepted)

Dry run passes. No CELO could be obtained: Google Cloud faucet requires Google sign-in, faucet.celo.org requires
GitHub sign-in, and Arc Foundry's `cast`/`forge script` have no CIP-64 `feeCurrency` support to pay gas in USDC.
Evidence: the throwaway wallet holds 0 CELO on Celo Sepolia at the time of writing.

## Safety rails in the deploy script

- Reads `eth_chainId` from the RPC and requires it to equal the EVM's `block.chainid`.
- Broadcast allowlist (this phase): **84532, 5042002, 11142220 only**. Any other chain id can be queried and estimated but
  `--broadcast` reverts with `BroadcastNotAllowed`. Testnets are always allowed. A mainnet is allowed only when the
  environment variable `MAINNET_CHAIN_ID` equals the chain id read from the RPC; `script/deploy-mainnet.sh <chain>
  --broadcast` sets it from the chain named on the command line, one chain per invocation. Without it the 9 mainnets
  are rejected, and naming one mainnet never unlocks another (`test/DeployV2.t.sol`).
- Nick's factory runtime must be the exact 69 bytes read from Ethereum mainnet; otherwise `NicksFactoryRuntimeMismatch`.
- F2: if the predicted address already holds code it must hash to the expected runtime (idempotent skip); any other
  code aborts with `ForeignCodeAtFactoryAddress`.
- P2: created if missing; always verified (`isParent`, `factory()`, `destination()`, runtime hash).
- Arc (5042 / 5042002): the wrapper passes `--network arc` so simulation runs under Arc execution semantics. Broadcast requires `tx.gasprice >= 25 gwei` and `>= block.basefee`. The wrapper uses
  legacy fee mode (`--legacy --with-gas-price`) at `max(25 gwei, 1.2 × basefee)`; Base / Celo use plain EIP-1559
  estimation. Fee styles are never mixed in one transaction.
- The private key is read only from `DEPLOYER_PRIVATE_KEY` (`vm.envOr`). Nothing prints it; the broadcast log was
  grepped for 64-hex strings on the key line (0 hits).

## Tests

```bash
arc-forge test                                   # 52 unit tests (factory invariants, addressing, deploy script); the 6 fork tests self-skip without ARC_TESTNET_RPC
ARC_TESTNET_RPC=https://rpc.testnet.arc.io arc-forge test -n arc --match-contract ArcFork   # 6 Arc fork tests
```

Covered: unauthorized `init` / `initAndFlush`, second initialisation, parent re-init, zero destination, malicious /
foreign / EOA parent rejected, front-running with our salt still pays the hub, idempotent create / clone, ERC-20
`transfer` returning `false`, reverting, short return data and tokens without code all revert the whole
`cloneForwarderAndFlush` (clone not deployed), destination rejecting ETH reverts, ETH / ERC-20 / USDT-style / zero
balance flush paths, `getCloneAddress` vs the 55-byte clone code formula, `getForwarderAddress` vs the CREATE2
formula (fuzzed), factory runtime contains no `owner()` selector, Nick's runtime 69 bytes, deploy script: tampered
Nick runtime, foreign or tampered code at F2, idempotent second run, P2 verification, Arc fee floor, allowlist.
Fork tests cover both Arc USDC interfaces, dust, double-count protection and the dual Transfer logs.
Fork tests do not replace the live deployment above.

## Operating notes for the backend (phase 10B)

- Arc: pick exactly one flush interface per chain in configuration. Native (`token = 0x0`) moves dust too; the
  `0x3600…` interface moves whole micro-USDC. Count inbound money from the system emitter `0xffff…fffe` log only.
- `isUSDT` is informational in V2: both ERC-20 paths use the same safe transfer and accept no-return tokens.
- `cloneForwarderAndFlush` on an existing clone only flushes; on a missing clone it deploys + inits + flushes atomically.
