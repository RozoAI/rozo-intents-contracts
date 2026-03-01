#![cfg(test)]

use crate::{Error, TokenForwarder, TokenForwarderClient};
use soroban_sdk::{
    testutils::Address as _,
    token, vec, Address, Env, IntoVal, String,
};

fn create_token_contract<'a>(env: &Env, admin: &Address) -> token::Client<'a> {
    let token_address = env.register_stellar_asset_contract_v2(admin.clone());
    token::Client::new(env, &token_address.address())
}

fn setup_env() -> (Env, Address, Address, TokenForwarderClient<'static>) {
    let env = Env::default();
    env.mock_all_auths();

    let admin = Address::generate(&env);
    let proxy_address = Address::generate(&env);

    // Use constructor pattern - pass args to register
    let contract_id = env.register(
        TokenForwarder,
        (admin.clone(), proxy_address.clone()),
    );
    let client = TokenForwarderClient::new(&env, &contract_id);

    (env, admin, proxy_address, client)
}

#[test]
fn test_constructor_sets_config() {
    let (_env, admin, proxy_address, client) = setup_env();

    assert_eq!(client.get_admin(), Some(admin));
    assert_eq!(client.get_proxy_address(), Some(proxy_address));
}

#[test]
fn test_forward_success() {
    let (env, _admin, proxy_address, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    // Mint tokens to sender
    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let to = String::from_str(&env, "0x1234567890abcdef");
    let memo = String::from_str(&env, "test memo");

    client.forward(&sender, &token.address, &500, &to, &memo);

    // Check balances
    assert_eq!(token.balance(&sender), 500);
    assert_eq!(token.balance(&proxy_address), 500);
}

#[test]
fn test_forward_zero_amount() {
    let (env, _admin, _proxy_address, client) = setup_env();

    let sender = Address::generate(&env);
    let token_addr = Address::generate(&env);
    let to = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "test");

    let result = client.try_forward(&sender, &token_addr, &0, &to, &memo);
    assert_eq!(result, Err(Ok(Error::ZeroAmount)));
}

#[test]
fn test_forward_empty_destination() {
    let (env, _admin, _proxy_address, client) = setup_env();

    let sender = Address::generate(&env);
    let token_addr = Address::generate(&env);
    let to = String::from_str(&env, "");
    let memo = String::from_str(&env, "test");

    let result = client.try_forward(&sender, &token_addr, &100, &to, &memo);
    assert_eq!(result, Err(Ok(Error::EmptyDestination)));
}

#[test]
fn test_forward_memo_too_long() {
    let (env, _admin, _proxy_address, client) = setup_env();

    let sender = Address::generate(&env);
    let token_addr = Address::generate(&env);
    let to = String::from_str(&env, "0x1234");
    let memo = String::from_str(&env, "this memo is way too long and exceeds 28 bytes");

    let result = client.try_forward(&sender, &token_addr, &100, &to, &memo);
    assert_eq!(result, Err(Ok(Error::MemoTooLong)));
}

#[test]
fn test_set_proxy_address() {
    let (env, _admin, _proxy_address, client) = setup_env();

    let new_proxy = Address::generate(&env);
    client.set_proxy_address(&new_proxy);

    assert_eq!(client.get_proxy_address(), Some(new_proxy));
}

#[test]
fn test_flush() {
    let (env, _admin, proxy_address, client) = setup_env();

    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    // Mint tokens directly to contract
    let contract_address = client.address.clone();
    token::StellarAssetClient::new(&env, &token.address).mint(&contract_address, &1000);

    // Flush tokens
    client.flush(&token.address, &500);

    assert_eq!(token.balance(&contract_address), 500);
    assert_eq!(token.balance(&proxy_address), 500);
}

#[test]
fn test_flush_zero_amount() {
    let (env, _admin, _proxy_address, client) = setup_env();

    let token_addr = Address::generate(&env);
    let result = client.try_flush(&token_addr, &0);
    assert_eq!(result, Err(Ok(Error::ZeroAmount)));
}

