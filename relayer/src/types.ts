/**
 * Intent status enum matching contract
 */
export enum IntentStatus {
  New = 0,
  Filling = 1,
  Filled = 2,
  Failed = 3,
  Refunded = 4,
}

/**
 * Intent data structure
 */
export interface Intent {
  intentId: string; // bytes32 as hex
  sender: string;
  sourceToken: string;
  sourceAmount: bigint;
  destinationChainId: number;
  destinationToken: string; // bytes32
  receiver: string; // bytes32
  destinationAmount: bigint;
  deadline: number;
  status: IntentStatus;
  relayer?: string;
  refundAddress?: string;
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
}

/**
 * Fill result
 */
export interface FillResult {
  success: boolean;
  txHash?: string;
  error?: string;
}
