use crate::errors::Error;
use crate::types::{Intent, OutboundMessage};
use soroban_sdk::{symbol_short, Address, Bytes, BytesN, Env, String, Vec};

// Storage keys using symbol_short!
fn owner_key() -> soroban_sdk::Symbol {
    symbol_short!("OWNER")
}

fn gateway_key() -> soroban_sdk::Symbol {
    symbol_short!("GATEWAY")
}

fn gas_svc_key() -> soroban_sdk::Symbol {
    symbol_short!("GAS_SVC")
}

fn fee_rcpt_key() -> soroban_sdk::Symbol {
    symbol_short!("FEE_RCPT")
}

fn proto_fee_key() -> soroban_sdk::Symbol {
    symbol_short!("PROTO_FE")
}

fn outbound_key() -> soroban_sdk::Symbol {
    symbol_short!("OUT_MSG")
}

// Key builders
fn intent_key(intent_id: &BytesN<32>) -> (soroban_sdk::Symbol, BytesN<32>) {
    (symbol_short!("INTENT"), intent_id.clone())
}

fn relayer_key(relayer: &Address) -> (soroban_sdk::Symbol, Address) {
    (symbol_short!("RELAYER"), relayer.clone())
}

fn messenger_key(messenger: &Address) -> (soroban_sdk::Symbol, Address) {
    (symbol_short!("MSGER"), messenger.clone())
}

fn trusted_key(chain_name: &String) -> (soroban_sdk::Symbol, String) {
    (symbol_short!("TRUSTED"), chain_name.clone())
}

fn chain_name_key(chain_id: u64) -> (soroban_sdk::Symbol, u64) {
    (symbol_short!("CHAIN"), chain_id)
}

fn fees_key(token: &Address) -> (soroban_sdk::Symbol, Address) {
    (symbol_short!("FEES"), token.clone())
}

// Owner
pub fn has_owner(env: &Env) -> bool {
    env.storage().instance().has(&owner_key())
}

pub fn get_owner(env: &Env) -> Result<Address, Error> {
    env.storage()
        .instance()
        .get(&owner_key())
        .ok_or(Error::NotInitialized)
}

pub fn set_owner(env: &Env, owner: &Address) {
    env.storage().instance().set(&owner_key(), owner);
}

pub fn require_owner(env: &Env) -> Result<(), Error> {
    let _owner = get_owner(env)?;
    // Note: In Soroban, we use require_auth() on the owner address
    // This is called by admin functions which should pass owner as a parameter
    Ok(())
}

// Gateway
pub fn get_gateway(env: &Env) -> Result<Address, Error> {
    env.storage()
        .instance()
        .get(&gateway_key())
        .ok_or(Error::NotInitialized)
}

pub fn set_gateway(env: &Env, gateway: &Address) {
    env.storage().instance().set(&gateway_key(), gateway);
}

// Gas Service
pub fn get_gas_service(env: &Env) -> Result<Address, Error> {
    env.storage()
        .instance()
        .get(&gas_svc_key())
        .ok_or(Error::NotInitialized)
}

pub fn set_gas_service(env: &Env, gas_service: &Address) {
    env.storage().instance().set(&gas_svc_key(), gas_service);
}

// Fee Recipient
pub fn get_fee_recipient(env: &Env) -> Result<Address, Error> {
    env.storage()
        .instance()
        .get(&fee_rcpt_key())
        .ok_or(Error::NotInitialized)
}

pub fn set_fee_recipient(env: &Env, recipient: &Address) {
    env.storage().instance().set(&fee_rcpt_key(), recipient);
}

// Protocol Fee
pub fn get_protocol_fee_storage(env: &Env) -> u32 {
    env.storage().instance().get(&proto_fee_key()).unwrap_or(0)
}

pub fn set_protocol_fee_storage(env: &Env, fee_bps: u32) {
    env.storage().instance().set(&proto_fee_key(), &fee_bps);
}

// Intents
pub fn has_intent(env: &Env, intent_id: &BytesN<32>) -> bool {
    env.storage().persistent().has(&intent_key(intent_id))
}

pub fn get_intent(env: &Env, intent_id: &BytesN<32>) -> Result<Intent, Error> {
    env.storage()
        .persistent()
        .get(&intent_key(intent_id))
        .ok_or(Error::IntentNotFound)
}

pub fn set_intent(env: &Env, intent_id: &BytesN<32>, intent: &Intent) {
    env.storage()
        .persistent()
        .set(&intent_key(intent_id), intent);
}

// Relayers
pub fn is_relayer(env: &Env, relayer: &Address) -> bool {
    env.storage()
        .instance()
        .get(&relayer_key(relayer))
        .unwrap_or(false)
}

pub fn set_relayer(env: &Env, relayer: &Address, allowed: bool) {
    env.storage()
        .instance()
        .set(&relayer_key(relayer), &allowed);
}

// Messengers
pub fn is_messenger(env: &Env, messenger: &Address) -> bool {
    env.storage()
        .instance()
        .get(&messenger_key(messenger))
        .unwrap_or(false)
}

pub fn set_messenger(env: &Env, messenger: &Address, allowed: bool) {
    env.storage()
        .instance()
        .set(&messenger_key(messenger), &allowed);
}

// Trusted Contracts
pub fn get_trusted_contract(env: &Env, chain_name: &String) -> Result<String, Error> {
    env.storage()
        .instance()
        .get(&trusted_key(chain_name))
        .ok_or(Error::UntrustedSource)
}

pub fn set_trusted_contract_storage(env: &Env, chain_name: &String, contract_address: &String) {
    env.storage()
        .instance()
        .set(&trusted_key(chain_name), contract_address);
}

// Chain Names
pub fn get_chain_name(env: &Env, chain_id: u64) -> Result<String, Error> {
    env.storage()
        .instance()
        .get(&chain_name_key(chain_id))
        .ok_or(Error::ChainNotFound)
}

pub fn set_chain_name(env: &Env, chain_id: u64, chain_name: &String) {
    env.storage()
        .instance()
        .set(&chain_name_key(chain_id), chain_name);
}

// Accumulated Fees
pub fn get_accumulated_fees(env: &Env, token: &Address) -> i128 {
    env.storage()
        .persistent()
        .get(&fees_key(token))
        .unwrap_or(0)
}

pub fn set_accumulated_fees(env: &Env, token: &Address, amount: i128) {
    env.storage().persistent().set(&fees_key(token), &amount);
}

// Outbound Messages (for testing)
pub fn store_outbound_message(
    env: &Env,
    destination_chain: &String,
    destination_address: &String,
    payload: &Bytes,
) {
    let message = OutboundMessage {
        destination_chain: destination_chain.clone(),
        destination_address: destination_address.clone(),
        payload: payload.clone(),
    };

    let mut messages: Vec<OutboundMessage> = env
        .storage()
        .temporary()
        .get(&outbound_key())
        .unwrap_or(Vec::new(env));
    messages.push_back(message);
    env.storage().temporary().set(&outbound_key(), &messages);
}

pub fn get_outbound_messages(env: &Env) -> Vec<OutboundMessage> {
    env.storage()
        .temporary()
        .get(&outbound_key())
        .unwrap_or(Vec::new(env))
}
