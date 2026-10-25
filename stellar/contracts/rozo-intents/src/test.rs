#![cfg(test)]

use super::*;
use crate::types::{CreateIntentParams, IntentStatus, RelayerType};
use soroban_sdk::{
    testutils::{Address as _, Events, Ledger, LedgerInfo},
    token::{Client as TokenClient, StellarAssetClient},
    Address, BytesN, Env, String, Symbol, TryFromVal, Val, Vec,
};

fn create_token_contract<'a>(env: &Env, admin: &Address) -> (Address, TokenClient<'a>) {
    let contract_address = env.register_stellar_asset_contract(admin.clone());
    (
        contract_address.clone(),
        TokenClient::new(env, &contract_address),
    )
}

fn zero_bytes32(env: &Env) -> BytesN<32> {
    BytesN::from_array(env, &[0u8; 32])
}

fn setup_env() -> (
    Env,
    Address, // contract
    Address, // owner
    Address, // sender
    Address, // receiver
    Address, // relayer
    Address, // token
    TokenClient<'static>,
) {
    let env = Env::default();
    env.mock_all_auths();

    let owner = Address::generate(&env);
    let sender = Address::generate(&env);
    let receiver = Address::generate(&env);
    let relayer = Address::generate(&env);

    // Deploy token
    let (token_address, token_client) = create_token_contract(&env, &owner);

    // Mint tokens to sender
    let stellar_asset = StellarAssetClient::new(&env, &token_address);
    stellar_asset.mint(&sender, &10_000_000_000i128); // 1000 USDC (7 decimals)

    // Mint tokens to relayer for fillAndNotify
    stellar_asset.mint(&relayer, &10_000_000_000i128);

    // Deploy RozoIntents contract
    let contract = env.register_contract(None, RozoIntentsContract);

    // Initialize with chain_id (Stellar = 1500)
    let client = RozoIntentsContractClient::new(&env, &contract);
    client.initialize(&owner, &owner, &1500u64);

    // Configure
    client.set_protocol_fee(&owner, &3); // 3 bps
    client.add_relayer(&owner, &relayer, &RelayerType::External);
    client.set_trusted_contract(
        &owner,
        &String::from_str(&env, "base"),
        &String::from_str(&env, "0x123..."),
    );
    client.set_chain_id_to_name(&owner, &8453u64, &String::from_str(&env, "base"));
    client.set_chain_id_to_name(&owner, &1500u64, &String::from_str(&env, "stellar"));

    (
        env,
        contract,
        owner,
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

type IntentCreatedData = (
    BytesN<32>, // sender
    BytesN<32>, // source_token
    i128,       // source_amount
    u64,        // source_chain_id
    u64,        // destination_chain_id
    BytesN<32>, // destination_token
    BytesN<32>, // receiver
    bool,       // receiver_is_account
    i128,       // destination_amount
    u64,        // deadline
    u64,        // created_at
    BytesN<32>, // refund_address
    BytesN<32>, // relayer
);

// Topics and data of the first event with this name emitted by the contract
fn find_event(env: &Env, contract: &Address, name: &str) -> (Vec<Val>, Val) {
    let name = Symbol::new(env, name);
    for (emitter, topics, data) in env.events().all().iter() {
        if emitter == *contract
            && Symbol::try_from_val(env, &topics.get(0).unwrap()) == Ok(name.clone())
        {
            return (topics, data);
        }
    }
    panic!("event not emitted");
}

// Rebuild IntentData from the intent_created event only
fn intent_data_from_created_event(env: &Env, contract: &Address) -> IntentData {
    let (topics, data) = find_event(env, contract, "intent_created");
    let (
        sender,
        source_token,
        source_amount,
        source_chain_id,
        destination_chain_id,
        destination_token,
        receiver,
        receiver_is_account,
        destination_amount,
        deadline,
        created_at,
        refund_address,
        relayer,
    ) = IntentCreatedData::try_from_val(env, &data).unwrap();
    IntentData {
        intent_id: BytesN::try_from_val(env, &topics.get(1).unwrap()).unwrap(),
        sender,
        refund_address,
        source_token,
        source_amount,
        source_chain_id,
        destination_chain_id,
        destination_token,
        receiver,
        destination_amount,
        deadline,
        created_at,
        relayer,
        receiver_is_account,
    }
}

#[test]
fn test_initialize() {
    let env = Env::default();
    env.mock_all_auths();

    let owner = Address::generate(&env);

    let contract = env.register_contract(None, RozoIntentsContract);
    let client = RozoIntentsContractClient::new(&env, &contract);

    // Initialize with chain_id
    client.initialize(&owner, &owner, &1500u64);

    // Should not be able to initialize again
    let result = client.try_initialize(&owner, &owner, &1500u64);
    assert!(result.is_err());
}

#[test]
fn test_create_intent() {
    let (env, contract, _owner, sender, receiver, _relayer, token, _token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);
    let zero_relayer = zero_bytes32(&env);

    // Set future timestamp
    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent with open relayer (zeros)
    let params = CreateIntentParams {
        intent_id: intent_id.clone(),
        source_token: token.clone(),
        source_amount: 1_000_000_000i128, // 100 USDC
        destination_chain_id: 8453u64,    // Base chain ID
        destination_token: token_bytes,
        receiver: receiver_bytes,
        receiver_is_account: false,
        destination_amount: 990_000_000i128, // 99 USDC
        deadline: 2000u64,
        refund_address: sender.clone(),
        relayer: zero_relayer, // open to any relayer
    };
    client.create_intent(&sender, &params);

    // Verify intent was created
    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.sender, sender);
    assert_eq!(intent.source_amount, 1_000_000_000i128);
    assert_eq!(intent.status, IntentStatus::Pending);
}

#[test]
fn test_create_intent_with_assigned_relayer() {
    let (env, contract, _owner, sender, receiver, _relayer, token, _token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);
    // Create a bytes32 representation of the relayer
    let relayer_bytes = BytesN::from_array(&env, &[3u8; 32]); // Different from receiver

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent with specific relayer
    let params = CreateIntentParams {
        intent_id: intent_id.clone(),
        source_token: token.clone(),
        source_amount: 1_000_000_000i128,
        destination_chain_id: 8453u64,
        destination_token: token_bytes,
        receiver: receiver_bytes,
        receiver_is_account: false,
        destination_amount: 990_000_000i128,
        deadline: 2000u64,
        refund_address: sender.clone(),
        relayer: relayer_bytes.clone(), // assigned relayer
    };
    client.create_intent(&sender, &params);

    // Verify intent has relayer assigned
    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.relayer, relayer_bytes);
    assert_eq!(intent.status, IntentStatus::Pending);
}

