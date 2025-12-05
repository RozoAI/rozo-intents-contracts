use soroban_sdk::contracterror;

#[contracterror]
#[derive(Clone, Debug, Copy, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    AlreadyInitialized = 1,
    NotInitialized = 2,
    NotOwner = 3,
    NotRelayer = 4,
    NotMessenger = 5,
    NotAuthorized = 6,
    IntentAlreadyExists = 10,
    IntentNotFound = 11,
    InvalidStatus = 12,
    IntentExpired = 13,
    IntentNotExpired = 14,
    InvalidAmount = 20,
    InvalidDeadline = 21,
    InvalidFee = 22,
    InvalidPayload = 23,
    UntrustedSource = 30,
    ChainNotFound = 31,
    TransferFailed = 40,
}
