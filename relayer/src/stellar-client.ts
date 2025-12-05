import * as StellarSdk from '@stellar/stellar-sdk';
import { ChainConfig, FillResult } from './types';

// Soroban contract function names
const FILL_FN = 'fill';
const FILL_AND_NOTIFY_FN = 'fill_and_notify';

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
   * Call fill() on the Stellar contract
   */
  async fill(intentId: string): Promise<FillResult> {
    try {
      const account = await this.server.getAccount(this.keypair.publicKey());

      // Convert intentId hex string to bytes
      const intentIdBytes = Buffer.from(intentId.replace('0x', ''), 'hex');

      const contract = new StellarSdk.Contract(this.contractId);

      // Build the fill transaction
      const tx = new StellarSdk.TransactionBuilder(account, {
        fee: '100000', // 0.01 XLM
        networkPassphrase: this.networkPassphrase,
      })
        .addOperation(
          contract.call(
            FILL_FN,
            StellarSdk.nativeToScVal(this.keypair.publicKey(), { type: 'address' }),
            StellarSdk.nativeToScVal(intentIdBytes, { type: 'bytes' })
          )
        )
        .setTimeout(30)
        .build();

      // Simulate to get actual fees
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
   * Call fillAndNotify() on the Stellar contract
   * This pays the receiver and sends notification via Axelar
   */
  async fillAndNotify(
    intentId: string,
    receiver: string,
    amount: bigint,
    sourceChain: string,
    gasToken: string,
    gasFee: bigint
  ): Promise<FillResult> {
    try {
      const account = await this.server.getAccount(this.keypair.publicKey());

      const intentIdBytes = Buffer.from(intentId.replace('0x', ''), 'hex');
      const receiverBytes = Buffer.from(receiver.replace('0x', ''), 'hex');

      const contract = new StellarSdk.Contract(this.contractId);

      // Build the fillAndNotify transaction
      const tx = new StellarSdk.TransactionBuilder(account, {
        fee: '100000',
        networkPassphrase: this.networkPassphrase,
      })
        .addOperation(
          contract.call(
            FILL_AND_NOTIFY_FN,
            StellarSdk.nativeToScVal(this.keypair.publicKey(), { type: 'address' }),
            StellarSdk.nativeToScVal(intentIdBytes, { type: 'bytes' }),
            StellarSdk.nativeToScVal(receiverBytes, { type: 'bytes' }),
            StellarSdk.nativeToScVal(amount, { type: 'i128' }),
            StellarSdk.nativeToScVal(sourceChain, { type: 'string' }),
            StellarSdk.nativeToScVal(gasToken, { type: 'address' }),
            StellarSdk.nativeToScVal(gasFee, { type: 'i128' })
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
