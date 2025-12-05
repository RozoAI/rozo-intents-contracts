// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Intent Status Enum
enum IntentStatus {
    NEW, // Created, waiting for fill
    FILLING, // Relayer called fill(), awaiting confirmation
    FILLED, // Completed (via notify or slowFill)
    FAILED, // Fill verification failed (admin must investigate)
    REFUNDED // Sender refunded after deadline
}

/// @title Intent Struct
/// @notice Represents a cross-chain payment intent
struct Intent {
    bytes32 intentId; // Unique identifier (off-chain generated)
    address sender; // Who created the intent
    address refundAddress; // Where to refund if expired (usually sender)
    address sourceToken; // Token deposited on source chain
    uint256 sourceAmount; // Amount deposited (source chain decimals)
    uint256 destinationChainId; // Target chain ID
    bytes32 destinationToken; // Token on destination (bytes32 for cross-chain compatibility)
    bytes32 receiver; // Recipient on destination (bytes32 for cross-chain)
    uint256 destinationAmount; // Minimum amount receiver expects
    uint64 deadline; // Unix timestamp (seconds) - after this, refund allowed
    IntentStatus status; // Current state
    address relayer; // Who filled (set on fill())
}

/// @title RozoIntents Errors
interface IRozoIntentsErrors {
    error IntentAlreadyExists();
    error IntentNotFound();
    error InvalidStatus(IntentStatus current, IntentStatus expected);
    error IntentExpired();
    error IntentNotExpired();
    error NotRelayer();
    error NotMessenger();
    error NotGateway();
    error InsufficientAmount(uint256 paid, uint256 required);
    error SlowFillUnsupported();
    error TransferFailed();
    error InvalidFee();
    error UntrustedSource();
    error NotApprovedByGateway();
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
        uint64 deadline
    );

    event IntentFilling(bytes32 indexed intentId, address indexed relayer);

    event IntentFilled(bytes32 indexed intentId, address indexed relayer, uint256 amountPaid);

    event IntentFailed(bytes32 indexed intentId, string reason);

    event IntentRefunded(bytes32 indexed intentId, address indexed refundAddress, uint256 amount);

    event SlowFillTriggered(bytes32 indexed intentId, bytes32 bridgeMessageId, address indexed caller);

    event IntentStatusChanged(
        bytes32 indexed intentId, IntentStatus oldStatus, IntentStatus newStatus, address indexed admin
    );

    event IntentRelayerChanged(bytes32 indexed intentId, address oldRelayer, address newRelayer, address indexed admin);

    event FillAndNotifySent(bytes32 indexed intentId, address indexed relayer, bytes32 receiver, uint256 amount);

    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event MessengerSet(address indexed messenger, bool allowed);
    event TrustedContractSet(string chainName, string contractAddress);
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
    /// @param destinationAmount Minimum amount receiver expects
    /// @param deadline Unix timestamp after which refund is allowed
    /// @param refundAddress Where to refund if expired
    function createIntent(
        bytes32 intentId,
        address sourceToken,
        uint256 sourceAmount,
        uint256 destinationChainId,
        bytes32 destinationToken,
        bytes32 receiver,
        uint256 destinationAmount,
        uint64 deadline,
        address refundAddress
    ) external;

    /// @notice Refund an expired intent
    /// @param intentId The intent to refund
    function refund(bytes32 intentId) external;
}

/// @title RozoIntents Relayer Interface
interface IRozoIntentsRelayer {
    /// @notice Mark an intent as FILLING (relayer claims intent)
    /// @param intentId The intent to fill
    function fill(bytes32 intentId) external;

    /// @notice Trigger slow fill via CCTP bridge (EVM only)
    /// @param intentId The intent to slow fill
    function slowFill(bytes32 intentId) external;
}

/// @title RozoIntents Destination Interface
interface IRozoIntentsDestination {
    /// @notice Fill intent and send notification to source chain
    /// @param intentId Intent ID from source chain
    /// @param receiver Recipient address on destination chain
    /// @param token Token to transfer on destination chain
    /// @param amount Amount to pay receiver
    /// @param sourceChainId Source chain ID for Axelar callback routing
    function fillAndNotify(bytes32 intentId, bytes32 receiver, address token, uint256 amount, uint256 sourceChainId)
        external
        payable;
}

/// @title RozoIntents Admin Interface
interface IRozoIntentsAdmin {
    function setFeeRecipient(address recipient) external;
    function setProtocolFee(uint256 feeBps) external;
    function withdrawFees(address token) external;
    function addRelayer(address relayer) external;
    function removeRelayer(address relayer) external;
    function setTrustedContract(string calldata chainName, string calldata contractAddress) external;
    function setMessenger(address messenger, bool allowed) external;
    function setChainIdToAxelarName(uint256 chainId, string calldata axelarName) external;
    function setSlowFillBridge(
        uint256 destinationChainId,
        address sourceToken,
        bytes32 destinationToken,
        address bridgeAdapter
    ) external;
    function removeSlowFillBridge(uint256 destinationChainId, address sourceToken, bytes32 destinationToken) external;
    function setIntentStatus(bytes32 intentId, IntentStatus status) external;
    function setIntentRelayer(bytes32 intentId, address relayer) external;
    function adminRefund(bytes32 intentId) external;
}

/// @title RozoIntents View Interface
interface IRozoIntentsView {
    function intents(bytes32 intentId) external view returns (Intent memory);
    function relayers(address relayer) external view returns (bool);
    function messengers(address messenger) external view returns (bool);
    function trustedContracts(string calldata chainName) external view returns (string memory);
    function chainIdToAxelarName(uint256 chainId) external view returns (string memory);
    function protocolFee() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function accumulatedFees(address token) external view returns (uint256);
}
