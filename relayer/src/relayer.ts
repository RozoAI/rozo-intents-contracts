import { Intent, IntentStatus, RelayerConfig, ChainConfig } from './types';
import { EvmClient } from './evm-client';
import { StellarClient } from './stellar-client';

// Chain IDs
const STELLAR_CHAIN_ID = 1500;
const BASE_CHAIN_ID = 8453;
const BASE_SEPOLIA_CHAIN_ID = 84532;

/**
 * RozoIntents Relayer
 *
 * Monitors for new intents and fills them by paying on destination chain,
 * then receiving payment on source chain via Axelar verification.
 */
export class Relayer {
  private config: RelayerConfig;
  private evmClients: Map<number, EvmClient> = new Map();
  private stellarClient: StellarClient | null = null;
  private activeIntents: Map<string, Intent> = new Map();
  private isRunning: boolean = false;

  constructor(config: RelayerConfig) {
    this.config = config;
    this.initClients();
  }

  /**
   * Initialize chain clients
   */
  private initClients(): void {
    for (const chainConfig of this.config.chains) {
      if (chainConfig.chainType === 'evm') {
        const client = new EvmClient(chainConfig, this.config.evmPrivateKey);
        this.evmClients.set(chainConfig.chainId, client);
        console.log(`Initialized EVM client for ${chainConfig.name} (chainId: ${chainConfig.chainId})`);
      } else if (chainConfig.chainType === 'stellar') {
        this.stellarClient = new StellarClient(chainConfig, this.config.stellarSecretKey);
        console.log(`Initialized Stellar client for ${chainConfig.name}`);
      }
    }
  }

  /**
   * Start the relayer
   */
  async start(): Promise<void> {
    console.log('Starting relayer...');
    this.isRunning = true;

    // Check whitelist status
    await this.checkWhitelistStatus();

    // Set up event listeners for EVM chains
    for (const [chainId, client] of this.evmClients) {
      client.onIntentCreated((intent) => {
        console.log(`New intent detected on chain ${chainId}: ${intent.intentId}`);
        this.handleNewIntent(intent, chainId);
      });

      client.onIntentFilling((intentId, relayer) => {
        if (relayer.toLowerCase() !== client.getRelayerAddress().toLowerCase()) {
          console.log(`Intent ${intentId} claimed by another relayer: ${relayer}`);
          this.activeIntents.delete(intentId);
        }
      });
    }

    // Start polling loop for past intents
    this.pollLoop();

    console.log('Relayer started');
  }

  /**
   * Stop the relayer
   */
  stop(): void {
    console.log('Stopping relayer...');
    this.isRunning = false;

    for (const client of this.evmClients.values()) {
      client.removeAllListeners();
    }

    console.log('Relayer stopped');
  }

  /**
   * Check if relayer is whitelisted on all chains
   */
  private async checkWhitelistStatus(): Promise<void> {
    for (const [chainId, client] of this.evmClients) {
      const isWhitelisted = await client.isWhitelisted();
      const chain = this.config.chains.find(c => c.chainId === chainId);
      console.log(`Whitelisted on ${chain?.name || chainId}: ${isWhitelisted}`);

      if (!isWhitelisted) {
        console.warn(`WARNING: Relayer not whitelisted on chain ${chainId}. Fill transactions will fail.`);
      }
    }
  }

  /**
   * Main polling loop to discover fillable intents
   */
  private async pollLoop(): Promise<void> {
    while (this.isRunning) {
      try {
        // Check each EVM chain for fillable intents
        for (const [chainId, client] of this.evmClients) {
          await this.checkFillableIntents(client, chainId);
        }
      } catch (error) {
        console.error('Error in poll loop:', error);
      }

      await this.sleep(this.config.pollIntervalMs);
    }
  }

  /**
   * Check for fillable intents on a chain
   */
  private async checkFillableIntents(client: EvmClient, sourceChainId: number): Promise<void> {
    // For demo, we check active intents we're tracking
    for (const [intentId, intent] of this.activeIntents) {
      // Refresh intent status
      const currentIntent = await client.getIntent(intentId);
      if (!currentIntent) continue;

      // Update local state
      this.activeIntents.set(intentId, currentIntent);

      // Check if still fillable
      if (currentIntent.status === IntentStatus.New) {
        const now = Math.floor(Date.now() / 1000);
        if (currentIntent.deadline > now) {
          // Attempt to fill
          await this.attemptFill(currentIntent, sourceChainId);
        }
      }
    }
  }

