#![no_std]

mod errors;
mod events;
mod storage;
mod types;

use errors::Error;
use events::*;
use soroban_sdk::{contract, contractimpl, token, Address, Bytes, BytesN, Env, IntoVal, String};
use storage::*;
use types::*;

// Zero bytes32 constant for comparisons
const ZERO_BYTES32: [u8; 32] = [0u8; 32];

/// RozoIntents Soroban Contract
/// Intent-based cross-chain payments. Base <-> Stellar (bidirectional).
/// Supports multiple messengers (Rozo, Axelar) via adapter pattern.
#[contract]
pub struct RozoIntentsContract;

#[contractimpl]
impl RozoIntentsContract {
    /// Initialize the contract
    pub fn initialize(
        env: Env,
        owner: Address,
        fee_recipient: Address,
        chain_id: u64,
    ) -> Result<(), Error> {
        if has_owner(&env) {
            return Err(Error::AlreadyInitialized);
        }

        set_owner(&env, &owner);
        set_fee_recipient(&env, &fee_recipient);
        set_chain_id(&env, chain_id);

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
        relayer: BytesN<32>,
    ) -> Result<(), Error> {
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
            created_at: env.ledger().timestamp(),
            status: IntentStatus::Pending,
            relayer: relayer.clone(),
        };
        set_intent(&env, &intent_id, &intent);

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
            relayer,
        );

        Ok(())
    }

    /// Refund an expired intent
    pub fn refund(env: Env, caller: Address, intent_id: BytesN<32>) -> Result<(), Error> {
        caller.require_auth();

        let mut intent = get_intent(&env, &intent_id)?;

        // Validate status - only PENDING can be refunded
        if intent.status != IntentStatus::Pending {
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

    // ============ Destination Functions ============

    /// Fill intent on destination and send notification to source chain
    pub fn fill_and_notify(
        env: Env,
        relayer: Address,
        intent_data: IntentData,
        repayment_address: BytesN<32>,
        messenger_id: u8,
    ) -> Result<(), Error> {
        relayer.require_auth();

        // Verify caller is authorized relayer
        let relayer_type = get_relayer_type(&env, &relayer);
        if relayer_type == RelayerType::None {
            return Err(Error::NotRelayer);
        }

        // Verify this is the correct destination chain
        let current_chain_id = get_chain_id(&env);
        if intent_data.destination_chain_id != current_chain_id {
            return Err(Error::WrongChain);
        }

        // Verify deadline not passed
        if env.ledger().timestamp() >= intent_data.deadline {
            return Err(Error::IntentExpired);
        }

        // Verify relayer authorization
        let relayer_bytes32 = address_to_bytes32(&env, &relayer);
        let zero_bytes32 = BytesN::from_array(&env, &ZERO_BYTES32);

        if intent_data.relayer != zero_bytes32 {
            // Intent has assigned relayer
            let is_assigned = intent_data.relayer == relayer_bytes32;
            let is_rozo_fallback = is_rozo_fallback(&env, &relayer, intent_data.created_at);

            if !is_assigned && !is_rozo_fallback {
                return Err(Error::NotAssignedRelayer);
            }
        }
        // If intent_data.relayer == bytes32(0), any whitelisted relayer can fill

        // Compute fillHash for double-fill prevention
        let fill_hash = compute_fill_hash(&env, &intent_data);

        // Check not already filled
        if has_fill_record(&env, &fill_hash) {
            return Err(Error::AlreadyFilled);
        }

        // Store fill record
        let record = FillRecord {
            relayer: relayer.clone(),
            repayment_address: repayment_address.clone(),
        };
        set_fill_record(&env, &fill_hash, &record);

        // Transfer tokens to receiver
        let receiver_address = bytes32_to_address(&env, &intent_data.receiver);
        let token_address = bytes32_to_address(&env, &intent_data.destination_token);

        let token_client = token::Client::new(&env, &token_address);
        token_client.transfer(&relayer, &receiver_address, &intent_data.destination_amount);

        // Get messenger adapter and send notification
        let adapter = get_messenger_adapter(&env, messenger_id);
        if adapter.is_none() {
            return Err(Error::InvalidMessenger);
        }
        let adapter_address = adapter.unwrap();

        // Build payload for cross-chain notification
        // Format: intentId, fillHash, repaymentAddress, relayer (who performed fill), amount
        let relayer_bytes32 = address_to_bytes32(&env, &relayer);
        let payload = encode_notify_payload(
            &env,
            &intent_data.intent_id,
            &fill_hash,
            &repayment_address,
            &relayer_bytes32,
            intent_data.destination_amount,
        );

        // Get source chain info for cross-chain messaging
        let source_chain = get_chain_name(&env, intent_data.source_chain_id)?;
        let destination_address = get_trusted_contract(&env, &source_chain)?;

        // Store outbound message (for testing/debugging)
        store_outbound_message(&env, &source_chain, &destination_address, &payload);

        // CRITICAL: Actually call the messenger adapter to send the cross-chain message
        // The adapter contract handles the actual message delivery to the source chain
        send_via_adapter(&env, &adapter_address, intent_data.source_chain_id, &payload);

        emit_fill_and_notify_sent(&env, intent_data.intent_id, relayer, repayment_address, messenger_id);

        Ok(())
    }

    /// Retry notification with different messenger (if original messenger failed)
    pub fn retry_notify(
        env: Env,
        relayer: Address,
        intent_data: IntentData,
        messenger_id: u8,
    ) -> Result<(), Error> {
        relayer.require_auth();

        // Compute fillHash
        let fill_hash = compute_fill_hash(&env, &intent_data);

        // Must have been filled previously
        let record = get_fill_record(&env, &fill_hash);
        if record.is_none() {
            return Err(Error::IntentNotFound);
        }
        let record = record.unwrap();

        // Only original filler can retry
        if record.relayer != relayer {
            return Err(Error::NotAssignedRelayer);
        }

        // Get messenger adapter
        let adapter = get_messenger_adapter(&env, messenger_id);
        if adapter.is_none() {
            return Err(Error::InvalidMessenger);
        }
        let adapter_address = adapter.unwrap();

        // Build payload with relayer identity
        let relayer_bytes32 = address_to_bytes32(&env, &relayer);
        let payload = encode_notify_payload(
            &env,
            &intent_data.intent_id,
            &fill_hash,
            &record.repayment_address,
            &relayer_bytes32,
            intent_data.destination_amount,
        );

        let source_chain = get_chain_name(&env, intent_data.source_chain_id)?;
        let destination_address = get_trusted_contract(&env, &source_chain)?;

        // Store outbound message (for testing/debugging)
        store_outbound_message(&env, &source_chain, &destination_address, &payload);

        // CRITICAL: Actually call the messenger adapter to send the cross-chain message
        send_via_adapter(&env, &adapter_address, intent_data.source_chain_id, &payload);

        emit_retry_notify_sent(&env, intent_data.intent_id, relayer, messenger_id);

        Ok(())
    }

    // ============ Messenger Callback ============

    /// Receive notification from messenger adapter
    /// @dev Only registered messenger adapters can call this function
    /// @param caller The address of the calling contract (must be registered adapter)
    ///               The adapter MUST call `env.authorize_as_current_contract()` before calling
    pub fn notify(
        env: Env,
        caller: Address,
        messenger_id: u8,
        source_chain_id: u64,
        message_data: Bytes,
    ) -> Result<(), Error> {
        // Verify messenger adapter is registered
        let adapter = get_messenger_adapter(&env, messenger_id);
        if adapter.is_none() {
            return Err(Error::InvalidMessenger);
        }
        let adapter_address = adapter.unwrap();

        // SECURITY: Verify the caller is the registered adapter contract
        // 1. Check the passed address matches the registered adapter
        if caller != adapter_address {
            return Err(Error::NotMessenger);
        }

        // 2. Require authorization from the adapter
        // The adapter MUST call env.authorize_as_current_contract() before calling notify
        // This ensures only the actual adapter contract can successfully call this function
        caller.require_auth();

        // Decode payload (adapter has already verified the message before calling)
        let (fill_hash, intent_id, repayment_address, relayer, amount_paid) =
            decode_notify_payload(&env, &message_data)?;

        // Complete fill
        complete_fill(&env, &intent_id, &fill_hash, &repayment_address, relayer, amount_paid)
    }

    // ============ Admin Functions ============

    /// Set protocol fee (in basis points, max 30)
    pub fn set_protocol_fee(env: Env, admin: Address, fee_bps: u32) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;

        if fee_bps > 30 {
            return Err(Error::InvalidFee);
        }

        set_protocol_fee_storage(&env, fee_bps);
        emit_protocol_fee_set(&env, fee_bps);

        Ok(())
    }

    /// Set fee recipient
    pub fn set_fee_rcpt(env: Env, admin: Address, recipient: Address) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;
        set_fee_recipient(&env, &recipient);
        emit_fee_recipient_set(&env, recipient);
        Ok(())
    }

    /// Add a relayer with type
    pub fn add_relayer(env: Env, admin: Address, relayer: Address, relayer_type: RelayerType) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;

        if relayer_type == RelayerType::None {
            return Err(Error::InvalidPayload);
        }

        set_relayer_type(&env, &relayer, relayer_type.clone());
        emit_relayer_added(&env, relayer, relayer_type);
        Ok(())
    }

    /// Remove a relayer
    pub fn remove_relayer(env: Env, admin: Address, relayer: Address) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;
        set_relayer_type(&env, &relayer, RelayerType::None);
        emit_relayer_removed(&env, relayer);
        Ok(())
    }

    /// Set messenger adapter
    pub fn set_msger_adapter(env: Env, admin: Address, messenger_id: u8, adapter: Address) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;
        set_messenger_adapter(&env, messenger_id, &adapter);
        emit_messenger_adapter_set(&env, messenger_id, adapter);
        Ok(())
    }

    /// Set trusted contract for a chain
    pub fn set_trusted_contract(
        env: Env,
        admin: Address,
        chain_name: String,
        contract_address: String,
    ) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;
        set_trusted_contract_storage(&env, &chain_name, &contract_address);
        emit_trusted_contract_set(&env, chain_name, contract_address);
        Ok(())
    }

    /// Set chain ID to name mapping
    pub fn set_chain_id_to_name(env: Env, admin: Address, chain_id: u64, chain_name: String) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;
        set_chain_name(&env, chain_id, &chain_name);
        Ok(())
    }

    /// Set Rozo relayer for fallback fills
    pub fn set_rozo_relayer(env: Env, admin: Address, relayer: Address) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;
        set_rozo_relayer(&env, &relayer);
        emit_rozo_relayer_set(&env, relayer);
        Ok(())
    }

    /// Set Rozo relayer threshold (seconds)
    pub fn set_rozo_threshold(env: Env, admin: Address, threshold: u64) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;
        set_rozo_relayer_threshold(&env, threshold);
        emit_rozo_threshold_set(&env, threshold);
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
        relayer: BytesN<32>,
    ) -> Result<(), Error> {
        admin.require_auth();
        require_owner(&env)?;

        let mut intent = get_intent(&env, &intent_id)?;
        let old_relayer = intent.relayer.clone();
        intent.relayer = relayer.clone();
        set_intent(&env, &intent_id, &intent);
        emit_intent_relayer_changed(&env, intent_id, old_relayer, relayer, admin);
        Ok(())
    }

    /// Admin refund
    pub fn admin_refund(env: Env, admin: Address, intent_id: BytesN<32>) -> Result<(), Error> {
        admin.require_auth();
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
    pub fn withdraw_fees(env: Env, admin: Address, token: Address) -> Result<(), Error> {
        admin.require_auth();
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

    /// Get relayer type
    pub fn get_relayer_type(env: Env, address: Address) -> RelayerType {
        get_relayer_type(&env, &address)
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
    pub fn get_fee_rcpt(env: Env) -> Result<Address, Error> {
        get_fee_recipient(&env)
    }

    /// Get accumulated fees for a token
    pub fn get_accum_fees(env: Env, token: Address) -> i128 {
        get_accumulated_fees(&env, &token)
    }

    /// Get Rozo relayer
    pub fn get_rozo_relayer(env: Env) -> Option<Address> {
        get_rozo_relayer(&env)
    }

    /// Get Rozo relayer threshold
    pub fn get_rozo_threshold(env: Env) -> u64 {
        get_rozo_relayer_threshold(&env)
    }

    /// Get messenger adapter
    pub fn get_msger_adapter(env: Env, messenger_id: u8) -> Option<Address> {
        get_messenger_adapter(&env, messenger_id)
    }

    /// Get fill record
    pub fn get_fill_record(env: Env, fill_hash: BytesN<32>) -> Option<FillRecord> {
        get_fill_record(&env, &fill_hash)
    }
}

// ============ Helper Functions ============

/// Send a cross-chain message via the messenger adapter
/// This calls the adapter contract's send_message function to actually deliver the message
fn send_via_adapter(env: &Env, adapter: &Address, destination_chain_id: u64, payload: &Bytes) {
    // Create a client to call the messenger adapter contract
    // The adapter implements IMessengerAdapter with send_message(destination_chain_id, payload)
    // We use a cross-contract call to invoke the adapter
    let args: soroban_sdk::Vec<soroban_sdk::Val> = soroban_sdk::vec![
        env,
        destination_chain_id.into_val(env),
        payload.into_val(env)
    ];

    // Invoke the adapter's send_message function
    // This will handle the actual cross-chain messaging (via Axelar, Rozo relayer network, etc.)
    env.invoke_contract::<()>(adapter, &soroban_sdk::symbol_short!("send_msg"), args);
}

fn complete_fill(
    env: &Env,
    intent_id: &BytesN<32>,
    fill_hash: &BytesN<32>,
    repayment_address: &BytesN<32>,
    relayer: BytesN<32>,
    amount_paid: i128,
) -> Result<(), Error> {
    let mut intent = get_intent(env, intent_id)?;

    // Status must be PENDING
    if intent.status != IntentStatus::Pending {
        return Err(Error::InvalidStatus);
    }

    // Compute expected fillHash from stored intent
    let expected_data = IntentData {
        intent_id: intent.intent_id.clone(),
        sender: address_to_bytes32(env, &intent.sender),
        refund_address: address_to_bytes32(env, &intent.refund_address),
        source_token: address_to_bytes32(env, &intent.source_token),
        source_amount: intent.source_amount,
        source_chain_id: get_chain_id(env),
        destination_chain_id: intent.destination_chain_id,
        destination_token: intent.destination_token.clone(),
        receiver: intent.receiver.clone(),
        destination_amount: intent.destination_amount,
        deadline: intent.deadline,
        created_at: intent.created_at,
        relayer: intent.relayer.clone(),
    };
    let expected_fill_hash = compute_fill_hash(env, &expected_data);

    // Verify fillHash matches
    if *fill_hash != expected_fill_hash {
        intent.status = IntentStatus::Failed;
        set_intent(env, intent_id, &intent);
        emit_intent_failed(env, intent_id.clone(), expected_fill_hash, fill_hash.clone());
        return Ok(());
    }

    // Verify amount paid meets minimum
    if amount_paid < intent.destination_amount {
        intent.status = IntentStatus::Failed;
        set_intent(env, intent_id, &intent);
        emit_intent_failed(env, intent_id.clone(), expected_fill_hash, fill_hash.clone());
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

    // Pay relayer using repaymentAddress
    let payout_address = bytes32_to_address(env, repayment_address);
    let token_client = token::Client::new(env, &intent.source_token);
    token_client.transfer(&env.current_contract_address(), &payout_address, &relayer_payout);

    emit_intent_filled(env, intent_id.clone(), relayer, repayment_address.clone(), amount_paid);

    Ok(())
}

fn is_rozo_fallback(env: &Env, caller: &Address, created_at: u64) -> bool {
    let rozo_relayer = get_rozo_relayer(env);
    if rozo_relayer.is_none() {
        return false;
    }

    if *caller != rozo_relayer.unwrap() {
        return false;
    }

    let threshold = get_rozo_relayer_threshold(env);
    if threshold == 0 {
        return false;
    }

    env.ledger().timestamp() >= created_at + threshold
}

fn compute_fill_hash(env: &Env, intent_data: &IntentData) -> BytesN<32> {
    // Simple hash computation - in production use proper hashing
    use soroban_sdk::crypto::Hash;
    let mut hasher = env.crypto().sha256_hash_new();

    hasher.hash_extend(&intent_data.intent_id.to_array());
    hasher.hash_extend(&intent_data.sender.to_array());
    hasher.hash_extend(&intent_data.refund_address.to_array());
    hasher.hash_extend(&intent_data.source_token.to_array());
    hasher.hash_extend(&intent_data.source_amount.to_be_bytes());
    hasher.hash_extend(&intent_data.source_chain_id.to_be_bytes());
    hasher.hash_extend(&intent_data.destination_chain_id.to_be_bytes());
    hasher.hash_extend(&intent_data.destination_token.to_array());
    hasher.hash_extend(&intent_data.receiver.to_array());
    hasher.hash_extend(&intent_data.destination_amount.to_be_bytes());
    hasher.hash_extend(&intent_data.deadline.to_be_bytes());
    hasher.hash_extend(&intent_data.created_at.to_be_bytes());
    hasher.hash_extend(&intent_data.relayer.to_array());

    hasher.hash_finalize()
}

/// Convert Stellar Address to bytes32 for cross-chain compatibility
///
/// This function extracts the raw 32-byte identifier from a Stellar address:
/// - For Account addresses (G...): extracts the 32-byte Ed25519 public key
/// - For Contract addresses (C...): extracts the 32-byte contract ID
///
/// IMPORTANT: This encoding does NOT preserve the address type (account vs contract).
/// The caller must track the address type separately if round-trip conversion is needed.
/// For cross-chain use, this is typically handled by context (e.g., receiver addresses
/// are known to be of a specific type based on the destination chain).
///
/// XDR format for ScAddress:
/// - Account: 4 bytes (discriminant=0) + 4 bytes (PublicKeyType::Ed25519=0) + 32 bytes (Ed25519 key) = 40 bytes
/// - Contract: 4 bytes (discriminant=1) + 32 bytes (contract ID) = 36 bytes
fn address_to_bytes32(env: &Env, addr: &Address) -> BytesN<32> {
    let addr_bytes = addr.to_xdr(env);
    let mut result = [0u8; 32];
    let len = addr_bytes.len();

    // Check discriminant to determine address type
    // First 4 bytes are the SCAddress discriminant (big-endian u32)
    let discriminant = if len >= 4 {
        addr_bytes.get(3).unwrap_or(0)
    } else {
        0
    };

    if discriminant == 0 {
        // Account address (G...)
        // XDR: 4 bytes discriminant + 4 bytes PublicKeyType + 32 bytes Ed25519 key
        if len >= 40 {
            // Copy all 32 bytes of the Ed25519 key (starting at offset 8)
            for i in 0..32 {
                result[i] = addr_bytes.get((8 + i) as u32).unwrap_or(0);
            }
        }
    } else {
        // Contract address (C...)
        // XDR: 4 bytes discriminant + 32 bytes contract ID
        if len >= 36 {
            // Copy all 32 bytes of the contract ID (starting at offset 4)
            for i in 0..32 {
                result[i] = addr_bytes.get((4 + i) as u32).unwrap_or(0);
            }
        }
    }

    BytesN::from_array(env, &result)
}

/// Convert bytes32 to Stellar Address
///
/// This function converts a raw 32-byte identifier to a Stellar address.
/// Since bytes32 doesn't contain type information, this function uses the
/// `is_account` parameter to determine the address type.
///
/// @param bytes The 32-byte identifier (Ed25519 key or contract ID)
/// @param is_account If true, creates an Account address (G...); if false, creates a Contract address (C...)
///
/// XDR format for ScAddress:
/// - Account: 4 bytes (discriminant=0) + 4 bytes (PublicKeyType::Ed25519=0) + 32 bytes (Ed25519 key) = 40 bytes
/// - Contract: 4 bytes (discriminant=1) + 32 bytes (contract ID) = 36 bytes
fn bytes32_to_address_typed(env: &Env, bytes: &BytesN<32>, is_account: bool) -> Address {
    let bytes_arr = bytes.to_array();

    if is_account {
        // Reconstruct account address
        let mut account_xdr = [0u8; 40];
        account_xdr[0] = 0;
        account_xdr[1] = 0;
        account_xdr[2] = 0;
        account_xdr[3] = 0; // ScAddress::Account variant
        account_xdr[4] = 0;
        account_xdr[5] = 0;
        account_xdr[6] = 0;
        account_xdr[7] = 0; // PublicKeyType::Ed25519 variant
        for i in 0..32 {
            account_xdr[8 + i] = bytes_arr[i];
        }

        let xdr = Bytes::from_array(env, &account_xdr);
        Address::from_xdr(env, &xdr)
            .expect("Failed to construct account address from bytes32")
    } else {
        // Reconstruct contract address
        let mut contract_xdr = [0u8; 36];
        contract_xdr[0] = 0;
        contract_xdr[1] = 0;
        contract_xdr[2] = 0;
        contract_xdr[3] = 1; // ScAddress::Contract variant
        for i in 0..32 {
            contract_xdr[4 + i] = bytes_arr[i];
        }

        let xdr = Bytes::from_array(env, &contract_xdr);
        Address::from_xdr(env, &xdr)
            .expect("Failed to construct contract address from bytes32")
    }
}

/// Convert bytes32 to Stellar Address (defaults to Contract address)
///
/// For cross-chain compatibility, bytes32 values are assumed to be CONTRACT addresses
/// by default, since:
/// 1. Token contracts are always Contract addresses
/// 2. Cross-chain receivers should use Contract addresses for better compatibility
///
/// If you need to convert to an Account address, use `bytes32_to_address_typed` instead.
fn bytes32_to_address(env: &Env, bytes: &BytesN<32>) -> Address {
    // Default to contract address for cross-chain compatibility
    // Users who need to receive at an account address should provide the type explicitly
    bytes32_to_address_typed(env, bytes, false)
}

/// Encode notify payload for cross-chain notification
/// Format: intentId (32) + fillHash (32) + repaymentAddress (32) + relayer (32) + amount (32)
/// Total: 160 bytes
fn encode_notify_payload(
    env: &Env,
    intent_id: &BytesN<32>,
    fill_hash: &BytesN<32>,
    repayment_address: &BytesN<32>,
    relayer: &BytesN<32>,
    amount: i128,
) -> Bytes {
    let mut payload = Bytes::new(env);

    // Intent ID (32 bytes)
    payload.append(&Bytes::from_array(env, &intent_id.to_array()));

    // Fill hash (32 bytes)
    payload.append(&Bytes::from_array(env, &fill_hash.to_array()));

    // Repayment address (32 bytes)
    payload.append(&Bytes::from_array(env, &repayment_address.to_array()));

    // Relayer (32 bytes) - who performed the fill
    payload.append(&Bytes::from_array(env, &relayer.to_array()));

    // Amount (32 bytes) - left-pad i128 to 32 bytes
    let mut amount_bytes = [0u8; 32];
    let amount_be = amount.to_be_bytes();
    amount_bytes[16..32].copy_from_slice(&amount_be);
    payload.append(&Bytes::from_array(env, &amount_bytes));

    payload
}

/// Decode notify payload from cross-chain notification
/// Format: intentId (32) + fillHash (32) + repaymentAddress (32) + relayer (32) + amount (32)
/// Returns: (fillHash, intentId, repaymentAddress, relayer, amount)
fn decode_notify_payload(
    env: &Env,
    payload: &Bytes,
) -> Result<(BytesN<32>, BytesN<32>, BytesN<32>, BytesN<32>, i128), Error> {
    if payload.len() != 160 {
        return Err(Error::InvalidPayload);
    }

    let mut intent_id_arr = [0u8; 32];
    let mut fill_hash_arr = [0u8; 32];
    let mut repayment_arr = [0u8; 32];
    let mut relayer_arr = [0u8; 32];
    let mut amount_arr = [0u8; 32];

    for i in 0..32 {
        intent_id_arr[i] = payload.get(i as u32).unwrap_or(0);
        fill_hash_arr[i] = payload.get((32 + i) as u32).unwrap_or(0);
        repayment_arr[i] = payload.get((64 + i) as u32).unwrap_or(0);
        relayer_arr[i] = payload.get((96 + i) as u32).unwrap_or(0);
        amount_arr[i] = payload.get((128 + i) as u32).unwrap_or(0);
    }

    let intent_id = BytesN::from_array(env, &intent_id_arr);
    let fill_hash = BytesN::from_array(env, &fill_hash_arr);
    let repayment_address = BytesN::from_array(env, &repayment_arr);
    let relayer = BytesN::from_array(env, &relayer_arr);

    // Amount: take last 16 bytes for i128
    let mut amount_i128_arr = [0u8; 16];
    amount_i128_arr.copy_from_slice(&amount_arr[16..32]);
    let amount = i128::from_be_bytes(amount_i128_arr);

    Ok((fill_hash, intent_id, repayment_address, relayer, amount))
}

#[cfg(test)]
mod test;
