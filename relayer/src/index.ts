import { loadConfig, validateConfig } from './config';
import { Relayer } from './relayer';

/**
 * Main entry point for the RozoIntents Relayer
 */
async function main(): Promise<void> {
  console.log('RozoIntents Relayer v0.1.0');
  console.log('==========================\n');

  try {
    // Load configuration
    console.log('Loading configuration...');
    const config = loadConfig();
    validateConfig(config);

    console.log(`Configured chains: ${config.chains.map(c => c.name).join(', ')}`);
    console.log(`Poll interval: ${config.pollIntervalMs}ms`);
    console.log(`Min profit: $${config.minProfitUsd}\n`);

    // Create and start relayer
    const relayer = new Relayer(config);
    await relayer.start();

    // Handle shutdown
    process.on('SIGINT', () => {
      console.log('\nReceived SIGINT, shutting down...');
      relayer.stop();
      process.exit(0);
    });

    process.on('SIGTERM', () => {
      console.log('\nReceived SIGTERM, shutting down...');
      relayer.stop();
      process.exit(0);
    });

    // Keep running
    console.log('\nRelayer is running. Press Ctrl+C to stop.\n');

  } catch (error) {
    console.error('Failed to start relayer:', error);
    process.exit(1);
  }
}

main();
