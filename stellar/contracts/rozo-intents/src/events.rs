use crate::types::IntentStatus;
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
        ),
    );
}

pub fn emit_intent_filling(env: &Env, intent_id: BytesN<32>, relayer: Address) {
    env.events().publish(
        (Symbol::new(env, "intent_filling"), intent_id),
        relayer,
    );
}

pub fn emit_intent_filled(env: &Env, intent_id: BytesN<32>, relayer: Address, amount_paid: i128) {
    env.events().publish(
        (Symbol::new(env, "intent_filled"), intent_id),
        (relayer, amount_paid),
    );
}

pub fn emit_intent_failed(env: &Env, intent_id: BytesN<32>, reason: String) {
    env.events()
        .publish((Symbol::new(env, "intent_failed"), intent_id), reason);
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
    receiver: BytesN<32>,
    amount: i128,
) {
    env.events().publish(
        (Symbol::new(env, "fill_and_notify_sent"), intent_id),
        (relayer, receiver, amount),
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
    old_relayer: Option<Address>,
    new_relayer: Address,
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

pub fn emit_relayer_added(env: &Env, relayer: Address) {
    env.events()
        .publish((Symbol::new(env, "relayer_added"),), relayer);
}

pub fn emit_relayer_removed(env: &Env, relayer: Address) {
    env.events()
        .publish((Symbol::new(env, "relayer_removed"),), relayer);
}

pub fn emit_messenger_set(env: &Env, messenger: Address, allowed: bool) {
    env.events()
        .publish((Symbol::new(env, "messenger_set"),), (messenger, allowed));
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