  /**
   * Handle a new intent event
   */
  private async handleNewIntent(intent: Intent, sourceChainId: number): Promise<void> {
    // Skip if already tracking
    if (this.activeIntents.has(intent.intentId)) {
      return;
    }

    // Check profitability
    if (!this.isProfitable(intent)) {
      console.log(`Intent ${intent.intentId} not profitable, skipping`);
      return;
    }

    // Track the intent
    this.activeIntents.set(intent.intentId, intent);

    // Attempt to fill
    await this.attemptFill(intent, sourceChainId);
  }

  /**
   * Check if an intent is profitable to fill
   */
  private isProfitable(intent: Intent): boolean {
    // Calculate profit = sourceAmount - destinationAmount
    // This is a simplification - real implementation should consider:
    // - Gas costs on both chains
    // - Token price differences
    // - Protocol fees
    const profit = intent.sourceAmount - intent.destinationAmount;

    // For now, just check if profit is positive
    // Real implementation would convert to USD and compare to minProfitUsd
    return profit > 0n;
  }

  /**
   * Attempt to fill an intent
   */
  private async attemptFill(intent: Intent, sourceChainId: number): Promise<void> {
    console.log(`Attempting to fill intent ${intent.intentId}`);
    console.log(`  Source chain: ${sourceChainId}`);
    console.log(`  Destination chain: ${intent.destinationChainId}`);
    console.log(`  Source amount: ${intent.sourceAmount}`);
    console.log(`  Destination amount: ${intent.destinationAmount}`);

    const sourceClient = this.evmClients.get(sourceChainId);
    if (!sourceClient) {
      console.error(`No client for source chain ${sourceChainId}`);
      return;
    }

    // Step 1: Call fill() on source chain to claim the intent
    console.log('Step 1: Calling fill() on source chain...');
    const fillResult = await sourceClient.fill(intent.intentId);

    if (!fillResult.success) {
      console.error(`Fill failed: ${fillResult.error}`);
      return;
    }

    console.log(`Fill successful! TX: ${fillResult.txHash}`);

    // Step 2: Pay on destination chain
    if (intent.destinationChainId === STELLAR_CHAIN_ID) {
      // Destination is Stellar
      await this.payOnStellar(intent, sourceChainId);
    } else if (this.isEvmChain(intent.destinationChainId)) {
      // Destination is EVM
      await this.payOnEvm(intent, sourceChainId);
    } else {
      console.error(`Unknown destination chain: ${intent.destinationChainId}`);
    }
  }

  /**
   * Pay receiver on Stellar and send notification
   */
  private async payOnStellar(intent: Intent, sourceChainId: number): Promise<void> {
    if (!this.stellarClient) {
      console.error('Stellar client not initialized');
      return;
    }

    console.log('Step 2: Calling fillAndNotify() on Stellar...');

    const sourceChain = this.getChainName(sourceChainId);

    const result = await this.stellarClient.fillAndNotify(
      intent.intentId,
      intent.receiver,
      intent.destinationAmount,
      sourceChain,
      '', // Gas token (native XLM)
      0n  // Gas fee
    );

    if (result.success) {
      console.log(`Stellar fillAndNotify successful! TX: ${result.txHash}`);
      console.log('Axelar will verify and call notify() on source chain...');
    } else {
      console.error(`Stellar fillAndNotify failed: ${result.error}`);
    }
  }

  /**
   * Pay receiver on EVM destination chain
   */
  private async payOnEvm(intent: Intent, sourceChainId: number): Promise<void> {
    const destClient = this.evmClients.get(intent.destinationChainId);
    if (!destClient) {
      console.error(`No client for destination chain ${intent.destinationChainId}`);
      return;
    }

    console.log('Step 2: Calling fillAndNotify() on EVM destination...');

    // For same-chain or EVM-EVM, use fillAndNotify on destination
    const result = await destClient.fillAndNotify(intent.intentId);

    if (result.success) {
      console.log(`EVM fillAndNotify successful! TX: ${result.txHash}`);
    } else {
      console.error(`EVM fillAndNotify failed: ${result.error}`);
    }
  }

  /**
   * Check if chain ID is an EVM chain
   */
  private isEvmChain(chainId: number): boolean {
    return chainId !== STELLAR_CHAIN_ID;
  }

  /**
   * Get chain name from chain ID
   */
  private getChainName(chainId: number): string {
    switch (chainId) {
      case BASE_CHAIN_ID:
        return 'base';
      case BASE_SEPOLIA_CHAIN_ID:
        return 'base-sepolia';
      case STELLAR_CHAIN_ID:
        return 'stellar';
      default:
        return `chain-${chainId}`;
    }
  }

  /**
   * Sleep utility
   */
  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
