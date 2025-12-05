#![cfg(test)]

use super::*;
use soroban_sdk::{
    testutils::{Address as _, Ledger, LedgerInfo},
    token::{Client as TokenClient, StellarAssetClient},
    Address, BytesN, Env, IntoVal, String,
};

fn create_token_contract<'a>(env: &Env, admin: &Address) -> (Address, TokenClient<'a>) {
    let contract_address = env.register_stellar_asset_contract(admin.clone());
    (
        contract_address.clone(),
        TokenClient::new(env, &contract_address),
    )
}

fn setup_env() -> (
    Env,
    Address, // contract
    Address, // owner
    Address, // gateway
    Address, // gas_service
    Address, // sender
    Address, // receiver
    Address, // relayer
    Address, // token
    TokenClient<'static>,
) {
    let env = Env::default();
    env.mock_all_auths();

    let owner = Address::generate(&env);
    let gateway = Address::generate(&env);
    let gas_service = Address::generate(&env);
    let sender = Address::generate(&env);
    let receiver = Address::generate(&env);
    let relayer = Address::generate(&env);

    // Deploy token
    let (token_address, token_client) = create_token_contract(&env, &owner);

    // Mint tokens to sender
    let stellar_asset = StellarAssetClient::new(&env, &token_address);
    stellar_asset.mint(&sender, &10_000_000_000i128); // 1000 USDC (7 decimals)

    // Deploy RozoIntents contract
    let contract = env.register_contract(None, RozoIntentsContract);

    // Initialize
    let client = RozoIntentsContractClient::new(&env, &contract);
    client.initialize(&owner, &gateway, &gas_service, &owner);

    // Configure
    client.set_protocol_fee(&3); // 3 bps
    client.add_relayer(&relayer);
    client.set_trusted_contract(
        &String::from_str(&env, "base"),
        &String::from_str(&env, "0x123..."),
    );
    client.set_chain_id_to_name(&8453u64, &String::from_str(&env, "base"));
    client.set_chain_id_to_name(&1500u64, &String::from_str(&env, "stellar"));

    (
        env,
        contract,
        owner,
        gateway,
        gas_service,
        sender,
        receiver,
        relayer,
        token_address,
        token_client,
    )
}

fn generate_intent_id(env: &Env) -> BytesN<32> {
    BytesN::from_array(env, &[1u8; 32])
}

fn address_to_bytes32(env: &Env, _addr: &Address) -> BytesN<32> {
    // Simplified conversion for testing
    BytesN::from_array(env, &[2u8; 32])
}

#[test]
fn test_initialize() {
    let env = Env::default();
    env.mock_all_auths();

    let owner = Address::generate(&env);
    let gateway = Address::generate(&env);
    let gas_service = Address::generate(&env);

    let contract = env.register_contract(None, RozoIntentsContract);
    let client = RozoIntentsContractClient::new(&env, &contract);

    client.initialize(&owner, &gateway, &gas_service, &owner);

    // Should not be able to initialize again
    let result = client.try_initialize(&owner, &gateway, &gas_service, &owner);
    assert!(result.is_err());
}

#[test]
fn test_create_intent() {
    let (env, contract, _owner, _gateway, _gas_service, sender, receiver, _relayer, token, _token_client) =
        setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);

    // Set future timestamp
    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent
    // Args: sender, intent_id, source_token, source_amount, destination_chain_id,
    //       destination_token, receiver, destination_amount, deadline, refund_address
    client.create_intent(
        &sender,
        &intent_id,
        &token,
        &1_000_000_000i128, // 100 USDC
        &8453u64,           // Base chain ID
        &token_bytes,
        &receiver_bytes,
        &990_000_000i128, // 99 USDC
        &2000u64,         // deadline
        &sender,          // refund_address
    );

    // Verify intent was created
    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.sender, sender);
    assert_eq!(intent.source_amount, 1_000_000_000i128);
    assert_eq!(intent.status, IntentStatus::New);
}

#[test]
fn test_fill() {
    let (env, contract, _owner, _gateway, _gas_service, sender, receiver, relayer, token, _token_client) =
        setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent
    client.create_intent(
        &sender,
        &intent_id,
        &token,
        &1_000_000_000i128,
        &8453u64,
        &token_bytes,
        &receiver_bytes,
        &990_000_000i128,
        &2000u64,
        &sender,
    );

    // Relayer fills
    client.fill(&relayer, &intent_id);

    // Verify status changed
    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.status, IntentStatus::Filling);
    assert_eq!(intent.relayer, Some(relayer));
}

#[test]
fn test_refund_after_deadline() {
    let (env, contract, _owner, _gateway, _gas_service, sender, receiver, _relayer, token, token_client) =
        setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);

    let initial_balance = token_client.balance(&sender);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent
    let amount = 1_000_000_000i128;
    client.create_intent(
        &sender,
        &intent_id,
        &token,
        &amount,
        &8453u64,
        &token_bytes,
        &receiver_bytes,
        &990_000_000i128,
        &2000u64,
        &sender,
    );

    // Verify tokens were transferred
    assert_eq!(token_client.balance(&sender), initial_balance - amount);

    // Move past deadline
    env.ledger().set(LedgerInfo {
        timestamp: 3000,
        ..env.ledger().get()
    });

    // Refund - anyone can call after deadline
    client.refund(&sender, &intent_id);

    // Verify refund
    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.status, IntentStatus::Refunded);
    assert_eq!(token_client.balance(&sender), initial_balance);
}

#[test]
fn test_admin_functions() {
    let (env, contract, _owner, _gateway, _gas_service, _sender, _receiver, _relayer, _token, _token_client) =
        setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);

    // Set protocol fee
    client.set_protocol_fee(&10);
    assert_eq!(client.get_protocol_fee(), 10);

    // Add/remove relayer
    let new_relayer = Address::generate(&env);
    client.add_relayer(&new_relayer);
    assert!(client.is_relayer(&new_relayer));

    client.remove_relayer(&new_relayer);
    assert!(!client.is_relayer(&new_relayer));

    // Set trusted contract
    client.set_trusted_contract(
        &String::from_str(&env, "ethereum"),
        &String::from_str(&env, "0x456..."),
    );
}

#[test]
fn test_admin_refund() {
    let (env, contract, _owner, _gateway, _gas_service, sender, receiver, _relayer, token, token_client) =
        setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);

    let initial_balance = token_client.balance(&sender);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent
    let amount = 1_000_000_000i128;
    client.create_intent(
        &sender,
        &intent_id,
        &token,
        &amount,
        &8453u64,
        &token_bytes,
        &receiver_bytes,
        &990_000_000i128,
        &2000u64,
        &sender,
    );

    // Admin refund (before deadline) - uses stored owner
    client.admin_refund(&intent_id);

    // Verify refund
    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.status, IntentStatus::Refunded);
    assert_eq!(token_client.balance(&sender), initial_balance);
}
