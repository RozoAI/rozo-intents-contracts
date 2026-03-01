#![cfg(test)]

use crate::{Error, IntentBridge, IntentBridgeClient, IntentStatus};
use soroban_sdk::{
    testutils::{Address as _, Ledger, LedgerInfo},
    token, vec, Address, Env, IntoVal, String,
};

const DAY_IN_SECS: u64 = 86400;

fn advance_ledger(env: &Env, by_secs: u64) {
    let current = env.ledger().get();
    env.ledger().set(LedgerInfo {
        timestamp: current.timestamp + by_secs,
        protocol_version: current.protocol_version,
        sequence_number: current.sequence_number + 1,
        network_id: current.network_id,
        base_reserve: current.base_reserve,
        min_temp_entry_ttl: current.min_temp_entry_ttl,
        min_persistent_entry_ttl: current.min_persistent_entry_ttl,
        max_entry_ttl: current.max_entry_ttl,
    });
}

fn create_token_contract<'a>(env: &Env, admin: &Address) -> token::Client<'a> {
    let token_address = env.register_stellar_asset_contract_v2(admin.clone());
    token::Client::new(env, &token_address.address())
}

fn setup_env() -> (
    Env,
    Address,
    Address,
    IntentBridgeClient<'static>,
) {
    let env = Env::default();
    env.mock_all_auths();

    // Set initial ledger
    env.ledger().set(LedgerInfo {
        timestamp: 1000,
        protocol_version: 22,
        sequence_number: 100,
        network_id: Default::default(),
        base_reserve: 10,
        min_temp_entry_ttl: 10,
        min_persistent_entry_ttl: 10,
        max_entry_ttl: 3110400,
    });

    let messenger = Address::generate(&env);
    let relayer = Address::generate(&env);

    // Use constructor pattern - pass args to register
    let contract_id = env.register(
        IntentBridge,
        (messenger.clone(), relayer.clone(), DAY_IN_SECS),
    );
    let client = IntentBridgeClient::new(&env, &contract_id);

    (env, messenger, relayer, client)
}

#[test]
fn test_constructor_sets_config() {
    let (_env, messenger, relayer, client) = setup_env();

    assert_eq!(client.get_messenger(), Some(messenger));
    assert_eq!(client.get_relayer(), Some(relayer));
    assert_eq!(client.get_deadline_duration(), Some(DAY_IN_SECS));
}

#[test]
fn test_create_intent_success() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    // Mint tokens to sender
    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234567890abcdef");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Check intent
    let intent = client.get_intent(&intent_id).unwrap();
    assert_eq!(intent.sender, sender);
    assert_eq!(intent.source_amount, 500);
    assert_eq!(intent.destination_amount, 400);
    assert_eq!(intent.status, IntentStatus::Pending);

    // Check token locked
    assert_eq!(token.balance(&sender), 500);
    assert_eq!(token.balance(&client.address), 500);
}

#[test]
fn test_create_intent_zero_amount() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_addr = Address::generate(&env);
    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let result = client.try_create_intent(
        &sender,
        &token_addr,
        &0,
        &dest_chain,
        &dest_addr,
        &0,
        &memo,
    );
    assert_eq!(result, Err(Ok(Error::ZeroAmount)));
}

#[test]
fn test_create_intent_memo_too_long() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_addr = Address::generate(&env);
    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "this memo is way too long and exceeds 28 bytes limit");

    let result = client.try_create_intent(
        &sender,
        &token_addr,
        &100,
        &dest_chain,
        &dest_addr,
        &90,
        &memo,
    );
    assert_eq!(result, Err(Ok(Error::MemoTooLong)));
}

#[test]
fn test_fill_success() {
    let (env, _messenger, relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Fill the intent
    client.fill(&intent_id);

    // Check status
    let intent = client.get_intent(&intent_id).unwrap();
    assert_eq!(intent.status, IntentStatus::Filled);

    // Check funds transferred to relayer
    assert_eq!(token.balance(&client.address), 0);
    assert_eq!(token.balance(&relayer), 500);
}

#[test]
fn test_fill_not_found() {
    let (env, _messenger, _relayer, client) = setup_env();

    let fake_id = soroban_sdk::BytesN::from_array(&env, &[0u8; 32]);
    let result = client.try_fill(&fake_id);
    assert_eq!(result, Err(Ok(Error::IntentNotFound)));
}

#[test]
fn test_fill_deadline_exceeded() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Advance time past deadline
    advance_ledger(&env, DAY_IN_SECS + 1);

    let result = client.try_fill(&intent_id);
    assert_eq!(result, Err(Ok(Error::DeadlineExceeded)));
}

