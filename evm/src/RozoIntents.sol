// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "./utils/Ownable.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "./utils/SafeERC20.sol";
import {
    Intent,
    IntentData,
    IntentStatus,
    RelayerType,
    FillRecord,
    IRozoIntentsErrors,
    IRozoIntentsEvents,
    IRozoIntentsUser,
    IRozoIntentsDestination,
    IRozoIntentsMessenger,
    IRozoIntentsAdmin,
    IRozoIntentsView
} from "./interfaces/IRozoIntents.sol";
import {IMessengerAdapter} from "./interfaces/IMessengerAdapter.sol";

/// @title RozoIntents
/// @notice Intent-based cross-chain settlement manager for Base ↔ Stellar
/// @dev Supports multiple messengers (Rozo, Axelar) via adapter pattern
contract RozoIntents is
    Ownable,
    ReentrancyGuard,
    IRozoIntentsErrors,
    IRozoIntentsEvents,
    IRozoIntentsUser,
    IRozoIntentsDestination,
    IRozoIntentsMessenger,
    IRozoIntentsAdmin,
    IRozoIntentsView
{
    using SafeERC20 for IERC20;

    uint256 private constant MAX_PROTOCOL_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ============ Storage ============

    /// @notice Intent storage by intentId
    mapping(bytes32 => Intent) private _intents;

    /// @notice Relayer whitelist with types (NONE, ROZO, EXTERNAL)
    mapping(address => RelayerType) public relayers;

    /// @notice Messenger adapters by messengerId (0=Rozo, 1=Axelar)
    mapping(uint8 => IMessengerAdapter) public messengerAdapters;

    /// @notice Filled intents by fillHash (destination chain only)
    mapping(bytes32 => FillRecord) public filledIntents;

    /// @notice Trusted contracts by chain name (for legacy Axelar compatibility)
    mapping(string => string) public trustedContracts;

    /// @notice Accumulated fees by token
    mapping(address => uint256) public accumulatedFees;

    /// @notice Rozo-operated relayer for fallback fills
    address public rozoRelayer;

    /// @notice Time (in seconds) after which rozoRelayer can fill any intent
    uint256 public rozoRelayerThreshold;

    /// @notice Protocol fee in basis points (max 30 bps)
    uint256 public protocolFee;

    /// @notice Address to receive protocol fees
    address public feeRecipient;

    // ============ Constructor ============

    constructor(address owner_, address feeRecipient_) Ownable(owner_) {
        if (feeRecipient_ != address(0)) {
            feeRecipient = feeRecipient_;
            emit FeeRecipientSet(feeRecipient_);
        }
    }

    // ============ User Functions ============

    /// @inheritdoc IRozoIntentsUser
    function createIntent(
        bytes32 intentId,
        address sourceToken,
        uint256 sourceAmount,
        uint256 destinationChainId,
        bytes32 destinationToken,
        bytes32 receiver,
        uint256 destinationAmount,
        uint64 deadline,
        address refundAddress,
        bytes32 relayer
    ) external override nonReentrant {
        if (intentId == bytes32(0)) revert InvalidPayload();
        if (sourceToken == address(0)) revert ZeroAddress();
        if (sourceAmount == 0 || destinationAmount == 0) revert InvalidPayload();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        Intent storage existing = _intents[intentId];
        if (existing.sender != address(0)) revert IntentAlreadyExists();

        address refundTarget = refundAddress == address(0) ? msg.sender : refundAddress;

        IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), sourceAmount);

        _intents[intentId] = Intent({
            intentId: intentId,
            sender: msg.sender,
            refundAddress: refundTarget,
            sourceToken: sourceToken,
            sourceAmount: sourceAmount,
            destinationChainId: destinationChainId,
            destinationToken: destinationToken,
            receiver: receiver,
            destinationAmount: destinationAmount,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            status: IntentStatus.PENDING,
            relayer: relayer
        });

        emit IntentCreated(
            intentId,
            msg.sender,
            sourceToken,
            sourceAmount,
            destinationChainId,
            receiver,
            destinationAmount,
            deadline,
            relayer
        );
    }

    /// @inheritdoc IRozoIntentsUser
    function refund(bytes32 intentId) external override nonReentrant {
        Intent storage intent = _requireIntent(intentId);
        if (intent.status != IntentStatus.PENDING) {
            revert InvalidStatus(intent.status, IntentStatus.PENDING);
        }
        if (block.timestamp < intent.deadline) revert IntentNotExpired();
        if (msg.sender != intent.sender && msg.sender != intent.refundAddress) revert NotRelayer();

        intent.status = IntentStatus.REFUNDED;
        IERC20(intent.sourceToken).safeTransfer(intent.refundAddress, intent.sourceAmount);

        emit IntentRefunded(intentId, intent.refundAddress, intent.sourceAmount);
    }

    // ============ Destination Functions ============

    /// @inheritdoc IRozoIntentsDestination
    function fillAndNotify(
        IntentData calldata intentData,
        bytes32 repaymentAddress,
        uint8 messengerId
    ) external payable override nonReentrant {
        // Verify caller is authorized relayer
        RelayerType callerType = relayers[msg.sender];
        if (callerType == RelayerType.NONE) revert NotRelayer();

        // Verify this is the correct destination chain
        if (intentData.destinationChainId != block.chainid) revert WrongChain();

        // Verify deadline not passed
        if (block.timestamp >= intentData.deadline) revert IntentExpired();

        // Verify relayer authorization
        bytes32 callerBytes32 = _addressToBytes32(msg.sender);
        if (intentData.relayer != bytes32(0)) {
            // Intent has assigned relayer
            bool isAssignedRelayer = intentData.relayer == callerBytes32;
            bool isRozoFallback = _isRozoFallback(msg.sender, intentData.createdAt);
            if (!isAssignedRelayer && !isRozoFallback) {
                revert NotAssignedRelayer();
            }
        }
        // If intentData.relayer == bytes32(0), any whitelisted relayer can fill

        // Compute fillHash for double-fill prevention
        bytes32 fillHash = keccak256(abi.encode(intentData));

        // Check not already filled
        FillRecord storage existing = filledIntents[fillHash];
        if (existing.relayer != address(0)) revert AlreadyFilled();

        // Store fill record
        filledIntents[fillHash] = FillRecord({
            relayer: msg.sender,
            repaymentAddress: repaymentAddress
        });

        // Transfer tokens to receiver
        address receiverAddress = _bytes32ToAddress(intentData.receiver);
        address tokenAddress = _bytes32ToAddress(intentData.destinationToken);
        if (receiverAddress == address(0) || tokenAddress == address(0)) revert InvalidPayload();

        IERC20(tokenAddress).safeTransferFrom(msg.sender, receiverAddress, intentData.destinationAmount);

        // Send cross-chain notification
        IMessengerAdapter adapter = messengerAdapters[messengerId];
        if (address(adapter) == address(0)) revert InvalidMessenger();

        bytes memory payload = abi.encode(
            fillHash,
            intentData.intentId,
            repaymentAddress,
            intentData.destinationAmount
        );

        adapter.sendMessage{value: msg.value}(intentData.sourceChainId, payload);

        emit FillAndNotifySent(intentData.intentId, msg.sender, repaymentAddress, messengerId);
    }

    /// @inheritdoc IRozoIntentsDestination
    function retryNotify(
        IntentData calldata intentData,
        uint8 messengerId
    ) external payable override nonReentrant {
        // Compute fillHash
        bytes32 fillHash = keccak256(abi.encode(intentData));

        // Must have been filled previously
        FillRecord storage record = filledIntents[fillHash];
        if (record.relayer == address(0)) revert IntentNotFound();

        // Only original filler can retry
        if (record.relayer != msg.sender) revert NotAssignedRelayer();

        // Get messenger adapter
        IMessengerAdapter adapter = messengerAdapters[messengerId];
        if (address(adapter) == address(0)) revert InvalidMessenger();

        // Resend notification
        bytes memory payload = abi.encode(
            fillHash,
            intentData.intentId,
            record.repaymentAddress,
            intentData.destinationAmount
        );

        adapter.sendMessage{value: msg.value}(intentData.sourceChainId, payload);

        emit RetryNotifySent(intentData.intentId, msg.sender, messengerId);
    }

    // ============ Messenger Callback ============

    /// @inheritdoc IRozoIntentsMessenger
    function notify(
        uint8 messengerId,
        uint256 sourceChainId,
        bytes calldata messageData
    ) external override nonReentrant {
        // Verify caller is the registered messenger adapter
        IMessengerAdapter adapter = messengerAdapters[messengerId];
        if (address(adapter) == address(0)) revert InvalidMessenger();
        if (msg.sender != address(adapter)) revert NotMessenger();

        // Verify and decode message
        bytes memory payload = adapter.verifyMessage(sourceChainId, messageData);

        (bytes32 fillHash, bytes32 intentId, bytes32 repaymentAddress, uint256 amountPaid) =
            abi.decode(payload, (bytes32, bytes32, bytes32, uint256));

        _completeFill(intentId, fillHash, repaymentAddress, amountPaid);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IRozoIntentsAdmin
    function setFeeRecipient(address recipient) external override onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setProtocolFee(uint256 feeBps) external override onlyOwner {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert InvalidFee();
        protocolFee = feeBps;
        emit ProtocolFeeSet(feeBps);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function withdrawFees(address token) external override onlyOwner nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (feeRecipient == address(0)) revert ZeroAddress();

        uint256 amount = accumulatedFees[token];
        if (amount == 0) return;

        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, amount);

        emit FeesWithdrawn(token, feeRecipient, amount);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function addRelayer(address relayer, RelayerType relayerType) external override onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        if (relayerType == RelayerType.NONE) revert InvalidPayload();
        relayers[relayer] = relayerType;
        emit RelayerAdded(relayer, relayerType);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function removeRelayer(address relayer) external override onlyOwner {
        relayers[relayer] = RelayerType.NONE;
        emit RelayerRemoved(relayer);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setMessengerAdapter(address adapter) external override onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        IMessengerAdapter messengerAdapter = IMessengerAdapter(adapter);
        uint8 id = messengerAdapter.messengerId();
        messengerAdapters[id] = messengerAdapter;
        emit MessengerAdapterSet(id, adapter);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setTrustedContract(string calldata chainName, string calldata contractAddress)
        external
        override
        onlyOwner
    {
        if (bytes(chainName).length == 0) revert InvalidPayload();
        trustedContracts[chainName] = contractAddress;
        emit TrustedContractSet(chainName, contractAddress);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setRozoRelayer(address relayer) external override onlyOwner {
        rozoRelayer = relayer;
        emit RozoRelayerSet(relayer);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setRozoRelayerThreshold(uint256 threshold) external override onlyOwner {
        rozoRelayerThreshold = threshold;
        emit RozoRelayerThresholdSet(threshold);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setIntentStatus(bytes32 intentId, IntentStatus status) external override onlyOwner {
        Intent storage intent = _requireIntent(intentId);
        IntentStatus old = intent.status;
        intent.status = status;
        emit IntentStatusChanged(intentId, old, status, msg.sender);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setIntentRelayer(bytes32 intentId, bytes32 relayer) external override onlyOwner {
        Intent storage intent = _requireIntent(intentId);
        bytes32 oldRelayer = intent.relayer;
        intent.relayer = relayer;
        emit IntentRelayerChanged(intentId, oldRelayer, relayer, msg.sender);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function adminRefund(bytes32 intentId) external override onlyOwner nonReentrant {
        Intent storage intent = _requireIntent(intentId);
        if (intent.status == IntentStatus.FILLED || intent.status == IntentStatus.REFUNDED) {
            revert InvalidStatus(intent.status, IntentStatus.PENDING);
        }

        intent.status = IntentStatus.REFUNDED;
        IERC20(intent.sourceToken).safeTransfer(intent.refundAddress, intent.sourceAmount);

        emit IntentRefunded(intentId, intent.refundAddress, intent.sourceAmount);
    }

    // ============ View Functions ============

    /// @inheritdoc IRozoIntentsView
    function intents(bytes32 intentId) external view override returns (Intent memory) {
        return _intents[intentId];
    }

    // ============ Internal Functions ============

    /// @notice Complete a fill on source chain after receiving cross-chain notification
    function _completeFill(
        bytes32 intentId,
        bytes32 fillHash,
        bytes32 repaymentAddress,
        uint256 amountPaid
    ) internal {
        Intent storage intent = _requireIntent(intentId);
        if (intent.status != IntentStatus.PENDING) {
            revert InvalidStatus(intent.status, IntentStatus.PENDING);
        }

        // Compute expected fillHash from stored intent
        IntentData memory expectedData = IntentData({
            intentId: intent.intentId,
            sender: _addressToBytes32(intent.sender),
            refundAddress: _addressToBytes32(intent.refundAddress),
            sourceToken: _addressToBytes32(intent.sourceToken),
            sourceAmount: intent.sourceAmount,
            sourceChainId: block.chainid,
            destinationChainId: intent.destinationChainId,
            destinationToken: intent.destinationToken,
            receiver: intent.receiver,
            destinationAmount: intent.destinationAmount,
            deadline: intent.deadline,
            createdAt: intent.createdAt,
            relayer: intent.relayer
        });
        bytes32 expectedFillHash = keccak256(abi.encode(expectedData));

        // Verify fillHash matches
        if (fillHash != expectedFillHash) {
            intent.status = IntentStatus.FAILED;
            emit IntentFailed(intentId, expectedFillHash, fillHash);
            return;
        }

        // Verify amount paid meets minimum
        if (amountPaid < intent.destinationAmount) {
            intent.status = IntentStatus.FAILED;
            emit IntentFailed(intentId, expectedFillHash, fillHash);
            return;
        }

        // Calculate fee and payout
        uint256 feeAmount = _calculateProtocolFee(intent.sourceAmount);
        uint256 relayerPayout = intent.sourceAmount - feeAmount;
        accumulatedFees[intent.sourceToken] += feeAmount;

        // Mark as filled
        intent.status = IntentStatus.FILLED;

        // Pay relayer using repaymentAddress
        address payoutAddress = _bytes32ToAddress(repaymentAddress);
        if (payoutAddress == address(0)) revert InvalidPayload();

        IERC20(intent.sourceToken).safeTransfer(payoutAddress, relayerPayout);

        emit IntentFilled(intentId, repaymentAddress, repaymentAddress, amountPaid);
    }

    /// @notice Check if caller qualifies as Rozo fallback
    function _isRozoFallback(address caller, uint64 createdAt) internal view returns (bool) {
        if (caller != rozoRelayer) return false;
        if (rozoRelayerThreshold == 0) return false;
        return block.timestamp >= createdAt + rozoRelayerThreshold;
    }

    /// @notice Calculate protocol fee for an amount
    function _calculateProtocolFee(uint256 amount) internal view returns (uint256) {
        return (amount * protocolFee) / BPS_DENOMINATOR;
    }

    /// @notice Convert address to bytes32
    function _addressToBytes32(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    /// @notice Convert bytes32 to address
    function _bytes32ToAddress(bytes32 value) internal pure returns (address) {
        return address(uint160(uint256(value)));
    }

    /// @notice Get intent or revert if not found
    function _requireIntent(bytes32 intentId) internal view returns (Intent storage) {
        Intent storage intent = _intents[intentId];
        if (intent.sender == address(0)) revert IntentNotFound();
        return intent;
    }
}