// =============================================================================
// Authorization Tests (using mock_auths to test specific auth requirements)
// =============================================================================

/// These tests verify that authorization is properly enforced by using mock_auths
/// to provide authorization for specific addresses, and verifying the call fails
/// when the wrong address provides authorization.

#[test]
#[should_panic(expected = "HostError: Error(Auth")]
fn test_set_proxy_address_unauthorized() {
    let (env, _admin, _proxy_address, client) = setup_env();

    // Try to set proxy address with wrong caller (not admin)
    let wrong_caller = Address::generate(&env);
    let new_proxy = Address::generate(&env);

    env.mock_auths(&[soroban_sdk::testutils::MockAuth {
        address: &wrong_caller,
        invoke: &soroban_sdk::testutils::MockAuthInvoke {
            contract: &client.address,
            fn_name: "set_proxy_address",
            args: (&new_proxy,).into_val(&env),
            sub_invokes: &[],
        },
    }]);

    // This should fail - wrong_caller is not admin
    client.set_proxy_address(&new_proxy);
}

#[test]
fn test_set_proxy_address_authorized() {
    let (env, admin, _proxy_address, client) = setup_env();

    let new_proxy = Address::generate(&env);

    // Mock auth for the correct admin
    env.mock_auths(&[soroban_sdk::testutils::MockAuth {
        address: &admin,
        invoke: &soroban_sdk::testutils::MockAuthInvoke {
            contract: &client.address,
            fn_name: "set_proxy_address",
            args: (&new_proxy,).into_val(&env),
            sub_invokes: &[],
        },
    }]);

    // This should succeed - admin is authorized
    client.set_proxy_address(&new_proxy);
    assert_eq!(client.get_proxy_address(), Some(new_proxy));
}

#[test]
#[should_panic(expected = "HostError: Error(Auth")]
fn test_flush_unauthorized() {
    let (env, _admin, _proxy_address, client) = setup_env();

    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    // Mint tokens to contract
    let contract_address = client.address.clone();
    token::StellarAssetClient::new(&env, &token.address).mint(&contract_address, &1000);

    // Try flush with wrong caller (not admin)
    let wrong_caller = Address::generate(&env);
    env.mock_auths(&[soroban_sdk::testutils::MockAuth {
        address: &wrong_caller,
        invoke: &soroban_sdk::testutils::MockAuthInvoke {
            contract: &client.address,
            fn_name: "flush",
            args: (&token.address, 500i128).into_val(&env),
            sub_invokes: &[],
        },
    }]);

    // This should fail - wrong_caller is not admin
    client.flush(&token.address, &500);
}

#[test]
#[should_panic(expected = "HostError: Error(Auth")]
fn test_forward_unauthorized_sender() {
    let (env, _admin, _proxy_address, client) = setup_env();

    let sender = Address::generate(&env);
    let token_admin = Address::generate(&env);
    let token = create_token_contract(&env, &token_admin);

    // Mint tokens to sender
    token::StellarAssetClient::new(&env, &token.address).mint(&sender, &1000);

    let to = String::from_str(&env, "0x1234567890abcdef");
    let memo = String::from_str(&env, "test memo");

    // Provide authorization for wrong address
    let wrong_caller = Address::generate(&env);
    env.mock_auths(&[soroban_sdk::testutils::MockAuth {
        address: &wrong_caller,
        invoke: &soroban_sdk::testutils::MockAuthInvoke {
            contract: &client.address,
            fn_name: "forward",
            args: vec![
                &env,
                sender.into_val(&env),
                token.address.into_val(&env),
                500i128.into_val(&env),
                to.into_val(&env),
                memo.into_val(&env),
            ],
            sub_invokes: &[],
        },
    }]);

    // This should fail - sender hasn't authorized (wrong_caller did)
    client.forward(&sender, &token.address, &500, &to, &memo);
}