#[test]
fn test_fill_already_filled() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    client.fill(&intent_id);

    // Try to fill again
    let result = client.try_fill(&intent_id);
    assert_eq!(result, Err(Ok(Error::InvalidStatus)));
}

#[test]
fn test_refund_success() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Advance time past deadline
    advance_ledger(&env, DAY_IN_SECS + 1);

    // Refund
    client.refund(&intent_id);

    // Check status
    let intent = client.get_intent(&intent_id).unwrap();
    assert_eq!(intent.status, IntentStatus::Refunded);

    // Check funds returned to sender
    assert_eq!(token.balance(&client.address), 0);
    assert_eq!(token.balance(&sender), 1000);
}

#[test]
fn test_refund_deadline_not_reached() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Try to refund before deadline
    let result = client.try_refund(&intent_id);
    assert_eq!(result, Err(Ok(Error::DeadlineNotReached)));
}

#[test]
fn test_refund_already_filled() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Fill the intent
    client.fill(&intent_id);

    // Advance time past deadline
    advance_ledger(&env, DAY_IN_SECS + 1);

    // Try to refund after fill
    let result = client.try_refund(&intent_id);
    assert_eq!(result, Err(Ok(Error::InvalidStatus)));
}

#[test]
fn test_refund_already_refunded() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Advance time past deadline
    advance_ledger(&env, DAY_IN_SECS + 1);

    // Refund
    client.refund(&intent_id);

    // Try to refund again
    let result = client.try_refund(&intent_id);
    assert_eq!(result, Err(Ok(Error::InvalidStatus)));
}

// =============================================================================
// Authorization Tests (using mock_auths to test specific auth requirements)
// =============================================================================

/// These tests verify that authorization is properly enforced by using mock_auths
/// to provide authorization for specific addresses, and verifying the call fails
/// when the wrong address provides authorization.

#[test]
#[should_panic(expected = "HostError: Error(Auth")]
fn test_fill_unauthorized_caller() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);
    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Now try to fill with a wrong caller's authorization
    // fill() requires messenger.require_auth(), so providing wrong address auth should fail
    let wrong_caller = Address::generate(&env);
    env.mock_auths(&[soroban_sdk::testutils::MockAuth {
        address: &wrong_caller,
        invoke: &soroban_sdk::testutils::MockAuthInvoke {
            contract: &client.address,
            fn_name: "fill",
            args: (&intent_id,).into_val(&env),
            sub_invokes: &[],
        },
    }]);

    client.fill(&intent_id);
}

#[test]
#[should_panic(expected = "HostError: Error(Auth")]
fn test_refund_unauthorized_caller() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);
    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let intent_id = client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );

    // Advance past deadline
    advance_ledger(&env, DAY_IN_SECS + 1);

    // Now try to refund with a different address (not the sender)
    // refund() requires intent.sender.require_auth(), so providing wrong address auth should fail
    let wrong_caller = Address::generate(&env);
    env.mock_auths(&[soroban_sdk::testutils::MockAuth {
        address: &wrong_caller,
        invoke: &soroban_sdk::testutils::MockAuthInvoke {
            contract: &client.address,
            fn_name: "refund",
            args: (&intent_id,).into_val(&env),
            sub_invokes: &[],
        },
    }]);

    client.refund(&intent_id);
}

#[test]
#[should_panic(expected = "HostError: Error(Auth")]
fn test_create_intent_unauthorized_sender() {
    let (env, _messenger, _relayer, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);
    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let dest_chain = String::from_str(&env, "ethereum");
    let dest_addr = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    // Provide authorization for wrong address
    // create_intent() requires sender.require_auth(), so providing different address auth should fail
    let wrong_caller = Address::generate(&env);
    env.mock_auths(&[soroban_sdk::testutils::MockAuth {
        address: &wrong_caller,
        invoke: &soroban_sdk::testutils::MockAuthInvoke {
            contract: &client.address,
            fn_name: "create_intent",
            args: vec![
                &env,
                sender.into_val(&env),
                token.address.into_val(&env),
                500i128.into_val(&env),
                dest_chain.into_val(&env),
                dest_addr.into_val(&env),
                400i128.into_val(&env),
                memo.into_val(&env),
            ],
            sub_invokes: &[],
        },
    }]);

    client.create_intent(
        &sender,
        &token.address,
        &500,
        &dest_chain,
        &dest_addr,
        &400,
        &memo,
    );
}
