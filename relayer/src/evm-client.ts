import { ethers, Contract, Wallet, Provider } from 'ethers';
import { Intent, IntentData, IntentStatus, ChainConfig, FillResult } from './types';

// ABI for RozoIntents contract (minimal required functions)
// Updated to match the actual contract interface with address type flags
const ROZO_INTENTS_ABI = [
  // Events
  'event IntentCreated(bytes32 indexed intentId, address indexed sender, address sourceToken, uint256 sourceAmount, uint256 destinationChainId, bytes32 receiver, uint256 destinationAmount, uint64 deadline, bytes32 relayer)',
  'event IntentFilled(bytes32 indexed intentId, bytes32 indexed relayer, bytes32 repaymentAddress, uint256 amountPaid)',
  'event IntentRefunded(bytes32 indexed intentId, address indexed refundAddress, uint256 amount)',
  'event FillAndNotifySent(bytes32 indexed intentId, address indexed relayer, bytes32 repaymentAddress, uint8 messengerId)',
  'event RetryNotifySent(bytes32 indexed intentId, address indexed relayer, uint8 messengerId)',

  // View functions - match contract public getters (including receiverIsAccount)
  'function intents(bytes32 intentId) external view returns (tuple(bytes32 intentId, address sender, address refundAddress, address sourceToken, uint256 sourceAmount, uint256 destinationChainId, bytes32 destinationToken, bytes32 receiver, bool receiverIsAccount, uint256 destinationAmount, uint64 deadline, uint64 createdAt, uint8 status, bytes32 relayer))',
  'function relayers(address relayer) external view returns (uint8)',
  'function filledIntents(bytes32 fillHash) external view returns (address relayer, bytes32 repaymentAddress, bool repaymentIsAccount)',
  'function rozoRelayer() external view returns (address)',
  'function rozoRelayerThreshold() external view returns (uint256)',
  'function protocolFee() external view returns (uint256)',

  // Relayer functions (with receiverIsAccount in IntentData and repaymentIsAccount parameter)
  'function fillAndNotify(tuple(bytes32 intentId, bytes32 sender, bytes32 refundAddress, bytes32 sourceToken, uint256 sourceAmount, uint256 sourceChainId, uint256 destinationChainId, bytes32 destinationToken, bytes32 receiver, uint256 destinationAmount, uint64 deadline, uint64 createdAt, bytes32 relayer, bool receiverIsAccount) intentData, bytes32 repaymentAddress, bool repaymentIsAccount, uint8 messengerId) external payable',
  'function retryNotify(tuple(bytes32 intentId, bytes32 sender, bytes32 refundAddress, bytes32 sourceToken, uint256 sourceAmount, uint256 sourceChainId, uint256 destinationChainId, bytes32 destinationToken, bytes32 receiver, uint256 destinationAmount, uint64 deadline, uint64 createdAt, bytes32 relayer, bool receiverIsAccount) intentData, uint8 messengerId) external payable',
];

// Helper to convert address to bytes32 (left-padded)
function addressToBytes32(address: string): string {
  if (address.startsWith('0x')) {
    address = address.slice(2);
  }
  return '0x' + address.toLowerCase().padStart(64, '0');
}

