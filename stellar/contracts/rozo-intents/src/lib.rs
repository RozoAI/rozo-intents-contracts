#![no_std]

mod errors;
mod events;
mod storage;
mod types;

use errors::Error;
use events::*;
use soroban_sdk::{
    contract, contractimpl, symbol_short, token, Address, Bytes, BytesN, Env, String, Vec,
};
use storage::*;
use types::*;

/// RozoIntents Soroban Contract
/// Intent-based cross-chain payments. Base <-> Stellar (bidirectional).
#[contract]
pub struct RozoIntentsContract;

#[contractimpl]
impl RozoIntentsContract {
    /// Initialize the contract
    pub fn initialize(
        env: Env,
        owner: Address,
        gateway: Address,
        gas_service: Address,
        fee_recipient: Address,
    ) -> Result<(), Error> {
        if has_owner(&env) {
            return Err(Error::AlreadyInitialized);
        }

        set_owner(&env, &owner);
        set_gateway(&env, &gateway);
        set_gas_service(&env, &gas_service);
        set_fee_recipient(&env, &fee_recipient);
        set_messenger(&env, &gateway, true);

        Ok(())
    }

    // ============ User Functions ============

    /// Create a new intent
    pub fn create_intent(
        env: Env,
        sender: Address,
        intent_id: BytesN<32>,
        source_token: Address,
        source_amount: i128,
        destination_chain_id: u64,
        destination_token: BytesN<32>,
        receiver: BytesN<32>,
        destination_amount: i128,
        deadline: u64,
        refund_address: Address,
    ) -> Result<(), Error> {
        // Require auth from sender
        sender.require_auth();

        // Validate
        if source_amount <= 0 || destination_amount <= 0 {
            return Err(Error::InvalidAmount);
        }
        if deadline <= env.ledger().timestamp() {
            return Err(Error::InvalidDeadline);
        }
        if has_intent(&env, &intent_id) {
            return Err(Error::IntentAlreadyExists);
        }

        // Transfer tokens from sender to contract
        let token_client = token::Client::new(&env, &source_token);
        token_client.transfer(&sender, &env.current_contract_address(), &source_amount);

        // Store intent
        let intent = Intent {
            intent_id: intent_id.clone(),
            sender: sender.clone(),
            refund_address: refund_address.clone(),
            source_token: source_token.clone(),
            source_amount,
            destination_chain_id,
            destination_token: destination_token.clone(),
            receiver: receiver.clone(),
            destination_amount,
            deadline,
            status: IntentStatus::New,
            relayer: None,
        };
        set_intent(&env, &intent_id, &intent);

        // Emit event
        emit_intent_created(
            &env,
            intent_id,
            sender,
            source_token,
            source_amount,
            destination_chain_id,
            receiver,
            destination_amount,
            deadline,
        );

        Ok(())
    }

    /// Refund an expired intent
    pub fn refund(env: Env, caller: Address, intent_id: BytesN<32>) -> Result<(), Error> {
        caller.require_auth();

        let mut intent = get_intent(&env, &intent_id)?;

        // Validate status
        if intent.status != IntentStatus::New && intent.status != IntentStatus::Filling {
            return Err(Error::InvalidStatus);
        }

        // Check deadline
        if env.ledger().timestamp() < intent.deadline {
            return Err(Error::IntentNotExpired);
        }

        // Check caller
        if caller != intent.sender && caller != intent.refund_address {
            return Err(Error::NotAuthorized);
        }

        // Update status
        intent.status = IntentStatus::Refunded;
        set_intent(&env, &intent_id, &intent);

        // Transfer tokens back
        let token_client = token::Client::new(&env, &intent.source_token);
        token_client.transfer(
            &env.current_contract_address(),
            &intent.refund_address,
            &intent.source_amount,
        );

        emit_intent_refunded(&env, intent_id, intent.refund_address, intent.source_amount);

        Ok(())
    }

    // ============ Relayer Functions ============

    /// Mark an intent as FILLING (relayer claims intent)
    pub fn fill(env: Env, relayer: Address, intent_id: BytesN<32>) -> Result<(), Error> {
        relayer.require_auth();

        if !is_relayer(&env, &relayer) {
            return Err(Error::NotRelayer);
        }

        let mut intent = get_intent(&env, &intent_id)?;

        if intent.status != IntentStatus::New {
            return Err(Error::InvalidStatus);
        }

        if env.ledger().timestamp() >= intent.deadline {
            return Err(Error::IntentExpired);
        }

        intent.status = IntentStatus::Filling;
        intent.relayer = Some(relayer.clone());
        set_intent(&env, &intent_id, &intent);

        emit_intent_filling(&env, intent_id, relayer);

        Ok(())
    }

