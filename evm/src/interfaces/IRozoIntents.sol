// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMessengerAdapter} from "./IMessengerAdapter.sol";

/// @title Intent Status Enum
/// @notice PENDING -> FILLED (success) or FAILED (mismatch) or REFUNDED (after deadline)
enum IntentStatus {
    PENDING,  // Created, waiting for fill
    FILLED,   // Completed (via notify)
    FAILED,   // Fill verification failed (fillHash mismatch, admin must investigate)
    REFUNDED  // Sender refunded after deadline
}

/// @title Relayer Type Enum
/// @notice Used to categorize relayers for access control
enum RelayerType {
    NONE,     // Not a relayer
    ROZO,     // Rozo-operated relayer (can fill as fallback)
    EXTERNAL  // Third-party relayer
}

/// @title Intent Struct
/// @notice Represents a cross-chain payment intent stored on source chain
struct Intent {
    bytes32 intentId;           // Unique identifier (off-chain generated)
    address sender;             // Who created the intent
    address refundAddress;      // Where to refund if expired (usually sender)
    address sourceToken;        // Token deposited on source chain
    uint256 sourceAmount;       // Amount deposited (source chain decimals)
    uint256 destinationChainId; // Target chain ID
    bytes32 destinationToken;   // Token on destination (bytes32 for cross-chain compatibility)
    bytes32 receiver;           // Recipient on destination (bytes32 for cross-chain)
    bool receiverIsAccount;     // Is receiver a Stellar account (G...) or contract (C...)?
    uint256 destinationAmount;  // Minimum amount receiver expects
    uint64 deadline;            // Unix timestamp (seconds) - after this, refund allowed
    uint64 createdAt;           // Unix timestamp when intent was created (for Rozo fallback timing)
    IntentStatus status;        // Current state
    bytes32 relayer;            // Assigned relayer (bytes32 for cross-chain compatibility, address(0) = open)
}

/// @title Intent Data Struct
/// @notice Full intent data passed to fillAndNotify for cross-chain verification
struct IntentData {
    bytes32 intentId;
    bytes32 sender;
    bytes32 refundAddress;
    bytes32 sourceToken;
    uint256 sourceAmount;
    uint256 sourceChainId;
    uint256 destinationChainId;
    bytes32 destinationToken;
    bytes32 receiver;
    uint256 destinationAmount;
    uint64 deadline;
    uint64 createdAt;
    bytes32 relayer;
    bool receiverIsAccount;     // Is receiver a Stellar account (G...) or contract (C...)?
}

/// @title Fill Record Struct
/// @notice Tracks fills on destination chain for double-fill prevention and retry mechanism
struct FillRecord {
    address relayer;            // Who filled on destination chain
    bytes32 repaymentAddress;   // Relayer's address on source chain for payout
    bool repaymentIsAccount;    // Is repayment address a Stellar account (G...) or contract (C...)?
}

/// @title RozoIntents Errors
interface IRozoIntentsErrors {
    error IntentAlreadyExists();
    error IntentNotFound();
    error InvalidStatus(IntentStatus current, IntentStatus expected);
    error IntentExpired();
    error IntentNotExpired();
    error NotRelayer();
    error NotAssignedRelayer();
    error NotAuthorizedRelayer();
    error NotMessenger();
    error InvalidMessenger();
    error AlreadyFilled();
    error FillHashMismatch();
    error WrongChain();
    error InsufficientAmount(uint256 paid, uint256 required);
    error TransferFailed();
    error InvalidFee();
    error UntrustedSource();
    error InvalidPayload();
    error ZeroAddress();
    error InvalidDeadline();
}

/// @title RozoIntents Events
interface IRozoIntentsEvents {
    event IntentCreated(
        bytes32 indexed intentId,
        address indexed sender,
        address sourceToken,
        uint256 sourceAmount,
        uint256 destinationChainId,
        bytes32 receiver,
        uint256 destinationAmount,
        uint64 deadline,
        bytes32 relayer
    );

    event IntentFilled(
        bytes32 indexed intentId,
        bytes32 indexed relayer,
        bytes32 repaymentAddress,
        uint256 amountPaid
    );

    event IntentFailed(bytes32 indexed intentId, bytes32 expectedFillHash, bytes32 receivedFillHash);

    event IntentRefunded(bytes32 indexed intentId, address indexed refundAddress, uint256 amount);

    event FillAndNotifySent(
        bytes32 indexed intentId,
        address indexed relayer,
        bytes32 repaymentAddress,
        uint8 messengerId
    );

    event RetryNotifySent(
        bytes32 indexed intentId,
        address indexed relayer,
        uint8 messengerId
    );

    event IntentStatusChanged(
        bytes32 indexed intentId,
        IntentStatus oldStatus,
        IntentStatus newStatus,
        address indexed admin
    );

