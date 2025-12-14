use crate::errors::Error;
use crate::types::{FillRecord, Intent, OutboundMessage, RelayerType};
use soroban_sdk::{symbol_short, Address, Bytes, BytesN, Env, String, Vec};

// Storage keys using symbol_short!
fn owner_key() -> soroban_sdk::Symbol {
    symbol_short!("OWNER")
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

fn rozo_relayer_key() -> soroban_sdk::Symbol {
    symbol_short!("ROZO_REL")
}

fn rozo_threshold_key() -> soroban_sdk::Symbol {
    symbol_short!("ROZO_TH")
}

fn chain_id_key() -> soroban_sdk::Symbol {
    symbol_short!("CHAIN_ID")
}

// Key builders
fn intent_key(intent_id: &BytesN<32>) -> (soroban_sdk::Symbol, BytesN<32>) {
    (symbol_short!("INTENT"), intent_id.clone())
}

fn relayer_key(relayer: &Address) -> (soroban_sdk::Symbol, Address) {
    (symbol_short!("RELAYER"), relayer.clone())
}

fn messenger_adapter_key(messenger_id: u32) -> (soroban_sdk::Symbol, u32) {
    (symbol_short!("MSG_ADP"), messenger_id)
}

fn fill_record_key(fill_hash: &BytesN<32>) -> (soroban_sdk::Symbol, BytesN<32>) {
    (symbol_short!("FILL"), fill_hash.clone())
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
    Ok(())
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

// Rozo Relayer
pub fn get_rozo_relayer(env: &Env) -> Option<Address> {
    env.storage().instance().get(&rozo_relayer_key())
}

pub fn set_rozo_relayer(env: &Env, relayer: &Address) {
    env.storage().instance().set(&rozo_relayer_key(), relayer);
}

// Rozo Relayer Threshold (seconds)
pub fn get_rozo_relayer_threshold(env: &Env) -> u64 {
    env.storage()
        .instance()
        .get(&rozo_threshold_key())
        .unwrap_or(0)
}

pub fn set_rozo_relayer_threshold(env: &Env, threshold: u64) {
    env.storage()
        .instance()
        .set(&rozo_threshold_key(), &threshold);
}

// Chain ID (current chain's ID)
pub fn get_chain_id(env: &Env) -> u64 {
    env.storage().instance().get(&chain_id_key()).unwrap_or(0)
}

pub fn set_chain_id(env: &Env, chain_id: u64) {
    env.storage().instance().set(&chain_id_key(), &chain_id);
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

// Relayers (now returns RelayerType)
pub fn get_relayer_type(env: &Env, relayer: &Address) -> RelayerType {
    env.storage()
        .instance()
        .get(&relayer_key(relayer))
        .unwrap_or(RelayerType::None)
}

pub fn set_relayer_type(env: &Env, relayer: &Address, relayer_type: RelayerType) {
    env.storage()
        .instance()
        .set(&relayer_key(relayer), &relayer_type);
}

pub fn is_relayer(env: &Env, relayer: &Address) -> bool {
    get_relayer_type(env, relayer) != RelayerType::None
}

// Messenger Adapters (by messengerId)
pub fn get_messenger_adapter(env: &Env, messenger_id: u32) -> Option<Address> {
    env.storage()
        .instance()
        .get(&messenger_adapter_key(messenger_id))
}

pub fn set_messenger_adapter(env: &Env, messenger_id: u32, adapter: &Address) {
    env.storage()
        .instance()
        .set(&messenger_adapter_key(messenger_id), adapter);
}

// Fill Records (destination chain - for double-fill prevention)
pub fn has_fill_record(env: &Env, fill_hash: &BytesN<32>) -> bool {
    env.storage().persistent().has(&fill_record_key(fill_hash))
}

pub fn get_fill_record(env: &Env, fill_hash: &BytesN<32>) -> Option<FillRecord> {
    env.storage().persistent().get(&fill_record_key(fill_hash))
}

pub fn set_fill_record(env: &Env, fill_hash: &BytesN<32>, record: &FillRecord) {
    env.storage()
        .persistent()
        .set(&fill_record_key(fill_hash), record);
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

// Chain Names (chain_id -> chain_name mapping)
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

#[allow(dead_code)]
pub fn get_outbound_messages(env: &Env) -> Vec<OutboundMessage> {
    env.storage()
        .temporary()
        .get(&outbound_key())
        .unwrap_or(Vec::new(env))
}
