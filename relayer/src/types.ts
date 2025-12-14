/**
 * Intent status enum matching contract
 * PENDING -> FILLED (success) or FAILED (mismatch) or REFUNDED (after deadline)
 */
export enum IntentStatus {
  Pending = 0,
  Filled = 1,
  Failed = 2,
  Refunded = 3,
}

/**
 * Relayer type enum matching contract
 */
export enum RelayerType {
  None = 0,
  Rozo = 1,
  External = 2,
}

/**
 * Intent data structure (stored on source chain)
 */
export interface Intent {
  intentId: string; // bytes32 as hex
  sender: string;
  refundAddress: string;
  sourceToken: string;
  sourceAmount: bigint;
  destinationChainId: number;
  destinationToken: string; // bytes32
  receiver: string; // bytes32
  receiverIsAccount: boolean; // Is receiver a Stellar account (G...) or contract (C...)?
  destinationAmount: bigint;
  deadline: number;
  createdAt: number;
  status: IntentStatus;
  relayer: string; // bytes32 (0x0 = open)
}

/**
 * IntentData structure (passed to fillAndNotify)
 * Full intent data for cross-chain verification
 */
export interface IntentData {
  intentId: string; // bytes32
  sender: string; // bytes32
  refundAddress: string; // bytes32
  sourceToken: string; // bytes32
  sourceAmount: bigint;
  sourceChainId: number;
  destinationChainId: number;
  destinationToken: string; // bytes32
  receiver: string; // bytes32
  destinationAmount: bigint;
  deadline: number;
  createdAt: number;
  relayer: string; // bytes32
  receiverIsAccount: boolean; // Is receiver a Stellar account (G...) or contract (C...)?
}

/**
 * FillRecord structure (stored on destination chain)
 */
export interface FillRecord {
  relayer: string; // address
  repaymentAddress: string; // bytes32
  repaymentIsAccount: boolean; // Is repayment address a Stellar account or contract?
}

/**
 * Chain configuration
 */
export interface ChainConfig {
  chainId: number;
  name: string;
  rpcUrl: string;
  contractAddress: string;
  chainType: 'evm' | 'stellar';
}

/**
 * Relayer configuration
 */
export interface RelayerConfig {
  pollIntervalMs: number;
  minProfitUsd: number;
  evmPrivateKey: string;
  stellarSecretKey: string;
  chains: ChainConfig[];
  defaultMessengerId: number; // 0 = Rozo, 1 = Axelar
}

/**
 * Fill result
 */
export interface FillResult {
  success: boolean;
  txHash?: string;
  error?: string;
}
