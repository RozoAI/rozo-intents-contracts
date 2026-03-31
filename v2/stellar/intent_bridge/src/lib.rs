#![no_std]

use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, symbol_short,
    token, xdr::ToXdr, Address, Bytes, BytesN, Env, String,
};

/// Storage keys
#[derive(Clone)]
#[contracttype]
pub enum DataKey {
    Messenger,
    Relayer,
    DeadlineDuration,
    Intent(BytesN<32>),
}

/// Intent status
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[contracttype]
#[repr(u32)]
pub enum IntentStatus {
    Pending = 0,
    Filled = 1,
    Refunded = 2,
}

/// Intent data structure
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Intent {
    pub intent_id: BytesN<32>,
    pub sender: Address,
    pub source_token: Address,
    pub source_amount: i128,
    pub destination_chain: String,
    pub destination_address: String,
    pub destination_amount: i128,
    pub memo: String,
    pub status: IntentStatus,
    pub created_at: u64,
    pub deadline: u64,
}

/// Error codes
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    AlreadyInitialized = 1,
    NotInitialized = 2,
    ZeroAmount = 3,
    IntentNotFound = 4,
    InvalidStatus = 5,
    DeadlineNotReached = 6,
    MemoTooLong = 7,
    IntentAlreadyExists = 8,
    DeadlineExceeded = 9,
    DeadlineOverflow = 10,
    InvalidDeadlineDuration = 11,
}

/// Intent created event
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IntentCreatedEvent {
    pub intent_id: BytesN<32>,
    pub sender: Address,
    pub source_token: Address,
    pub source_amount: i128,
    pub destination_chain: String,
    pub destination_address: String,
    pub destination_amount: i128,
    pub deadline: u64,
}

/// Intent filled event
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IntentFilledEvent {
    pub intent_id: BytesN<32>,
    pub timestamp: u64,
}

/// Intent refunded event
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IntentRefundedEvent {
    pub intent_id: BytesN<32>,
    pub sender: Address,
    pub source_amount: i128,
    pub timestamp: u64,
}

/// TTL constants (7 days in ledgers, ~5 sec per ledger)
const INTENT_TTL_THRESHOLD: u32 = 120960; // 7 days
const INTENT_TTL_EXTEND: u32 = 241920;    // 14 days
const INSTANCE_TTL_THRESHOLD: u32 = 120960; // 7 days
const INSTANCE_TTL_EXTEND: u32 = 241920;    // 14 days

#[contract]
pub struct IntentBridge;

#[contractimpl]
impl IntentBridge {
    /// Constructor: called automatically on deployment
    /// This ensures only the deployer can set initial configuration
    /// Panics if deadline_duration is 0 (would make all intents immediately expire)
    pub fn __constructor(
        env: Env,
        messenger: Address,
        relayer: Address,
        deadline_duration: u64,
    ) {
        if deadline_duration == 0 {
            panic!("deadline_duration must be greater than 0");
        }
        env.storage().instance().set(&DataKey::Messenger, &messenger);
        env.storage().instance().set(&DataKey::Relayer, &relayer);
        env.storage().instance().set(&DataKey::DeadlineDuration, &deadline_duration);
    }

    /// Create intent and lock funds
    pub fn create_intent(
        env: Env,
        sender: Address,
        source_token: Address,
        source_amount: i128,
        destination_chain: String,
        destination_address: String,
        destination_amount: i128,
        memo: String,
    ) -> Result<BytesN<32>, Error> {
        // Check initialized (messenger must exist)
        if !env.storage().instance().has(&DataKey::Messenger) {
            return Err(Error::NotInitialized);
        }

        // Extend instance TTL to prevent contract archival
        env.storage().instance().extend_ttl(INSTANCE_TTL_THRESHOLD, INSTANCE_TTL_EXTEND);

        if source_amount <= 0 {
            return Err(Error::ZeroAmount);
        }
        if memo.len() > 28 {
            return Err(Error::MemoTooLong);
        }

        sender.require_auth();

        // Generate collision-resistant intent_id
        // Include all intent fields to prevent collision for same sender in same ledger
        let now = env.ledger().timestamp();
        let mut preimage = Bytes::new(&env);
        preimage.append(&sender.clone().to_xdr(&env));
        preimage.append(&Bytes::from_slice(&env, &now.to_be_bytes()));
        preimage.append(&Bytes::from_slice(&env, &env.ledger().sequence().to_be_bytes()));
        preimage.append(&source_token.clone().to_xdr(&env));
        preimage.append(&Bytes::from_slice(&env, &source_amount.to_be_bytes()));
        preimage.append(&destination_chain.clone().to_xdr(&env));
        preimage.append(&destination_address.clone().to_xdr(&env));
        preimage.append(&Bytes::from_slice(&env, &destination_amount.to_be_bytes()));
        preimage.append(&memo.clone().to_xdr(&env));
        let intent_id: BytesN<32> = env.crypto().sha256(&preimage).into();

        // Check intent_id doesn't exist
        if env.storage().persistent().has(&DataKey::Intent(intent_id.clone())) {
            return Err(Error::IntentAlreadyExists);
        }

        let deadline_duration: u64 = env
            .storage()
            .instance()
            .get(&DataKey::DeadlineDuration)
            .ok_or(Error::NotInitialized)?;

        // Safe deadline calculation with overflow check
        let deadline = now.checked_add(deadline_duration).ok_or(Error::DeadlineOverflow)?;

        let intent = Intent {
            intent_id: intent_id.clone(),
            sender: sender.clone(),
            source_token: source_token.clone(),
            source_amount,
            destination_chain: destination_chain.clone(),
            destination_address: destination_address.clone(),
            destination_amount,
            memo,
            status: IntentStatus::Pending,
            created_at: now,
            deadline,
        };

        // Lock funds to contract — measure actual received amount (balance delta)
        // to handle fee-on-transfer or deflationary tokens correctly
        let token_client = token::Client::new(&env, &source_token);
        let balance_before = token_client.balance(&env.current_contract_address());
        token_client.transfer(&sender, &env.current_contract_address(), &source_amount);
        let balance_after = token_client.balance(&env.current_contract_address());
        let actual_received = balance_after - balance_before;
        if actual_received <= 0 {
            return Err(Error::ZeroAmount);
        }

        // Store intent with actual escrowed amount
        let intent = Intent {
            source_amount: actual_received,
            ..intent
        };

        // Store intent with TTL extension
        let key = DataKey::Intent(intent_id.clone());
        env.storage().persistent().set(&key, &intent);
        env.storage().persistent().extend_ttl(&key, INTENT_TTL_THRESHOLD, INTENT_TTL_EXTEND);

        // Emit event with actual escrowed amount
        let event = IntentCreatedEvent {
            intent_id: intent_id.clone(),
            sender,
            source_token,
            source_amount: actual_received,
            destination_chain,
            destination_address,
            destination_amount,
            deadline,
        };
        env.events().publish((symbol_short!("created"),), event);

        Ok(intent_id)
    }

