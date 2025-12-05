import dotenv from 'dotenv';
import { RelayerConfig, ChainConfig } from './types';

dotenv.config();

/**
 * Get chain configuration from environment
 */
function getChainConfigs(): ChainConfig[] {
  const configs: ChainConfig[] = [];

  // Base Sepolia (EVM)
  if (process.env.BASE_SEPOLIA_RPC_URL && process.env.ROZO_INTENTS_BASE) {
    configs.push({
      chainId: 84532,
      name: 'base-sepolia',
      rpcUrl: process.env.BASE_SEPOLIA_RPC_URL,
      contractAddress: process.env.ROZO_INTENTS_BASE,
      chainType: 'evm',
    });
  }

  // Base Mainnet (EVM)
  if (process.env.BASE_RPC_URL && process.env.ROZO_INTENTS_BASE_MAINNET) {
    configs.push({
      chainId: 8453,
      name: 'base',
      rpcUrl: process.env.BASE_RPC_URL,
      contractAddress: process.env.ROZO_INTENTS_BASE_MAINNET,
      chainType: 'evm',
    });
  }

  // Stellar
  if (process.env.ROZO_INTENTS_STELLAR) {
    configs.push({
      chainId: 1500,
      name: 'stellar',
      rpcUrl: process.env.STELLAR_NETWORK === 'mainnet'
        ? 'https://horizon.stellar.org'
        : 'https://horizon-testnet.stellar.org',
      contractAddress: process.env.ROZO_INTENTS_STELLAR,
      chainType: 'stellar',
    });
  }

  return configs;
}

/**
 * Load relayer configuration from environment
 */
export function loadConfig(): RelayerConfig {
  const evmPrivateKey = process.env.EVM_PRIVATE_KEY;
  const stellarSecretKey = process.env.STELLAR_SECRET_KEY;

  if (!evmPrivateKey) {
    throw new Error('EVM_PRIVATE_KEY is required');
  }
  if (!stellarSecretKey) {
    throw new Error('STELLAR_SECRET_KEY is required');
  }

  return {
    pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS || '5000', 10),
    minProfitUsd: parseFloat(process.env.MIN_PROFIT_USD || '0.50'),
    evmPrivateKey,
    stellarSecretKey,
    chains: getChainConfigs(),
  };
}

/**
 * Validate configuration
 */
export function validateConfig(config: RelayerConfig): void {
  if (config.chains.length === 0) {
    throw new Error('No chains configured');
  }

  const evmChains = config.chains.filter(c => c.chainType === 'evm');
  const stellarChains = config.chains.filter(c => c.chainType === 'stellar');

  if (evmChains.length === 0) {
    console.warn('Warning: No EVM chains configured');
  }
  if (stellarChains.length === 0) {
    console.warn('Warning: No Stellar chains configured');
  }
}
