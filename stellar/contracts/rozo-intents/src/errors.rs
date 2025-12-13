use soroban_sdk::contracterror;

#[contracterror]
#[derive(Clone, Debug, Copy, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    // Initialization errors
    AlreadyInitialized = 1,
    NotInitialized = 2,

    // Authorization errors
    NotOwner = 3,
    NotRelayer = 4,
    NotMessenger = 5,
    NotAuthorized = 6,

    // Intent errors
    IntentAlreadyExists = 10,
    IntentNotFound = 11,
    InvalidStatus = 12,
    IntentExpired = 13,
    IntentNotExpired = 14,

    // Validation errors
    InvalidAmount = 20,
    InvalidDeadline = 21,
    InvalidFee = 22,
    InvalidPayload = 23,

    // Cross-chain errors
    UntrustedSource = 30,
    ChainNotFound = 31,
    WrongChain = 32,

    // Transfer errors
    TransferFailed = 40,

    // Relayer errors
    NotAssignedRelayer = 50,
    NotAuthorizedRelayer = 51,
    AlreadyFilled = 52,
    FillHashMismatch = 53,
    InvalidMessenger = 54,
}
