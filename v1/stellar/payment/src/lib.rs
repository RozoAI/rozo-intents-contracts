#![no_std]

use soroban_sdk::{contract, contracterror, contractimpl, contracttype, symbol_short, token, Address, Env, String, Symbol};

// Storage keys
const DEST: Symbol = symbol_short!("dest");
const USDC: Symbol = symbol_short!("usdc");
const INIT: Symbol = symbol_short!("init");

// Mainnet USDC contract
const USDC_CONTRACT: &str = "CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75";

// Contract errors
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    AlreadyInitialized = 1,
    NotInitialized = 2,
    ZeroAmount = 3,
    InsufficientBalance = 4,
}

// Event topics
const PAYMENT: Symbol = symbol_short!("payment");
const FLUSH: Symbol = symbol_short!("flush");

// Contract event data types
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaymentEvent {
    pub from: Address,
    pub destination: Address,
    pub amount: i128,
    pub memo: String,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FlushEvent {
    pub token: Address,
    pub destination: Address,
    pub amount: i128,
}

#[contract]
pub struct Payment;

#[contractimpl]
impl Payment {
    /// Initialize the contract with a destination address
    /// Can only be called once
    pub fn init(env: Env, destination: Address) -> Result<(), Error> {
        // Check if already initialized
        if env.storage().instance().has(&INIT) {
            return Err(Error::AlreadyInitialized);
        }

        // Store destination address
        env.storage().instance().set(&DEST, &destination);

        // Store USDC address
        let usdc_str = String::from_str(&env, USDC_CONTRACT);
        let usdc_addr = Address::from_string(&usdc_str);
        env.storage().instance().set(&USDC, &usdc_addr);

        // Mark as initialized
        env.storage().instance().set(&INIT, &true);

        Ok(())
    }

    /// Pay USDC to the destination address
    /// The caller must have approved the contract to spend their USDC
    /// Memo is included in the event for tracking
    pub fn pay(env: Env, from: Address, amount: i128, memo: String) -> Result<(), Error> {
        // Check initialization
        if !env.storage().instance().has(&INIT) {
            return Err(Error::NotInitialized);
        }

        // Validate amount
        if amount <= 0 {
            return Err(Error::ZeroAmount);
        }

        // Require authorization from the payer
        from.require_auth();

        // Get destination and USDC addresses
        let destination: Address = env.storage().instance().get(&DEST).unwrap();
        let usdc_address: Address = env.storage().instance().get(&USDC).unwrap();

        // Transfer USDC from caller to destination
        let token_client = token::Client::new(&env, &usdc_address);
        token_client.transfer(&from, &destination, &amount);

        // Emit payment event
        env.events().publish(
            (PAYMENT, from.clone()),
            PaymentEvent {
                from,
                destination,
                amount,
                memo,
            },
        );

        Ok(())
    }

    /// Flush any tokens from this contract to the destination
    /// This is useful for recovering tokens accidentally sent to the contract
    pub fn flush(env: Env, token_contract: Address, amount: i128) -> Result<(), Error> {
        // Check initialization
        if !env.storage().instance().has(&INIT) {
            return Err(Error::NotInitialized);
        }

        // Validate amount
        if amount <= 0 {
            return Err(Error::ZeroAmount);
        }

        // Get destination address
        let destination: Address = env.storage().instance().get(&DEST).unwrap();

        // Transfer tokens from contract to destination
        let token_client = token::Client::new(&env, &token_contract);
        token_client.transfer(&env.current_contract_address(), &destination, &amount);

        // Emit flush event
        env.events().publish(
            (FLUSH, destination.clone()),
            FlushEvent {
                token: token_contract,
                destination,
                amount,
            },
        );

        Ok(())
    }

    /// Get the destination address
    pub fn get_destination(env: Env) -> Address {
        env.storage().instance().get(&DEST).unwrap()
    }

    /// Get the USDC token address
    pub fn get_usdc(env: Env) -> Address {
        env.storage().instance().get(&USDC).unwrap()
    }
}

#[cfg(test)]
mod test;