// Helper to convert bytes32 to address (extract last 20 bytes)
function bytes32ToAddress(bytes32: string): string {
  if (bytes32.startsWith('0x')) {
    bytes32 = bytes32.slice(2);
  }
  return '0x' + bytes32.slice(-40);
}

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
   * Get the relayer address as bytes32
   */
  getRelayerAddressBytes32(): string {
    return addressToBytes32(this.wallet.address);
  }

  /**
   * Check if this relayer is whitelisted (has RelayerType > 0)
   * Uses the `relayers` public mapping getter
   */
  async isWhitelisted(): Promise<boolean> {
    const relayerType = await this.contract.relayers(this.wallet.address);
    return Number(relayerType) > 0;
  }

  /**
   * Get the chain ID from the provider
   * Note: contract doesn't expose chainId(), we get it from the provider
   */
  async getChainId(): Promise<number> {
    const network = await this.provider.getNetwork();
    return Number(network.chainId);
  }

  /**
   * Get intent by ID
   * Uses the `intents` public mapping getter
   */
  async getIntent(intentId: string): Promise<Intent | null> {
    try {
      const result = await this.contract.intents(intentId);
      // Check if intent exists (sender != address(0))
      if (result.sender === '0x0000000000000000000000000000000000000000') {
        return null;
      }
      return {
        intentId: result.intentId,
        sender: result.sender,
        refundAddress: result.refundAddress,
        sourceToken: result.sourceToken,
        sourceAmount: result.sourceAmount,
        destinationChainId: Number(result.destinationChainId),
        destinationToken: result.destinationToken,
        receiver: result.receiver,
        receiverIsAccount: result.receiverIsAccount,
        destinationAmount: result.destinationAmount,
        deadline: Number(result.deadline),
        createdAt: Number(result.createdAt),
        status: Number(result.status) as IntentStatus,
        relayer: result.relayer,
      };
    } catch (error) {
      console.error(`Error getting intent ${intentId}:`, error);
      return null;
    }
  }

  /**
   * Listen for new intents
   * Note: Event doesn't include receiverIsAccount, must fetch from contract
   */
  onIntentCreated(callback: (intent: Intent, sourceChainId: number) => void): void {
    const filter = this.contract.filters.IntentCreated();
    this.contract.on(filter, (
      intentId: string,
      sender: string,
      sourceToken: string,
      sourceAmount: bigint,
      destinationChainId: bigint,
      receiver: string,
      destinationAmount: bigint,
      deadline: bigint,
      relayer: string
    ) => {
      callback({
        intentId,
        sender,
        refundAddress: sender, // Default to sender
        sourceToken,
        sourceAmount,
        destinationChainId: Number(destinationChainId),
        destinationToken: '', // Not in event
        receiver,
        receiverIsAccount: false, // Default to false, should fetch from contract for actual value
        destinationAmount,
        deadline: Number(deadline),
        createdAt: Math.floor(Date.now() / 1000), // Approximate
        status: IntentStatus.Pending,
        relayer,
      }, this.chainConfig.chainId);
    });
  }

  /**
   * Build IntentData struct from intent and source chain info
   */
  buildIntentData(intent: Intent, sourceChainId: number): IntentData {
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
      receiverIsAccount: intent.receiverIsAccount, // Address type flag
    };
  }

  /**
   * Call fillAndNotify() on the destination chain
   * This pays the receiver and sends notification back to source chain
   *
   * @param intentData Full intent data for verification
   * @param repaymentAddress Where to receive payment on source chain (bytes32)
   * @param repaymentIsAccount Whether repayment address is a Stellar account (G...) or contract (C...)
   * @param messengerId Messenger to use (0 = Rozo, 1 = Axelar)
   */
  async fillAndNotify(
    intentData: IntentData,
    repaymentAddress: string,
    repaymentIsAccount: boolean = false,
    messengerId: number = 0
  ): Promise<FillResult> {
    try {
      // Convert IntentData to contract struct format
      const intentDataStruct = {
        intentId: intentData.intentId,
        sender: intentData.sender,
        refundAddress: intentData.refundAddress,
        sourceToken: intentData.sourceToken,
        sourceAmount: intentData.sourceAmount,
        sourceChainId: intentData.sourceChainId,
        destinationChainId: intentData.destinationChainId,
        destinationToken: intentData.destinationToken,
        receiver: intentData.receiver,
        destinationAmount: intentData.destinationAmount,
        deadline: intentData.deadline,
        createdAt: intentData.createdAt,
        relayer: intentData.relayer,
        receiverIsAccount: intentData.receiverIsAccount,
      };

      const tx = await this.contract.fillAndNotify(
        intentDataStruct,
        repaymentAddress,
        repaymentIsAccount,
        messengerId,
        { value: 0 } // Gas payment handled by messenger adapter
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
   * Call retryNotify() to resend a fill notification
   * Used when the original notification failed
   *
   * @param intentData Full intent data
   * @param messengerId Messenger to use for retry
   */
  async retryNotify(
    intentData: IntentData,
    messengerId: number
  ): Promise<FillResult> {
    try {
      const intentDataStruct = {
        intentId: intentData.intentId,
        sender: intentData.sender,
        refundAddress: intentData.refundAddress,
        sourceToken: intentData.sourceToken,
        sourceAmount: intentData.sourceAmount,
        sourceChainId: intentData.sourceChainId,
        destinationChainId: intentData.destinationChainId,
        destinationToken: intentData.destinationToken,
        receiver: intentData.receiver,
        destinationAmount: intentData.destinationAmount,
        deadline: intentData.deadline,
        createdAt: intentData.createdAt,
        relayer: intentData.relayer,
        receiverIsAccount: intentData.receiverIsAccount,
      };

      const tx = await this.contract.retryNotify(
        intentDataStruct,
        messengerId,
        { value: 0 }
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
   * Note: Event doesn't include receiverIsAccount, defaults to false
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
          refundAddress: args.sender, // Default
          sourceToken: args.sourceToken,
          sourceAmount: args.sourceAmount,
          destinationChainId: Number(args.destinationChainId),
          destinationToken: '',
          receiver: args.receiver,
          receiverIsAccount: false, // Default, should fetch from contract for actual value
          destinationAmount: args.destinationAmount,
          deadline: Number(args.deadline),
          createdAt: Math.floor(Date.now() / 1000), // Approximate
          status: IntentStatus.Pending,
          relayer: args.relayer,
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
