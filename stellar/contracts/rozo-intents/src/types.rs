use soroban_sdk::{contracttype, Address, Bytes, BytesN, String};

/// Input parameters for create_intent function
/// Bundled to avoid hitting the 10-parameter limit
#[derive(Clone, Debug)]
#[contracttype]
pub struct CreateIntentParams {
    pub intent_id: BytesN<32>,
    pub source_token: Address,
    pub source_amount: i128,
    pub destination_chain_id: u64,
    pub destination_token: BytesN<32>,
    pub receiver: BytesN<32>,
    pub receiver_is_account: bool,
    pub destination_amount: i128,
    pub deadline: u64,
    pub refund_address: Address,
    pub relayer: BytesN<32>,
}

/// Intent Status
/// PENDING -> FILLED (success) or FAILED (mismatch) or REFUNDED (after deadline)
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub enum IntentStatus {
    Pending,   // Created, waiting for fill
    Filled,    // Completed (via notify)
    Failed,    // Fill verification failed (fillHash mismatch)
    Refunded,  // Sender refunded after deadline
}

/// Relayer Type
/// Used to categorize relayers for access control
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub enum RelayerType {
    None,      // Not a relayer
    Rozo,      // Rozo-operated relayer (can fill as fallback)
    External,  // Third-party relayer
}

/// Intent Structure (stored on source chain)
#[derive(Clone, Debug)]
#[contracttype]
pub struct Intent {
    pub intent_id: BytesN<32>,
    pub sender: Address,
    pub refund_address: Address,
    pub source_token: Address,
    pub source_amount: i128,
    pub destination_chain_id: u64,
    pub destination_token: BytesN<32>,
    pub receiver: BytesN<32>,
    pub receiver_is_account: bool,     // Is receiver a Stellar account (G...) or contract (C...)?
    pub destination_amount: i128,
    pub deadline: u64,
    pub created_at: u64,               // Timestamp when intent was created (for Rozo fallback)
    pub status: IntentStatus,
    pub relayer: BytesN<32>,           // Assigned relayer (bytes32 for cross-chain compatibility)
}

/// Intent Data Structure (passed to fillAndNotify)
/// Full intent data for cross-chain verification
#[derive(Clone, Debug)]
#[contracttype]
pub struct IntentData {
    pub intent_id: BytesN<32>,
    pub sender: BytesN<32>,
    pub refund_address: BytesN<32>,
    pub source_token: BytesN<32>,
    pub source_amount: i128,
    pub source_chain_id: u64,
    pub destination_chain_id: u64,
    pub destination_token: BytesN<32>,
    pub receiver: BytesN<32>,
    pub destination_amount: i128,
    pub deadline: u64,
    pub created_at: u64,
    pub relayer: BytesN<32>,
    // Address type flags for Stellar addresses (true = Account/G..., false = Contract/C...)
    // These are needed because bytes32 cannot encode the address type
    pub receiver_is_account: bool,      // Is receiver a Stellar account (G...) or contract (C...)?
}

/// Fill Record Structure
/// Tracks fills on destination chain for double-fill prevention and retry mechanism
#[derive(Clone, Debug)]
#[contracttype]
pub struct FillRecord {
    pub relayer: Address,              // Who filled on destination chain
    pub repayment_address: BytesN<32>, // Relayer's address on source chain for payout
    pub repayment_is_account: bool,    // Is repayment address an account (G...) or contract (C...)?
}

/// Outbound message (for testing/debugging)
#[derive(Clone, Debug)]
#[contracttype]
pub struct OutboundMessage {
    pub destination_chain: String,
    pub destination_address: String,
    pub payload: Bytes,
}
