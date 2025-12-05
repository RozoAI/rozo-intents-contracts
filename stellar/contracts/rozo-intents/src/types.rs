use soroban_sdk::{contracttype, Address, BytesN};

/// Intent Status
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub enum IntentStatus {
    New,
    Filling,
    Filled,
    Failed,
    Refunded,
}

/// Intent Structure
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
    pub destination_amount: i128,
    pub deadline: u64,
    pub status: IntentStatus,
    pub relayer: Option<Address>,
}

/// Outbound message (for testing/debugging)
#[derive(Clone, Debug)]
#[contracttype]
pub struct OutboundMessage {
    pub destination_chain: soroban_sdk::String,
    pub destination_address: soroban_sdk::String,
    pub payload: soroban_sdk::Bytes,
}
