# RozoIntents Relayer

A TypeScript relayer for filling cross-chain intents between Base and Stellar.

## Overview

The relayer monitors for new intents on source chains and fills them by:
1. Calling `fill()` on the source chain to claim the intent
2. Paying the receiver on the destination chain via `fillAndNotify()`
3. Receiving payment on the source chain after Axelar verification

## Setup

1. Install dependencies:
```bash
npm install
```

2. Copy `.env.example` to `.env` and configure:
```bash
cp .env.example .env
```

3. Configure your environment variables:
- `EVM_PRIVATE_KEY`: Private key for EVM chains (Base)
- `STELLAR_SECRET_KEY`: Secret key for Stellar
- `ROZO_INTENTS_BASE`: RozoIntents contract address on Base
- `ROZO_INTENTS_STELLAR`: RozoIntents contract ID on Stellar

## Running

Development mode:
```bash
npm run dev
```

Production mode:
```bash
npm run build
npm start
```

## Architecture

```
src/
├── index.ts          # Entry point
├── config.ts         # Configuration loading
├── types.ts          # TypeScript types
├── relayer.ts        # Main relayer logic
├── evm-client.ts     # EVM chain interactions
└── stellar-client.ts # Stellar chain interactions
```

## Flow

### Base → Stellar Intent

1. User creates intent on Base (funds locked)
2. Relayer detects `IntentCreated` event
3. Relayer calls `fill()` on Base → status = FILLING
4. Relayer calls `fillAndNotify()` on Stellar
   - Pays receiver
   - Sends Axelar message to Base
5. Axelar validators verify Stellar event
6. Axelar calls `notify()` on Base → status = FILLED
7. Relayer receives `sourceAmount - protocolFee`

### Stellar → Base Intent

1. User creates intent on Stellar (funds locked)
2. Relayer detects intent via Stellar events
3. Relayer calls `fill()` on Stellar → status = FILLING
4. Relayer calls `fillAndNotify()` on Base
   - Pays receiver
   - Sends Axelar message to Stellar
5. Axelar validators verify Base event
6. Axelar calls `notify()` on Stellar → status = FILLED
7. Relayer receives `sourceAmount - protocolFee`

## Requirements

- Relayer must be whitelisted on both chains
- Relayer needs sufficient balance on destination chain to pay receivers
- Relayer earns `sourceAmount - destinationAmount - protocolFee`

## Safety

- If relayer doesn't complete the fill, intent stays in FILLING status
- After deadline, anyone can call `refund()` to return funds to sender
- No fund loss possible - worst case is timeout and refund
