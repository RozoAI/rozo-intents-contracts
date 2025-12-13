use crate::types::{IntentStatus, RelayerType};
use soroban_sdk::{Address, BytesN, Env, String, Symbol};

pub fn emit_intent_created(
    env: &Env,
    intent_id: BytesN<32>,
    sender: Address,
    source_token: Address,
    source_amount: i128,
    destination_chain_id: u64,
    receiver: BytesN<32>,
    destination_amount: i128,
    deadline: u64,
    relayer: BytesN<32>,
) {
    env.events().publish(
        (Symbol::new(env, "intent_created"), intent_id.clone()),
        (
            sender,
            source_token,
            source_amount,
            destination_chain_id,
            receiver,
            destination_amount,
            deadline,
            relayer,
        ),
    );
}

pub fn emit_intent_filled(env: &Env, intent_id: BytesN<32>, relayer: BytesN<32>, amount_paid: i128) {
    env.events().publish(
        (Symbol::new(env, "intent_filled"), intent_id),
        (relayer, amount_paid),
    );
}

pub fn emit_intent_failed(
    env: &Env,
    intent_id: BytesN<32>,
    expected_fill_hash: BytesN<32>,
    received_fill_hash: BytesN<32>,
) {
    env.events().publish(
        (Symbol::new(env, "intent_failed"), intent_id),
        (expected_fill_hash, received_fill_hash),
    );
}

pub fn emit_intent_refunded(env: &Env, intent_id: BytesN<32>, refund_address: Address, amount: i128) {
    env.events().publish(
        (Symbol::new(env, "intent_refunded"), intent_id),
        (refund_address, amount),
    );
}

pub fn emit_fill_and_notify_sent(
    env: &Env,
    intent_id: BytesN<32>,
    relayer: Address,
    repayment_address: BytesN<32>,
    messenger_id: u8,
) {
    env.events().publish(
        (Symbol::new(env, "fill_and_notify_sent"), intent_id),
        (relayer, repayment_address, messenger_id),
    );
}

pub fn emit_retry_notify_sent(
    env: &Env,
    intent_id: BytesN<32>,
    relayer: Address,
    messenger_id: u8,
) {
    env.events().publish(
        (Symbol::new(env, "retry_notify_sent"), intent_id),
        (relayer, messenger_id),
    );
}

pub fn emit_intent_status_changed(
    env: &Env,
    intent_id: BytesN<32>,
    old_status: IntentStatus,
    new_status: IntentStatus,
    admin: Address,
) {
    env.events().publish(
        (Symbol::new(env, "intent_status_changed"), intent_id),
        (old_status, new_status, admin),
    );
}

pub fn emit_intent_relayer_changed(
    env: &Env,
    intent_id: BytesN<32>,
    old_relayer: BytesN<32>,
    new_relayer: BytesN<32>,
    admin: Address,
) {
    env.events().publish(
        (Symbol::new(env, "intent_relayer_changed"), intent_id),
        (old_relayer, new_relayer, admin),
    );
}

pub fn emit_protocol_fee_set(env: &Env, fee_bps: u32) {
    env.events()
        .publish((Symbol::new(env, "protocol_fee_set"),), fee_bps);
}

pub fn emit_fee_recipient_set(env: &Env, recipient: Address) {
    env.events()
        .publish((Symbol::new(env, "fee_recipient_set"),), recipient);
}

pub fn emit_relayer_added(env: &Env, relayer: Address, relayer_type: RelayerType) {
    env.events()
        .publish((Symbol::new(env, "relayer_added"),), (relayer, relayer_type));
}

pub fn emit_relayer_removed(env: &Env, relayer: Address) {
    env.events()
        .publish((Symbol::new(env, "relayer_removed"),), relayer);
}

pub fn emit_messenger_adapter_set(env: &Env, messenger_id: u8, adapter: Address) {
    env.events()
        .publish((Symbol::new(env, "messenger_adapter_set"),), (messenger_id, adapter));
}

pub fn emit_rozo_relayer_set(env: &Env, relayer: Address) {
    env.events()
        .publish((Symbol::new(env, "rozo_relayer_set"),), relayer);
}

pub fn emit_rozo_threshold_set(env: &Env, threshold: u64) {
    env.events()
        .publish((Symbol::new(env, "rozo_threshold_set"),), threshold);
}

pub fn emit_trusted_contract_set(env: &Env, chain_name: String, contract_address: String) {
    env.events().publish(
        (Symbol::new(env, "trusted_contract_set"),),
        (chain_name, contract_address),
    );
}

pub fn emit_fees_withdrawn(env: &Env, token: Address, recipient: Address, amount: i128) {
    env.events()
        .publish((Symbol::new(env, "fees_withdrawn"),), (token, recipient, amount));
}