    event IntentRelayerChanged(
        bytes32 indexed intentId,
        bytes32 oldRelayer,
        bytes32 newRelayer,
        address indexed admin
    );

    event RelayerAdded(address indexed relayer, RelayerType relayerType);
    event RelayerRemoved(address indexed relayer);
    event MessengerAdapterSet(uint8 indexed messengerId, address indexed adapter);
    event TrustedContractSet(string chainName, string contractAddress);
    event RozoRelayerSet(address indexed rozoRelayer);
    event RozoRelayerThresholdSet(uint256 threshold);
    event ProtocolFeeSet(uint256 feeBps);
    event FeeRecipientSet(address indexed recipient);
    event FeesWithdrawn(address indexed token, address indexed recipient, uint256 amount);
}

/// @title RozoIntents User Interface
interface IRozoIntentsUser {
    /// @notice Create a new intent
    /// @param intentId Unique ID (off-chain generated)
    /// @param sourceToken Token to deposit on source chain
    /// @param sourceAmount Amount to deposit (source chain decimals)
    /// @param destinationChainId Target chain ID
    /// @param destinationToken Token address on destination (bytes32)
    /// @param receiver Recipient address on destination (bytes32)
    /// @param receiverIsAccount Whether receiver is a Stellar account (G...) or contract (C...)
    /// @param destinationAmount Minimum amount receiver expects
    /// @param deadline Unix timestamp after which refund is allowed
    /// @param refundAddress Where to refund if expired
    /// @param relayer Assigned relayer from RFQ (bytes32(0) = open to any whitelisted relayer)
    function createIntent(
        bytes32 intentId,
        address sourceToken,
        uint256 sourceAmount,
        uint256 destinationChainId,
        bytes32 destinationToken,
        bytes32 receiver,
        bool receiverIsAccount,
        uint256 destinationAmount,
        uint64 deadline,
        address refundAddress,
        bytes32 relayer
    ) external;

    /// @notice Refund an expired intent
    /// @param intentId The intent to refund
    function refund(bytes32 intentId) external;
}

/// @title RozoIntents Destination Interface
interface IRozoIntentsDestination {
    /// @notice Fill intent and send notification to source chain
    /// @param intentData Full intent data for cross-chain verification
    /// @param repaymentAddress Relayer's address on source chain for payout (bytes32)
    /// @param repaymentIsAccount Whether repayment address is a Stellar account (G...) or contract (C...)
    /// @param messengerId Messenger to use (0=Rozo, 1=Axelar)
    function fillAndNotify(
        IntentData calldata intentData,
        bytes32 repaymentAddress,
        bool repaymentIsAccount,
        uint8 messengerId
    ) external payable;

    /// @notice Retry notification with different messenger (if original messenger failed)
    /// @param intentData Full intent data for cross-chain verification
    /// @param messengerId New messenger to use (0=Rozo, 1=Axelar)
    function retryNotify(
        IntentData calldata intentData,
        uint8 messengerId
    ) external payable;
}

/// @title RozoIntents Messenger Interface
interface IRozoIntentsMessenger {
    /// @notice Called by messenger adapter to notify fill completion
    /// @param messengerId Messenger that delivered the notification
    /// @param sourceChainId Chain where fill happened
    /// @param messageData Encoded payload from messenger
    function notify(
        uint8 messengerId,
        uint256 sourceChainId,
        bytes calldata messageData
    ) external;
}

/// @title RozoIntents Admin Interface
interface IRozoIntentsAdmin {
    function setFeeRecipient(address recipient) external;
    function setProtocolFee(uint256 feeBps) external;
    function withdrawFees(address token) external;
    function addRelayer(address relayer, RelayerType relayerType) external;
    function removeRelayer(address relayer) external;
    function setMessengerAdapter(address adapter) external;
    function setTrustedContract(string calldata chainName, string calldata contractAddress) external;
    function setRozoRelayer(address relayer) external;
    function setRozoRelayerThreshold(uint256 threshold) external;
    function setIntentStatus(bytes32 intentId, IntentStatus status) external;
    function setIntentRelayer(bytes32 intentId, bytes32 relayer) external;
    function adminRefund(bytes32 intentId) external;
}

/// @title RozoIntents View Interface
interface IRozoIntentsView {
    function intents(bytes32 intentId) external view returns (Intent memory);
    function relayers(address relayer) external view returns (RelayerType);
    function messengerAdapters(uint8 messengerId) external view returns (IMessengerAdapter);
    function filledIntents(bytes32 fillHash) external view returns (address relayer, bytes32 repaymentAddress, bool repaymentIsAccount);
    function rozoRelayer() external view returns (address);
    function rozoRelayerThreshold() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function accumulatedFees(address token) external view returns (uint256);
}