#[test]
fn test_refund_after_deadline() {
    let (env, contract, _owner, sender, receiver, _relayer, token, token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);
    let zero_relayer = zero_bytes32(&env);

    let initial_balance = token_client.balance(&sender);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent
    let amount = 1_000_000_000i128;
    let params = CreateIntentParams {
        intent_id: intent_id.clone(),
        source_token: token.clone(),
        source_amount: amount,
        destination_chain_id: 8453u64,
        destination_token: token_bytes,
        receiver: receiver_bytes,
        receiver_is_account: false,
        destination_amount: 990_000_000i128,
        deadline: 2000u64,
        refund_address: sender.clone(),
        relayer: zero_relayer,
    };
    client.create_intent(&sender, &params);

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
    let (env, contract, owner, _sender, _receiver, _relayer, _token, _token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);

    // Set protocol fee
    client.set_protocol_fee(&owner, &10);
    assert_eq!(client.get_protocol_fee(), 10);

    // Add/remove relayer with RelayerType
    let new_relayer = Address::generate(&env);
    client.add_relayer(&owner, &new_relayer, &RelayerType::External);
    assert!(client.is_relayer(&new_relayer));

    // Check relayer type
    let relayer_type = client.get_relayer_type(&new_relayer);
    assert_eq!(relayer_type, RelayerType::External);

    // Add Rozo relayer
    let rozo_relayer = Address::generate(&env);
    client.add_relayer(&owner, &rozo_relayer, &RelayerType::Rozo);
    let rozo_type = client.get_relayer_type(&rozo_relayer);
    assert_eq!(rozo_type, RelayerType::Rozo);

    client.remove_relayer(&owner, &new_relayer);
    assert!(!client.is_relayer(&new_relayer));

    // Set trusted contract
    client.set_trusted_contract(
        &owner,
        &String::from_str(&env, "ethereum"),
        &String::from_str(&env, "0x456..."),
    );
}

#[test]
fn test_rozo_relayer_config() {
    let (env, contract, owner, _sender, _receiver, _relayer, _token, _token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);

    // Set Rozo relayer
    let rozo = Address::generate(&env);
    client.set_rozo_relayer(&owner, &rozo);

    // Set Rozo threshold (e.g., 300 seconds = 5 minutes)
    client.set_rozo_threshold(&owner, &300u64);

    // Verify settings
    assert_eq!(client.get_rozo_threshold(), 300);
}

#[test]
fn test_admin_refund() {
    let (env, contract, owner, sender, receiver, _relayer, token, token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);
    let zero_relayer = zero_bytes32(&env);

    let initial_balance = token_client.balance(&sender);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent
    let amount = 1_000_000_000i128;
    let params = CreateIntentParams {
        intent_id: intent_id.clone(),
        source_token: token.clone(),
        source_amount: amount,
        destination_chain_id: 8453u64,
        destination_token: token_bytes,
        receiver: receiver_bytes,
        receiver_is_account: false,
        destination_amount: 990_000_000i128,
        deadline: 2000u64,
        refund_address: sender.clone(),
        relayer: zero_relayer,
    };
    client.create_intent(&sender, &params);

    // Admin refund (before deadline) - uses stored owner
    client.admin_refund(&owner, &intent_id);

    // Verify refund
    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.status, IntentStatus::Refunded);
    assert_eq!(token_client.balance(&sender), initial_balance);
}

