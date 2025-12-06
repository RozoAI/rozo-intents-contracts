## Codex Notes (EVM Intents)

- Solidity contract enforces deposit custody, keeps statuses explicit, and never trusts relayer payloads without Axelar validation + per-chain trusted addresses.
- Axelar `notify` path rejects mismatched payloads (receiver/token/amount), marking intents as `FAILED` so ops can manually investigate instead of releasing funds.
- SlowFill only works when Rozo has an authenticated bridge adapter configured per `(destinationChainId, sourceToken, destinationToken)` tuple; otherwise we fail fast and push the user towards fast-fill/refund.
- Refund logic intentionally allows both sender and the on-chain `refundAddress` to pull funds post-deadline, but no one else.
- Added a Foundry relayer script so operations can atomically `fill`, `fillAndNotify`, or `slowFill` via env-configured actions—makes on-call ops safer than ad-hoc scripts.

### Review Notes (2025-12-05)
- Double-checked RozoIntents access control: createIntent/refund limited to sender/refundAddress, relayer-gated fill/slowFill/fillAndNotify, messenger-gated notify.
- SlowFill currently forwards `sourceAmount - fee` to the bridge adapter; spec says bridge only `destinationAmount`. Worth aligning so protocol actually earns the spread cited in docs.
- Axelar `_completeFill` flow validates payloads and immediately marks intents FILLED/FAILED which keeps funds from being double released, so no replay surface spotted.
