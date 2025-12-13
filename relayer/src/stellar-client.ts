import * as StellarSdk from '@stellar/stellar-sdk';
import { ChainConfig, IntentData, FillResult } from './types';

// Soroban contract function names
const FILL_AND_NOTIFY_FN = 'fill_and_notify';
const RETRY_NOTIFY_FN = 'retry_notify';

export class StellarClient {
  private server: StellarSdk.SorobanRpc.Server;
  private keypair: StellarSdk.Keypair;
  private contractId: string;
  private networkPassphrase: string;

  constructor(chainConfig: ChainConfig, secretKey: string) {
    // Determine network
    const isMainnet = chainConfig.rpcUrl.includes('horizon.stellar.org') &&
                      !chainConfig.rpcUrl.includes('testnet');

    this.networkPassphrase = isMainnet
      ? StellarSdk.Networks.PUBLIC
      : StellarSdk.Networks.TESTNET;

    // Use Soroban RPC server (not Horizon)
    const sorobanRpcUrl = isMainnet
      ? 'https://soroban-rpc.stellar.org'
      : 'https://soroban-testnet.stellar.org';

    this.server = new StellarSdk.SorobanRpc.Server(sorobanRpcUrl);
    this.keypair = StellarSdk.Keypair.fromSecret(secretKey);
    this.contractId = chainConfig.contractAddress;
  }

  /**
   * Get the relayer public key
   */
  getRelayerAddress(): string {
    return this.keypair.publicKey();
  }

  /**
   * Get the relayer address as bytes32 for cross-chain use
   */
  getRelayerAddressBytes32(): string {
    // Convert Stellar public key to bytes32
    const pubKeyBytes = StellarSdk.StrKey.decodeEd25519PublicKey(this.keypair.publicKey());
    return '0x' + Buffer.from(pubKeyBytes).toString('hex');
  }

  /**
   * Helper to convert IntentData to Soroban struct
   */
  private intentDataToScVal(env: any, intentData: IntentData): any {
    return StellarSdk.nativeToScVal({
      intent_id: Buffer.from(intentData.intentId.replace('0x', ''), 'hex'),
      sender: Buffer.from(intentData.sender.replace('0x', ''), 'hex'),
      refund_address: Buffer.from(intentData.refundAddress.replace('0x', ''), 'hex'),
      source_token: Buffer.from(intentData.sourceToken.replace('0x', ''), 'hex'),
      source_amount: intentData.sourceAmount,
      source_chain_id: BigInt(intentData.sourceChainId),
      destination_chain_id: BigInt(intentData.destinationChainId),
      destination_token: intentData.destinationToken, // Address on Stellar
      receiver: intentData.receiver, // Address on Stellar
      destination_amount: intentData.destinationAmount,
      deadline: BigInt(intentData.deadline),
      created_at: BigInt(intentData.createdAt),
      relayer: Buffer.from(intentData.relayer.replace('0x', ''), 'hex'),
    }, { type: 'struct' });
  }