#[test]
fn test_admin_set_intent_status() {
    let (env, contract, owner, sender, receiver, _relayer, token, _token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);
    let zero_relayer = zero_bytes32(&env);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent
    let params = CreateIntentParams {
        intent_id: intent_id.clone(),
        source_token: token.clone(),
        source_amount: 1_000_000_000i128,
        destination_chain_id: 8453u64,
        destination_token: token_bytes,
        receiver: receiver_bytes,
        receiver_is_account: false,
        destination_amount: 990_000_000i128,
        deadline: 2000u64,
        refund_address: sender.clone(),
        relayer: zero_relayer,
    };
    client.create_intent(&sender, &params);

    // Admin can change status
    client.set_intent_status(&owner, &intent_id, &IntentStatus::Failed);

    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.status, IntentStatus::Failed);
}

#[test]
fn test_admin_set_intent_relayer() {
    let (env, contract, owner, sender, receiver, _relayer, token, _token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let receiver_bytes = address_to_bytes32(&env, &receiver);
    let token_bytes = address_to_bytes32(&env, &token);
    let zero_relayer = zero_bytes32(&env);
    let new_relayer = BytesN::from_array(&env, &[5u8; 32]);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    // Create intent with no relayer
    let params = CreateIntentParams {
        intent_id: intent_id.clone(),
        source_token: token.clone(),
        source_amount: 1_000_000_000i128,
        destination_chain_id: 8453u64,
        destination_token: token_bytes,
        receiver: receiver_bytes,
        receiver_is_account: false,
        destination_amount: 990_000_000i128,
        deadline: 2000u64,
        refund_address: sender.clone(),
        relayer: zero_relayer,
    };
    client.create_intent(&sender, &params);

    // Admin can assign relayer
    client.set_intent_relayer(&owner, &intent_id, &new_relayer);

    let intent = client.get_intent(&intent_id);
    assert_eq!(intent.relayer, new_relayer);
}

#[test]
fn test_intent_created_event_rebuilds_fill_hash() {
    let (env, contract, owner, sender, receiver, relayer, token, _token_client) = setup_env();

    let client = RozoIntentsContractClient::new(&env, &contract);
    let intent_id = generate_intent_id(&env);
    let refund = Address::generate(&env);
    let relayer_bytes = crate::address_to_bytes32(&env, &relayer);

    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        ..env.ledger().get()
    });

    let params = CreateIntentParams {
        intent_id: intent_id.clone(),
        source_token: token.clone(),
        source_amount: 1_000_000_000i128,
        destination_chain_id: 8453u64,
        destination_token: BytesN::from_array(&env, &[9u8; 32]),
        receiver: crate::address_to_bytes32(&env, &receiver),
        receiver_is_account: true,
        destination_amount: 990_000_000i128,
        deadline: 2000u64,
        refund_address: refund.clone(),
        relayer: relayer_bytes.clone(), // assigned relayer
    };
    client.create_intent(&sender, &params);

    let intent_data = intent_data_from_created_event(&env, &contract);
    assert_eq!(intent_data.intent_id, intent_id);
    assert_eq!(intent_data.source_chain_id, 1500);
    assert_eq!(intent_data.created_at, 1000);
    assert_eq!(
        intent_data.refund_address,
        crate::address_to_bytes32(&env, &refund)
    );
    assert!(intent_data.receiver_is_account);
    let fill_hash = compute_fill_hash(&env, &intent_data);

    env.ledger().set(LedgerInfo {
        timestamp: 1100,
        ..env.ledger().get()
    });

    // complete_fill reports the hash it verifies against when a notification does not match
    let adapter = Address::generate(&env);
    client.set_msger_adapter(&owner, &0u32, &adapter);
    let wrong_hash = zero_bytes32(&env);
    let payload = encode_notify_payload(
        &env,
        &intent_id,
        &wrong_hash,
        &relayer_bytes,
        &relayer_bytes,
        990_000_000i128,
        false,
    );
    client.notify(&adapter, &0u32, &8453u64, &payload);

    let (_, data) = find_event(&env, &contract, "intent_failed");
    let (expected_fill_hash, received_fill_hash) =
        <(BytesN<32>, BytesN<32>)>::try_from_val(&env, &data).unwrap();
    assert_eq!(received_fill_hash, wrong_hash);
    assert_eq!(expected_fill_hash, fill_hash);
}