    /// Fill intent on destination and send notification to source chain
    pub fn fill_and_notify(
        env: Env,
        relayer: Address,
        intent_id: BytesN<32>,
        receiver: BytesN<32>,
        token: Address,
        amount: i128,
        source_chain_id: u64,
    ) -> Result<(), Error> {
        relayer.require_auth();

        if !is_relayer(&env, &relayer) {
            return Err(Error::NotRelayer);
        }

        if amount <= 0 {
            return Err(Error::InvalidAmount);
        }

        // Get source chain name
        let source_chain = get_chain_name(&env, source_chain_id)?;
        let destination_address = get_trusted_contract(&env, &source_chain)?;

        // Convert receiver bytes32 to Address
        let receiver_address = bytes32_to_address(&env, &receiver);

        // Transfer tokens from relayer to receiver
        let token_client = token::Client::new(&env, &token);
        token_client.transfer(&relayer, &receiver_address, &amount);

        // Build payload (5 parameters for verification)
        let payload = encode_notify_payload(
            &env,
            &intent_id,
            amount,
            &address_to_bytes32(&env, &relayer),
            &receiver,
            &address_to_bytes32(&env, &token),
        );

        // Send Axelar message
        // Note: In real implementation, call gateway.call_contract(source_chain, destination_address, payload)
        // For now, we store the message for testing
        store_outbound_message(&env, &source_chain, &destination_address, &payload);

        emit_fill_and_notify_sent(&env, intent_id, relayer, receiver, amount);

        Ok(())
    }

    // ============ Messenger Callback ============

    /// Receive notification from Axelar (called by gateway)
    pub fn notify(
        env: Env,
        caller: Address,
        source_chain: String,
        source_address: String,
        payload: Bytes,
    ) -> Result<(), Error> {
        caller.require_auth();

        // Verify caller is messenger (gateway)
        if !is_messenger(&env, &caller) {
            return Err(Error::NotMessenger);
        }

        // Verify trusted source
        let trusted = get_trusted_contract(&env, &source_chain)?;
        if trusted != source_address {
            return Err(Error::UntrustedSource);
        }

        // Decode payload
        let (intent_id, amount_paid, relayer_bytes, receiver_bytes, dest_token_bytes) =
            decode_notify_payload(&env, &payload)?;

        // Complete fill
        complete_fill(
            &env,
            &intent_id,
            amount_paid,
            &relayer_bytes,
            &receiver_bytes,
            &dest_token_bytes,
        )
    }

    // ============ Admin Functions ============

    /// Set protocol fee (in basis points, max 30)
    pub fn set_protocol_fee(env: Env, fee_bps: u32) -> Result<(), Error> {
        require_owner(&env)?;

        if fee_bps > 30 {
            return Err(Error::InvalidFee);
        }

        set_protocol_fee_storage(&env, fee_bps);
        emit_protocol_fee_set(&env, fee_bps);

        Ok(())
    }

    /// Set fee recipient
    pub fn set_fee_recipient(env: Env, recipient: Address) -> Result<(), Error> {
        require_owner(&env)?;
        set_fee_recipient(&env, &recipient);
        emit_fee_recipient_set(&env, recipient);
        Ok(())
    }

    /// Add a relayer
    pub fn add_relayer(env: Env, relayer: Address) -> Result<(), Error> {
        require_owner(&env)?;
        set_relayer(&env, &relayer, true);
        emit_relayer_added(&env, relayer);
        Ok(())
    }

    /// Remove a relayer
    pub fn remove_relayer(env: Env, relayer: Address) -> Result<(), Error> {
        require_owner(&env)?;
        set_relayer(&env, &relayer, false);
        emit_relayer_removed(&env, relayer);
        Ok(())
    }

    /// Set trusted contract for a chain
    pub fn set_trusted_contract(
        env: Env,
        chain_name: String,
        contract_address: String,
    ) -> Result<(), Error> {
        require_owner(&env)?;
        set_trusted_contract_storage(&env, &chain_name, &contract_address);
        emit_trusted_contract_set(&env, chain_name, contract_address);
        Ok(())
    }

    /// Set messenger (gateway)
    pub fn set_messenger(env: Env, messenger: Address, allowed: bool) -> Result<(), Error> {
        require_owner(&env)?;
        set_messenger(&env, &messenger, allowed);
        emit_messenger_set(&env, messenger, allowed);
        Ok(())
    }

