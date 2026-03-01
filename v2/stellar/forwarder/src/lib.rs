#![no_std]

use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, symbol_short,
    token, Address, Env, String,
};

/// Storage keys
#[derive(Clone)]
#[contracttype]
pub enum DataKey {
    Admin,
    ProxyAddress,
}

/// Error codes
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    NotInitialized = 1,
    ZeroAmount = 2,
    EmptyDestination = 3,
    MemoTooLong = 4,
}

/// Forward event data
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ForwardEvent {
    pub sender: Address,
    pub proxy_address: Address,
    pub token: Address,
    pub amount: i128,
    pub to: String,
    pub memo: String,
    pub timestamp: u64,
}

#[contract]
pub struct TokenForwarder;

#[contractimpl]
impl TokenForwarder {
    /// Constructor: called automatically on deployment
    /// This ensures only the deployer can set initial configuration
    pub fn __constructor(env: Env, admin: Address, proxy_address: Address) {
        env.storage().instance().set(&DataKey::Admin, &admin);
        env.storage().instance().set(&DataKey::ProxyAddress, &proxy_address);
    }

    /// Forward tokens to proxy_address
    pub fn forward(
        env: Env,
        sender: Address,
        token_addr: Address,
        amount: i128,
        to: String,
        memo: String,
    ) -> Result<(), Error> {
        // Check initialized (admin must exist)
        if !env.storage().instance().has(&DataKey::Admin) {
            return Err(Error::NotInitialized);
        }
        if amount <= 0 {
            return Err(Error::ZeroAmount);
        }
        if to.len() == 0 {
            return Err(Error::EmptyDestination);
        }
        if memo.len() > 28 {
            return Err(Error::MemoTooLong);
        }

        sender.require_auth();

        let proxy_address: Address = env
            .storage()
            .instance()
            .get(&DataKey::ProxyAddress)
            .ok_or(Error::NotInitialized)?;

        // Transfer to proxy_address
        let token_client = token::Client::new(&env, &token_addr);
        token_client.transfer(&sender, &proxy_address, &amount);

        // Emit event with destination address
        let event = ForwardEvent {
            sender: sender.clone(),
            proxy_address: proxy_address.clone(),
            token: token_addr,
            amount,
            to,
            memo,
            timestamp: env.ledger().timestamp(),
        };
        env.events().publish((symbol_short!("forward"), sender), event);

        Ok(())
    }

    /// Admin: update proxy address
    pub fn set_proxy_address(env: Env, new_proxy_address: Address) -> Result<(), Error> {
        let admin: Address = env
            .storage()
            .instance()
            .get(&DataKey::Admin)
            .ok_or(Error::NotInitialized)?;
        admin.require_auth();

        env.storage().instance().set(&DataKey::ProxyAddress, &new_proxy_address);

        Ok(())
    }

    /// Admin: flush stuck tokens to proxy_address
    pub fn flush(env: Env, token_addr: Address, amount: i128) -> Result<(), Error> {
        if amount <= 0 {
            return Err(Error::ZeroAmount);
        }

        let admin: Address = env
            .storage()
            .instance()
            .get(&DataKey::Admin)
            .ok_or(Error::NotInitialized)?;
        admin.require_auth();

        let proxy_address: Address = env
            .storage()
            .instance()
            .get(&DataKey::ProxyAddress)
            .ok_or(Error::NotInitialized)?;

        let token_client = token::Client::new(&env, &token_addr);
        token_client.transfer(&env.current_contract_address(), &proxy_address, &amount);

        Ok(())
    }

    /// Query: get proxy address
    pub fn get_proxy_address(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::ProxyAddress)
    }

    /// Query: get admin address
    pub fn get_admin(env: Env) -> Option<Address> {
        env.storage().instance().get(&DataKey::Admin)
    }
}

#[cfg(test)]
mod test;
