import { Intent, IntentData, IntentStatus, RelayerConfig, ChainConfig } from './types';
import { EvmClient } from './evm-client';
import { StellarClient } from './stellar-client';

// Chain IDs
const STELLAR_CHAIN_ID = 1500;
const BASE_CHAIN_ID = 8453;
const BASE_SEPOLIA_CHAIN_ID = 84532;

// Helper to convert address to bytes32 (left-padded)
function addressToBytes32(address: string): string {
  if (address.startsWith('0x')) {
    address = address.slice(2);
  }
  return '0x' + address.toLowerCase().padStart(64, '0');
}

/**
 * RozoIntents Relayer
 *
 * Monitors for new intents and fills them by paying on destination chain,
 * then receiving payment on source chain via messenger verification.
 *
 * New design:
 * - No separate fill() on source chain
 * - fillAndNotify() on destination chain handles everything
 * - Messenger sends notification back to source chain
 * - notify() on source chain releases funds to relayer
 */
export class Relayer {
  private config: RelayerConfig;
  private evmClients: Map<number, EvmClient> = new Map();
  private stellarClient: StellarClient | null = null;
  private activeIntents: Map<string, { intent: Intent; sourceChainId: number }> = new Map();
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
      client.onIntentCreated((intent, sourceChainId) => {
        console.log(`New intent detected on chain ${chainId}: ${intent.intentId}`);
        this.handleNewIntent(intent, sourceChainId);
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
    for (const [intentId, { intent, sourceChainId: storedSourceChainId }] of this.activeIntents) {
      // Refresh intent status
      const currentIntent = await client.getIntent(intentId);
      if (!currentIntent) continue;

      // Update local state
      this.activeIntents.set(intentId, { intent: currentIntent, sourceChainId: storedSourceChainId });

      // Check if still fillable (PENDING status)
      if (currentIntent.status === IntentStatus.Pending) {
        const now = Math.floor(Date.now() / 1000);
        if (currentIntent.deadline > now) {
          // Attempt to fill
          await this.attemptFill(currentIntent, storedSourceChainId);
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
    this.activeIntents.set(intent.intentId, { intent, sourceChainId });

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
   * Build IntentData from intent for cross-chain verification
   */
  private buildIntentData(intent: Intent, sourceChainId: number): IntentData {
    return {
      intentId: intent.intentId,
      sender: addressToBytes32(intent.sender),
      refundAddress: addressToBytes32(intent.refundAddress),
      sourceToken: addressToBytes32(intent.sourceToken),
      sourceAmount: intent.sourceAmount,
      sourceChainId: sourceChainId,
      destinationChainId: intent.destinationChainId,
      destinationToken: intent.destinationToken, // Already bytes32
      receiver: intent.receiver, // Already bytes32
      destinationAmount: intent.destinationAmount,
      deadline: intent.deadline,
      createdAt: intent.createdAt,
      relayer: intent.relayer, // Already bytes32
    };
  }

  /**
   * Get relayer's repayment address for source chain (bytes32 format)
   */
  private getRepaymentAddress(sourceChainId: number): string {
    if (this.isEvmChain(sourceChainId)) {
      const client = this.evmClients.get(sourceChainId);
      if (client) {
        return client.getRelayerAddressBytes32();
      }
    } else if (sourceChainId === STELLAR_CHAIN_ID && this.stellarClient) {
      return this.stellarClient.getRelayerAddressBytes32();
    }
    // Fallback: use first EVM client's address
    const firstClient = this.evmClients.values().next().value;
    return firstClient ? firstClient.getRelayerAddressBytes32() : '0x' + '00'.repeat(32);
  }

  /**
   * Attempt to fill an intent
   *
   * New flow (no separate fill() on source chain):
   * 1. Build IntentData struct
   * 2. Call fillAndNotify() on destination chain
   * 3. Destination contract pays receiver + sends notification
   * 4. Messenger delivers notification to source chain
   * 5. Source chain releases funds to relayer's repaymentAddress
   */
  private async attemptFill(intent: Intent, sourceChainId: number): Promise<void> {
    console.log(`Attempting to fill intent ${intent.intentId}`);
    console.log(`  Source chain: ${sourceChainId}`);
    console.log(`  Destination chain: ${intent.destinationChainId}`);
    console.log(`  Source amount: ${intent.sourceAmount}`);
    console.log(`  Destination amount: ${intent.destinationAmount}`);

    // Build IntentData for verification
    const intentData = this.buildIntentData(intent, sourceChainId);

    // Get repayment address on source chain
    const repaymentAddress = this.getRepaymentAddress(sourceChainId);

    // Use configured messenger ID (default 0 = Rozo)
    const messengerId = this.config.defaultMessengerId ?? 0;

    // Call fillAndNotify on destination chain
    if (intent.destinationChainId === STELLAR_CHAIN_ID) {
      // Destination is Stellar
      await this.fillOnStellar(intentData, repaymentAddress, messengerId);
    } else if (this.isEvmChain(intent.destinationChainId)) {
      // Destination is EVM
      await this.fillOnEvm(intentData, repaymentAddress, messengerId);
    } else {
      console.error(`Unknown destination chain: ${intent.destinationChainId}`);
    }
  }

  /**
   * Fill on Stellar destination chain
   */
  private async fillOnStellar(
    intentData: IntentData,
    repaymentAddress: string,
    messengerId: number
  ): Promise<void> {
    if (!this.stellarClient) {
      console.error('Stellar client not initialized');
      return;
    }

    console.log('Calling fillAndNotify() on Stellar...');
    console.log(`  Messenger ID: ${messengerId}`);
    console.log(`  Repayment address: ${repaymentAddress}`);

    const result = await this.stellarClient.fillAndNotify(
      intentData,
      repaymentAddress,
      messengerId
    );

    if (result.success) {
      console.log(`Stellar fillAndNotify successful! TX: ${result.txHash}`);
      console.log('Messenger will deliver notification to source chain...');
      // Remove from active intents (will be confirmed via notify on source)
      this.activeIntents.delete(intentData.intentId);
    } else {
      console.error(`Stellar fillAndNotify failed: ${result.error}`);
    }
  }

  /**
   * Fill on EVM destination chain
   */
  private async fillOnEvm(
    intentData: IntentData,
    repaymentAddress: string,
    messengerId: number
  ): Promise<void> {
    const destClient = this.evmClients.get(intentData.destinationChainId);
    if (!destClient) {
      console.error(`No client for destination chain ${intentData.destinationChainId}`);
      return;
    }

    console.log('Calling fillAndNotify() on EVM destination...');
    console.log(`  Messenger ID: ${messengerId}`);
    console.log(`  Repayment address: ${repaymentAddress}`);

    const result = await destClient.fillAndNotify(
      intentData,
      repaymentAddress,
      messengerId
    );

    if (result.success) {
      console.log(`EVM fillAndNotify successful! TX: ${result.txHash}`);
      console.log('Messenger will deliver notification to source chain...');
      // Remove from active intents (will be confirmed via notify on source)
      this.activeIntents.delete(intentData.intentId);
    } else {
      console.error(`EVM fillAndNotify failed: ${result.error}`);
    }
  }

  /**
   * Retry a failed notification
   * Call this if the original fillAndNotify succeeded but messenger delivery failed
   */
  async retryNotification(
    intent: Intent,
    sourceChainId: number,
    messengerId: number
  ): Promise<void> {
    console.log(`Retrying notification for intent ${intent.intentId} with messenger ${messengerId}`);

    const intentData = this.buildIntentData(intent, sourceChainId);

    if (intent.destinationChainId === STELLAR_CHAIN_ID) {
      if (!this.stellarClient) {
        console.error('Stellar client not initialized');
        return;
      }
      const result = await this.stellarClient.retryNotify(intentData, messengerId);
      if (result.success) {
        console.log(`Stellar retryNotify successful! TX: ${result.txHash}`);
      } else {
        console.error(`Stellar retryNotify failed: ${result.error}`);
      }
    } else if (this.isEvmChain(intent.destinationChainId)) {
      const destClient = this.evmClients.get(intent.destinationChainId);
      if (!destClient) {
        console.error(`No client for destination chain ${intent.destinationChainId}`);
        return;
      }
      const result = await destClient.retryNotify(intentData, messengerId);
      if (result.success) {
        console.log(`EVM retryNotify successful! TX: ${result.txHash}`);
      } else {
        console.error(`EVM retryNotify failed: ${result.error}`);
      }
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
