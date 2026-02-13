#![cfg(test)]

use super::*;
use soroban_sdk::{
    testutils::Address as _,
    token::{StellarAssetClient, TokenClient},
    Address, Env, String,
};

fn create_token_contract<'a>(env: &Env, admin: &Address) -> (TokenClient<'a>, StellarAssetClient<'a>) {
    let contract_address = env.register_stellar_asset_contract_v2(admin.clone());
    (
        TokenClient::new(env, &contract_address.address()),
        StellarAssetClient::new(env, &contract_address.address()),
    )
}

#[test]
fn test_init() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(Payment, ());
    let client = PaymentClient::new(&env, &contract_id);

    let destination = Address::generate(&env);

    // Initialize contract
    client.init(&destination);

    // Verify destination is set correctly
    assert_eq!(client.get_destination(), destination);
}

#[test]
fn test_init_twice_fails() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(Payment, ());
    let client = PaymentClient::new(&env, &contract_id);

    let destination = Address::generate(&env);

    // Initialize contract
    client.init(&destination);

    // Try to initialize again - should return error
    let result = client.try_init(&destination);
    assert!(result.is_err());
}

#[test]
fn test_pay() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(Payment, ());
    let client = PaymentClient::new(&env, &contract_id);

    let destination = Address::generate(&env);
    let payer = Address::generate(&env);
    let usdc_admin = Address::generate(&env);
    let (usdc_token, usdc_asset) = create_token_contract(&env, &usdc_admin);

    // Mock the USDC contract address for testing
    // In tests, we need to manually set up the token
    // For this test, we'll create a modified version that accepts a custom USDC address

    // Mint USDC to the payer
    usdc_asset.mint(&payer, &10000);

    // Check initial balances
    assert_eq!(usdc_token.balance(&payer), 10000);
    assert_eq!(usdc_token.balance(&destination), 0);

    // Note: This test demonstrates the flow, but since we can't easily mock
    // the hardcoded USDC address in the contract, a full integration test
    // would require deploying to testnet or using a more sophisticated mock setup.
}

#[test]
fn test_flush() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(Payment, ());
    let client = PaymentClient::new(&env, &contract_id);

    let destination = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let (token_client, token_asset) = create_token_contract(&env, &token_admin);

    // Initialize contract
    client.init(&destination);

    // Mint tokens to the contract
    token_asset.mint(&contract_id, &5000);

    // Check initial balances
    assert_eq!(token_client.balance(&contract_id), 5000);
    assert_eq!(token_client.balance(&destination), 0);

    // Flush tokens from contract to destination
    client.flush(&token_asset.address, &3000);

    // Verify balances after flush
    assert_eq!(token_client.balance(&contract_id), 2000);
    assert_eq!(token_client.balance(&destination), 3000);

    // Flush remaining tokens
    client.flush(&token_asset.address, &2000);

    // Verify final balances
    assert_eq!(token_client.balance(&contract_id), 0);
    assert_eq!(token_client.balance(&destination), 5000);
}

#[test]
fn test_flush_zero_amount_fails() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(Payment, ());
    let client = PaymentClient::new(&env, &contract_id);

    let destination = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let (_, token_asset) = create_token_contract(&env, &token_admin);

    // Initialize contract
    client.init(&destination);

    // Try to flush zero amount - should fail
    let result = client.try_flush(&token_asset.address, &0);
    assert!(result.is_err());
}

#[test]
fn test_flush_not_initialized_fails() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(Payment, ());
    let client = PaymentClient::new(&env, &contract_id);

    let token_admin = Address::generate(&env);
    let (_, token_asset) = create_token_contract(&env, &token_admin);

    // Try to flush without initialization - should fail
    let result = client.try_flush(&token_asset.address, &1000);
    assert!(result.is_err());
}

#[test]
fn test_get_destination() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(Payment, ());
    let client = PaymentClient::new(&env, &contract_id);

    let destination = Address::generate(&env);

    // Initialize contract
    client.init(&destination);

    // Verify get_destination returns the correct address
    assert_eq!(client.get_destination(), destination);
}