    /// Messenger: confirm cross-chain completion, transfer funds to Relayer
    pub fn fill(env: Env, intent_id: BytesN<32>) -> Result<(), Error> {
        let messenger: Address = env
            .storage()
            .instance()
            .get(&DataKey::Messenger)
            .ok_or(Error::NotInitialized)?;
        messenger.require_auth();

        // Extend instance TTL to prevent contract archival
        env.storage().instance().extend_ttl(INSTANCE_TTL_THRESHOLD, INSTANCE_TTL_EXTEND);

        let key = DataKey::Intent(intent_id.clone());
        let mut intent: Intent = env
            .storage()
            .persistent()
            .get(&key)
            .ok_or(Error::IntentNotFound)?;

        if intent.status != IntentStatus::Pending {
            return Err(Error::InvalidStatus);
        }

        // fill must be before deadline
        let now = env.ledger().timestamp();
        if now >= intent.deadline {
            return Err(Error::DeadlineExceeded);
        }

        // Update status first
        intent.status = IntentStatus::Filled;
        env.storage().persistent().set(&key, &intent);
        // Extend TTL to ensure intent record survives for audit
        env.storage().persistent().extend_ttl(&key, INTENT_TTL_THRESHOLD, INTENT_TTL_EXTEND);

        // Transfer to Relayer
        let relayer: Address = env
            .storage()
            .instance()
            .get(&DataKey::Relayer)
            .ok_or(Error::NotInitialized)?;
        let token_client = token::Client::new(&env, &intent.source_token);
        token_client.transfer(&env.current_contract_address(), &relayer, &intent.source_amount);

        // Emit event
        let event = IntentFilledEvent {
            intent_id,
            timestamp: now,
        };
        env.events().publish((symbol_short!("filled"),), event);

        Ok(())
    }

    /// User: refund after deadline
    pub fn refund(env: Env, intent_id: BytesN<32>) -> Result<(), Error> {
        // Extend instance TTL to prevent contract archival
        env.storage().instance().extend_ttl(INSTANCE_TTL_THRESHOLD, INSTANCE_TTL_EXTEND);

        let key = DataKey::Intent(intent_id.clone());
        let mut intent: Intent = env
            .storage()
            .persistent()
            .get(&key)
            .ok_or(Error::IntentNotFound)?;

        intent.sender.require_auth();

        if intent.status != IntentStatus::Pending {
            return Err(Error::InvalidStatus);
        }

        let now = env.ledger().timestamp();
        if now < intent.deadline {
            return Err(Error::DeadlineNotReached);
        }

        // Update status first
        intent.status = IntentStatus::Refunded;
        env.storage().persistent().set(&key, &intent);
        // Extend TTL to ensure intent record survives for audit
        env.storage().persistent().extend_ttl(&key, INTENT_TTL_THRESHOLD, INTENT_TTL_EXTEND);

        // Refund to sender
        let token_client = token::Client::new(&env, &intent.source_token);
        token_client.transfer(
            &env.current_contract_address(),
            &intent.sender,
            &intent.source_amount,
        );

        // Emit event
        let event = IntentRefundedEvent {
            intent_id,
            sender: intent.sender,
            source_amount: intent.source_amount,
            timestamp: now,
        };
        env.events().publish((symbol_short!("refunded"),), event);

        Ok(())
    }

    /// Query: get intent by id
    pub fn get_intent(env: Env, intent_id: BytesN<32>) -> Option<Intent> {
        env.storage().persistent().get(&DataKey::Intent(intent_id))
    }

    /// Query: get messenger address
    pub fn get_messenger(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::Messenger)
    }

    /// Query: get relayer address
    pub fn get_relayer(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::Relayer)
    }

    /// Query: get deadline duration
    pub fn get_deadline_duration(env: Env) -> Option<u64> {
        env.storage().instance().get(&DataKey::DeadlineDuration)
    }
}

#[cfg(test)]
mod test;
