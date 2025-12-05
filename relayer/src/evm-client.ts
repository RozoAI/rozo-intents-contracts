import { ethers, Contract, Wallet, Provider } from 'ethers';
import { Intent, IntentStatus, ChainConfig, FillResult } from './types';

// ABI for RozoIntents contract (minimal required functions)
const ROZO_INTENTS_ABI = [
  // Events
  'event IntentCreated(bytes32 indexed intentId, address indexed sender, address sourceToken, uint256 sourceAmount, uint256 destinationChainId, bytes32 receiver, uint256 destinationAmount, uint64 deadline)',
  'event IntentFilling(bytes32 indexed intentId, address indexed relayer)',
  'event IntentFilled(bytes32 indexed intentId, address indexed relayer, uint256 amountPaid)',
  'event IntentRefunded(bytes32 indexed intentId, address indexed refundAddress, uint256 amount)',

  // View functions
  'function getIntent(bytes32 intentId) external view returns (tuple(bytes32 intentId, address sender, address refundAddress, address sourceToken, uint256 sourceAmount, uint256 destinationChainId, bytes32 destinationToken, bytes32 receiver, uint256 destinationAmount, uint64 deadline, uint8 status, address relayer))',
  'function isRelayer(address relayer) external view returns (bool)',

  // Relayer functions
  'function fill(bytes32 intentId) external',
  'function fillAndNotify(bytes32 intentId, address gasToken, uint256 gasFee) external payable',
];

export class EvmClient {
  private provider: Provider;
  private wallet: Wallet;
  private contract: Contract;
  private chainConfig: ChainConfig;

  constructor(chainConfig: ChainConfig, privateKey: string) {
    this.chainConfig = chainConfig;
    this.provider = new ethers.JsonRpcProvider(chainConfig.rpcUrl);
    this.wallet = new Wallet(privateKey, this.provider);
    this.contract = new Contract(chainConfig.contractAddress, ROZO_INTENTS_ABI, this.wallet);
  }

  /**
   * Get the relayer address
   */
  getRelayerAddress(): string {
    return this.wallet.address;
  }

  /**
   * Check if this relayer is whitelisted
   */
  async isWhitelisted(): Promise<boolean> {
    return this.contract.isRelayer(this.wallet.address);
  }

  /**
   * Get intent by ID
   */
  async getIntent(intentId: string): Promise<Intent | null> {
    try {
      const result = await this.contract.getIntent(intentId);
      return {
        intentId: result.intentId,
        sender: result.sender,
        sourceToken: result.sourceToken,
        sourceAmount: result.sourceAmount,
        destinationChainId: Number(result.destinationChainId),
        destinationToken: result.destinationToken,
        receiver: result.receiver,
        destinationAmount: result.destinationAmount,
        deadline: Number(result.deadline),
        status: Number(result.status) as IntentStatus,
        relayer: result.relayer === ethers.ZeroAddress ? undefined : result.relayer,
        refundAddress: result.refundAddress,
      };
    } catch (error) {
      console.error(`Error getting intent ${intentId}:`, error);
      return null;
    }
  }

  /**
   * Listen for new intents
   */
  onIntentCreated(callback: (intent: Intent) => void): void {
    const filter = this.contract.filters.IntentCreated();
    this.contract.on(filter, (
      intentId: string,
      sender: string,
      sourceToken: string,
      sourceAmount: bigint,
      destinationChainId: bigint,
      receiver: string,
      destinationAmount: bigint,
      deadline: bigint
    ) => {
      callback({
        intentId,
        sender,
        sourceToken,
        sourceAmount,
        destinationChainId: Number(destinationChainId),
        destinationToken: '', // Not in event
        receiver,
        destinationAmount,
        deadline: Number(deadline),
        status: IntentStatus.New,
      });
    });
  }

  /**
   * Listen for intents being filled by other relayers
   */
  onIntentFilling(callback: (intentId: string, relayer: string) => void): void {
    const filter = this.contract.filters.IntentFilling();
    this.contract.on(filter, (intentId: string, relayer: string) => {
      callback(intentId, relayer);
    });
  }

  /**
   * Call fill() on the contract to claim an intent
   */
  async fill(intentId: string): Promise<FillResult> {
    try {
      const tx = await this.contract.fill(intentId);
      const receipt = await tx.wait();
      return {
        success: true,
        txHash: receipt.hash,
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message || 'Unknown error',
      };
    }
  }

  /**
   * Call fillAndNotify() for local chain fills (source == destination)
   */
  async fillAndNotify(intentId: string, gasFee: bigint = 0n): Promise<FillResult> {
    try {
      const tx = await this.contract.fillAndNotify(
        intentId,
        ethers.ZeroAddress, // Native gas token
        gasFee,
        { value: gasFee }
      );
      const receipt = await tx.wait();
      return {
        success: true,
        txHash: receipt.hash,
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message || 'Unknown error',
      };
    }
  }

  /**
   * Get past IntentCreated events
   */
  async getPastIntents(fromBlock: number = 0): Promise<Intent[]> {
    const filter = this.contract.filters.IntentCreated();
    const events = await this.contract.queryFilter(filter, fromBlock);

    const intents: Intent[] = [];
    for (const event of events) {
      if ('args' in event) {
        const args = event.args;
        intents.push({
          intentId: args.intentId,
          sender: args.sender,
          sourceToken: args.sourceToken,
          sourceAmount: args.sourceAmount,
          destinationChainId: Number(args.destinationChainId),
          destinationToken: '',
          receiver: args.receiver,
          destinationAmount: args.destinationAmount,
          deadline: Number(args.deadline),
          status: IntentStatus.New,
        });
      }
    }
    return intents;
  }

  /**
   * Get the current block number
   */
  async getBlockNumber(): Promise<number> {
    return this.provider.getBlockNumber();
  }

  /**
   * Remove event listeners
   */
  removeAllListeners(): void {
    this.contract.removeAllListeners();
  }
}