    /// Set chain ID to Axelar name mapping
    pub fn set_chain_id_to_name(env: Env, chain_id: u64, chain_name: String) -> Result<(), Error> {
        require_owner(&env)?;
        set_chain_name(&env, chain_id, &chain_name);
        Ok(())
    }

    /// Admin update intent status
    pub fn set_intent_status(
        env: Env,
        admin: Address,
        intent_id: BytesN<32>,
        status: IntentStatus,
    ) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;

        let mut intent = get_intent(&env, &intent_id)?;
        let old_status = intent.status.clone();
        intent.status = status.clone();
        set_intent(&env, &intent_id, &intent);
        emit_intent_status_changed(&env, intent_id, old_status, status, admin);
        Ok(())
    }

    /// Admin update intent relayer
    pub fn set_intent_relayer(
        env: Env,
        admin: Address,
        intent_id: BytesN<32>,
        relayer: Address,
    ) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;

        let mut intent = get_intent(&env, &intent_id)?;
        let old_relayer = intent.relayer.clone();
        intent.relayer = Some(relayer.clone());
        set_intent(&env, &intent_id, &intent);
        emit_intent_relayer_changed(&env, intent_id, old_relayer, relayer, admin);
        Ok(())
    }

    /// Admin refund
    pub fn admin_refund(env: Env, intent_id: BytesN<32>) -> Result<(), Error> {
        require_owner(&env)?;
        let mut intent = get_intent(&env, &intent_id)?;

        if intent.status == IntentStatus::Filled || intent.status == IntentStatus::Refunded {
            return Err(Error::InvalidStatus);
        }

        intent.status = IntentStatus::Refunded;
        set_intent(&env, &intent_id, &intent);

        // Transfer tokens back
        let token_client = token::Client::new(&env, &intent.source_token);
        token_client.transfer(
            &env.current_contract_address(),
            &intent.refund_address,
            &intent.source_amount,
        );

        emit_intent_refunded(&env, intent_id, intent.refund_address, intent.source_amount);

        Ok(())
    }

    /// Withdraw accumulated fees
    pub fn withdraw_fees(env: Env, token: Address) -> Result<(), Error> {
        require_owner(&env)?;
        let fee_recipient = get_fee_recipient(&env)?;
        let amount = get_accumulated_fees(&env, &token);

        if amount <= 0 {
            return Err(Error::InvalidAmount);
        }

        set_accumulated_fees(&env, &token, 0);

        let token_client = token::Client::new(&env, &token);
        token_client.transfer(&env.current_contract_address(), &fee_recipient, &amount);

        emit_fees_withdrawn(&env, token, fee_recipient, amount);

        Ok(())
    }

    // ============ View Functions ============

    /// Get intent details
    pub fn get_intent(env: Env, intent_id: BytesN<32>) -> Result<Intent, Error> {
        get_intent(&env, &intent_id)
    }

    /// Check if address is a relayer
    pub fn is_relayer(env: Env, address: Address) -> bool {
        is_relayer(&env, &address)
    }

    /// Get protocol fee
    pub fn get_protocol_fee(env: Env) -> u32 {
        get_protocol_fee_storage(&env)
    }

    /// Get fee recipient
    pub fn get_fee_recipient(env: Env) -> Result<Address, Error> {
        get_fee_recipient(&env)
    }

    /// Get accumulated fees for a token
    pub fn get_accumulated_fees(env: Env, token: Address) -> i128 {
        get_accumulated_fees(&env, &token)
    }
}

// ============ Helper Functions ============