  /**
   * Call fillAndNotify() on the Stellar contract
   * This pays the receiver and sends notification via messenger
   *
   * @param intentData Full intent data for verification
   * @param repaymentAddress Where to receive payment on source chain (bytes32)
   * @param messengerId Messenger to use (0 = Rozo, 1 = Axelar)
   */
  async fillAndNotify(
    intentData: IntentData,
    repaymentAddress: string,
    messengerId: number = 0
  ): Promise<FillResult> {
    try {
      const account = await this.server.getAccount(this.keypair.publicKey());

      const contract = new StellarSdk.Contract(this.contractId);

      // Build the IntentData struct for Soroban
      const intentDataMap = new Map();
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('intent_id'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.intentId.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('sender'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.sender.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('refund_address'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.refundAddress.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('source_token'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.sourceToken.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('source_amount'),
        StellarSdk.nativeToScVal(intentData.sourceAmount, { type: 'i128' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('source_chain_id'),
        StellarSdk.nativeToScVal(BigInt(intentData.sourceChainId), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('destination_chain_id'),
        StellarSdk.nativeToScVal(BigInt(intentData.destinationChainId), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('destination_token'),
        StellarSdk.nativeToScVal(intentData.destinationToken, { type: 'address' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('receiver'),
        StellarSdk.nativeToScVal(intentData.receiver, { type: 'address' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('destination_amount'),
        StellarSdk.nativeToScVal(intentData.destinationAmount, { type: 'i128' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('deadline'),
        StellarSdk.nativeToScVal(BigInt(intentData.deadline), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('created_at'),
        StellarSdk.nativeToScVal(BigInt(intentData.createdAt), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('relayer'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.relayer.replace('0x', ''), 'hex'), { type: 'bytes' }));

      // Convert repaymentAddress to bytes32
      const repaymentAddressBytes = Buffer.from(repaymentAddress.replace('0x', ''), 'hex');

      // Build the fillAndNotify transaction
      const tx = new StellarSdk.TransactionBuilder(account, {
        fee: '100000', // 0.01 XLM
        networkPassphrase: this.networkPassphrase,
      })
        .addOperation(
          contract.call(
            FILL_AND_NOTIFY_FN,
            StellarSdk.xdr.ScVal.scvMap([...intentDataMap.entries()].map(([k, v]) =>
              new StellarSdk.xdr.ScMapEntry({ key: k, val: v })
            )),
            StellarSdk.nativeToScVal(repaymentAddressBytes, { type: 'bytes' }),
            StellarSdk.nativeToScVal(messengerId, { type: 'u32' })
          )
        )
        .setTimeout(30)
        .build();

      // Simulate
      const simulated = await this.server.simulateTransaction(tx);

      if (StellarSdk.SorobanRpc.Api.isSimulationError(simulated)) {
        return {
          success: false,
          error: `Simulation failed: ${simulated.error}`,
        };
      }

      // Prepare and sign
      const preparedTx = StellarSdk.SorobanRpc.assembleTransaction(tx, simulated).build();
      preparedTx.sign(this.keypair);

      // Submit
      const result = await this.server.sendTransaction(preparedTx);

      if (result.status === 'ERROR') {
        return {
          success: false,
          error: `Transaction failed: ${result.errorResult}`,
        };
      }

      // Wait for confirmation
      let txResult = await this.server.getTransaction(result.hash);
      while (txResult.status === 'NOT_FOUND') {
        await new Promise(resolve => setTimeout(resolve, 1000));
        txResult = await this.server.getTransaction(result.hash);
      }

      if (txResult.status === 'SUCCESS') {
        return {
          success: true,
          txHash: result.hash,
        };
      }

      return {
        success: false,
        error: `Transaction status: ${txResult.status}`,
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
      const account = await this.server.getAccount(this.keypair.publicKey());

      const contract = new StellarSdk.Contract(this.contractId);

      // Build the IntentData struct for Soroban (same as fillAndNotify)
      const intentDataMap = new Map();
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('intent_id'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.intentId.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('sender'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.sender.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('refund_address'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.refundAddress.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('source_token'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.sourceToken.replace('0x', ''), 'hex'), { type: 'bytes' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('source_amount'),
        StellarSdk.nativeToScVal(intentData.sourceAmount, { type: 'i128' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('source_chain_id'),
        StellarSdk.nativeToScVal(BigInt(intentData.sourceChainId), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('destination_chain_id'),
        StellarSdk.nativeToScVal(BigInt(intentData.destinationChainId), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('destination_token'),
        StellarSdk.nativeToScVal(intentData.destinationToken, { type: 'address' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('receiver'),
        StellarSdk.nativeToScVal(intentData.receiver, { type: 'address' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('destination_amount'),
        StellarSdk.nativeToScVal(intentData.destinationAmount, { type: 'i128' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('deadline'),
        StellarSdk.nativeToScVal(BigInt(intentData.deadline), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('created_at'),
        StellarSdk.nativeToScVal(BigInt(intentData.createdAt), { type: 'u64' }));
      intentDataMap.set(StellarSdk.xdr.ScVal.scvSymbol('relayer'),
        StellarSdk.nativeToScVal(Buffer.from(intentData.relayer.replace('0x', ''), 'hex'), { type: 'bytes' }));

      // Build the retryNotify transaction
      const tx = new StellarSdk.TransactionBuilder(account, {
        fee: '100000',
        networkPassphrase: this.networkPassphrase,
      })
        .addOperation(
          contract.call(
            RETRY_NOTIFY_FN,
            StellarSdk.xdr.ScVal.scvMap([...intentDataMap.entries()].map(([k, v]) =>
              new StellarSdk.xdr.ScMapEntry({ key: k, val: v })
            )),
            StellarSdk.nativeToScVal(messengerId, { type: 'u32' })
          )
        )
        .setTimeout(30)
        .build();

      // Simulate
      const simulated = await this.server.simulateTransaction(tx);

      if (StellarSdk.SorobanRpc.Api.isSimulationError(simulated)) {
        return {
          success: false,
          error: `Simulation failed: ${simulated.error}`,
        };
      }

      // Prepare and sign
      const preparedTx = StellarSdk.SorobanRpc.assembleTransaction(tx, simulated).build();
      preparedTx.sign(this.keypair);

      // Submit
      const result = await this.server.sendTransaction(preparedTx);

      if (result.status === 'ERROR') {
        return {
          success: false,
          error: `Transaction failed: ${result.errorResult}`,
        };
      }

      // Wait for confirmation
      let txResult = await this.server.getTransaction(result.hash);
      while (txResult.status === 'NOT_FOUND') {
        await new Promise(resolve => setTimeout(resolve, 1000));
        txResult = await this.server.getTransaction(result.hash);
      }

      if (txResult.status === 'SUCCESS') {
        return {
          success: true,
          txHash: result.hash,
        };
      }

      return {
        success: false,
        error: `Transaction status: ${txResult.status}`,
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message || 'Unknown error',
      };
    }
  }
}