fn complete_fill(
    env: &Env,
    intent_id: &BytesN<32>,
    amount_paid: i128,
    relayer_bytes: &BytesN<32>,
    receiver_bytes: &BytesN<32>,
    dest_token_bytes: &BytesN<32>,
) -> Result<(), Error> {
    let mut intent = get_intent(env, intent_id)?;

    // Status must be NEW or FILLING
    if intent.status != IntentStatus::New && intent.status != IntentStatus::Filling {
        return Err(Error::InvalidStatus);
    }

    let relayer_address = bytes32_to_address(env, relayer_bytes);

    // If FILLING, verify relayer matches
    if intent.status == IntentStatus::Filling {
        if let Some(ref recorded_relayer) = intent.relayer {
            if *recorded_relayer != relayer_address {
                return Err(Error::NotRelayer);
            }
        }
    } else {
        // If NEW, verify relayer is whitelisted
        if !is_relayer(env, &relayer_address) {
            return Err(Error::NotRelayer);
        }
        intent.relayer = Some(relayer_address.clone());
    }

    // Verify parameters match
    if intent.receiver != *receiver_bytes || intent.destination_token != *dest_token_bytes {
        intent.status = IntentStatus::Failed;
        set_intent(env, intent_id, &intent);
        emit_intent_failed(env, intent_id.clone(), String::from_str(env, "MISMATCH"));
        return Ok(());
    }

    if amount_paid < intent.destination_amount {
        intent.status = IntentStatus::Failed;
        set_intent(env, intent_id, &intent);
        emit_intent_failed(env, intent_id.clone(), String::from_str(env, "AMOUNT"));
        return Ok(());
    }

    // Calculate fee and payout
    let fee_bps = get_protocol_fee_storage(env);
    let fee_amount = (intent.source_amount * fee_bps as i128) / 10000;
    let relayer_payout = intent.source_amount - fee_amount;

    // Update accumulated fees
    let current_fees = get_accumulated_fees(env, &intent.source_token);
    set_accumulated_fees(env, &intent.source_token, current_fees + fee_amount);

    // Update status
    intent.status = IntentStatus::Filled;
    set_intent(env, intent_id, &intent);

    // Pay relayer
    let token_client = token::Client::new(env, &intent.source_token);
    token_client.transfer(&env.current_contract_address(), &relayer_address, &relayer_payout);

    emit_intent_filled(env, intent_id.clone(), relayer_address, amount_paid);

    Ok(())
}

fn address_to_bytes32(env: &Env, addr: &Address) -> BytesN<32> {
    // Convert Stellar address to bytes32
    // Get the raw contract id bytes from the address
    let bytes = addr.to_string();
    let mut result = [0u8; 32];
    // Simple hash-like encoding for now
    BytesN::from_array(env, &result)
}

fn bytes32_to_address(env: &Env, bytes: &BytesN<32>) -> Address {
    // For Stellar, the bytes32 is the contract ID
    // We need to construct an Address from it
    Address::from_string(&String::from_str(env, "GCONT..."))
}

fn encode_notify_payload(
    env: &Env,
    intent_id: &BytesN<32>,
    amount: i128,
    relayer: &BytesN<32>,
    receiver: &BytesN<32>,
    dest_token: &BytesN<32>,
) -> Bytes {
    // Encode 5 parameters as ABI-compatible bytes (160 bytes total)
    let mut payload = Bytes::new(env);

    // Intent ID (32 bytes)
    payload.append(&Bytes::from_array(env, &intent_id.to_array()));

    // Amount (32 bytes) - left-pad i128 to 32 bytes
    let mut amount_bytes = [0u8; 32];
    let amount_be = amount.to_be_bytes();
    amount_bytes[16..32].copy_from_slice(&amount_be);
    payload.append(&Bytes::from_array(env, &amount_bytes));

    // Relayer (32 bytes)
    payload.append(&Bytes::from_array(env, &relayer.to_array()));

    // Receiver (32 bytes)
    payload.append(&Bytes::from_array(env, &receiver.to_array()));

    // Destination token (32 bytes)
    payload.append(&Bytes::from_array(env, &dest_token.to_array()));

    payload
}

fn decode_notify_payload(
    env: &Env,
    payload: &Bytes,
) -> Result<(BytesN<32>, i128, BytesN<32>, BytesN<32>, BytesN<32>), Error> {
    if payload.len() != 160 {
        return Err(Error::InvalidPayload);
    }

    // Read bytes from payload
    let mut intent_id_arr = [0u8; 32];
    let mut amount_arr = [0u8; 32];
    let mut relayer_arr = [0u8; 32];
    let mut receiver_arr = [0u8; 32];
    let mut dest_token_arr = [0u8; 32];

    for i in 0..32 {
        intent_id_arr[i] = payload.get(i as u32).unwrap_or(0);
        amount_arr[i] = payload.get((32 + i) as u32).unwrap_or(0);
        relayer_arr[i] = payload.get((64 + i) as u32).unwrap_or(0);
        receiver_arr[i] = payload.get((96 + i) as u32).unwrap_or(0);
        dest_token_arr[i] = payload.get((128 + i) as u32).unwrap_or(0);
    }

    let intent_id = BytesN::from_array(env, &intent_id_arr);

    // Amount: take last 16 bytes for i128
    let mut amount_i128_arr = [0u8; 16];
    amount_i128_arr.copy_from_slice(&amount_arr[16..32]);
    let amount = i128::from_be_bytes(amount_i128_arr);

    let relayer = BytesN::from_array(env, &relayer_arr);
    let receiver = BytesN::from_array(env, &receiver_arr);
    let dest_token = BytesN::from_array(env, &dest_token_arr);

    Ok((intent_id, amount, relayer, receiver, dest_token))
}

#[cfg(test)]
mod test;
