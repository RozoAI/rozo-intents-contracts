// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAxelarGateway} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";
import {IAxelarGasService} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";

import {
    Intent,
    IntentStatus,
    IRozoIntentsErrors,
    IRozoIntentsEvents,
    IRozoIntentsUser,
    IRozoIntentsRelayer,
    IRozoIntentsDestination,
    IRozoIntentsAdmin,
    IRozoIntentsView
} from "./interfaces/IRozoIntents.sol";

/// @title RozoIntents
/// @notice Intent-based cross-chain payments. Base <-> Stellar (bidirectional).
/// @dev No custom validators. Axelar handles verification.
contract RozoIntents is
    Ownable,
    ReentrancyGuard,
    IRozoIntentsErrors,
    IRozoIntentsEvents,
    IRozoIntentsUser,
    IRozoIntentsRelayer,
    IRozoIntentsDestination,
    IRozoIntentsAdmin,
    IRozoIntentsView
{
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant MAX_PROTOCOL_FEE = 30; // 30 bps = 0.3%
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Immutables ============
    IAxelarGateway public immutable gateway;
    IAxelarGasService public immutable gasService;

    // ============ Intent Storage ============
    mapping(bytes32 => Intent) private _intents;

    // ============ Access Control ============
    mapping(address => bool) public relayers;
    mapping(address => bool) public messengers;

    // ============ Cross-Chain Configuration ============
    mapping(string => string) public trustedContracts;
    mapping(uint256 => string) public chainIdToAxelarName;

    // ============ SlowFill Configuration (EVM only) ============
    // key = keccak256(abi.encodePacked(destinationChainId, sourceToken, destinationToken))
    mapping(bytes32 => address) public slowFillBridges;

    // ============ Fee Configuration ============
    uint256 public protocolFee;
    mapping(address => uint256) public accumulatedFees;
    address public feeRecipient;

    // ============ Constructor ============
    constructor(
        address _gateway,
        address _gasService,
        address _owner
    ) Ownable(_owner) {
        if (_gateway == address(0)) revert ZeroAddress();
        if (_gasService == address(0)) revert ZeroAddress();

        gateway = IAxelarGateway(_gateway);
        gasService = IAxelarGasService(_gasService);
        feeRecipient = _owner;
    }

    // ============ Modifiers ============
    modifier onlyRelayer() {
        if (!relayers[msg.sender]) revert NotRelayer();
        _;
    }

    modifier onlyMessenger() {
        if (!messengers[msg.sender]) revert NotMessenger();
        _;
    }

    // ============ View Functions ============
    function intents(bytes32 intentId) external view returns (Intent memory) {
        return _intents[intentId];
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
        address refundAddress
    ) external nonReentrant {
        // Validate
        if (_intents[intentId].sender != address(0)) revert IntentAlreadyExists();
        if (sourceToken == address(0)) revert ZeroAddress();
        if (sourceAmount == 0) revert InsufficientAmount(0, 1);
        if (deadline <= block.timestamp) revert InvalidDeadline();
        if (refundAddress == address(0)) {
            refundAddress = msg.sender;
        }

        // Store intent
        _intents[intentId] = Intent({
            intentId: intentId,
            sender: msg.sender,
            refundAddress: refundAddress,
            sourceToken: sourceToken,
            sourceAmount: sourceAmount,
            destinationChainId: destinationChainId,
            destinationToken: destinationToken,
            receiver: receiver,
            destinationAmount: destinationAmount,
            deadline: deadline,
            status: IntentStatus.NEW,
            relayer: address(0)
        });

        // Transfer tokens from sender to contract
        IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), sourceAmount);

        emit IntentCreated(
            intentId,
            msg.sender,
            sourceToken,
            sourceAmount,
            destinationChainId,
            receiver,
            destinationAmount,
            deadline
        );
    }

    /// @inheritdoc IRozoIntentsUser
    function refund(bytes32 intentId) external nonReentrant {
        Intent storage intent = _intents[intentId];

        if (intent.sender == address(0)) revert IntentNotFound();
        if (block.timestamp < intent.deadline) revert IntentNotExpired();
        if (intent.status != IntentStatus.NEW && intent.status != IntentStatus.FILLING) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }

        // Must be called by sender or refundAddress
        if (msg.sender != intent.sender && msg.sender != intent.refundAddress) {
            revert InvalidStatus(intent.status, IntentStatus.REFUNDED);
        }

        intent.status = IntentStatus.REFUNDED;

        // Transfer full amount back to refundAddress
        IERC20(intent.sourceToken).safeTransfer(intent.refundAddress, intent.sourceAmount);

        emit IntentRefunded(intentId, intent.refundAddress, intent.sourceAmount);
    }

    // ============ Relayer Functions ============

    /// @inheritdoc IRozoIntentsRelayer
    function fill(bytes32 intentId) external onlyRelayer nonReentrant {
        Intent storage intent = _intents[intentId];

        if (intent.sender == address(0)) revert IntentNotFound();
        if (intent.status != IntentStatus.NEW) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }
        if (block.timestamp >= intent.deadline) revert IntentExpired();

        intent.status = IntentStatus.FILLING;
        intent.relayer = msg.sender;

        emit IntentFilling(intentId, msg.sender);
    }

    /// @inheritdoc IRozoIntentsRelayer
    function slowFill(bytes32 intentId) external onlyRelayer nonReentrant {
        Intent storage intent = _intents[intentId];

        if (intent.sender == address(0)) revert IntentNotFound();
        if (intent.status != IntentStatus.NEW) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }
        if (block.timestamp >= intent.deadline) revert IntentExpired();

        // Get bridge adapter for this route
        bytes32 routeKey = keccak256(abi.encodePacked(
            intent.destinationChainId,
            intent.sourceToken,
            intent.destinationToken
        ));
        address bridgeAdapter = slowFillBridges[routeKey];
        if (bridgeAdapter == address(0)) revert SlowFillUnsupported();

        // Calculate fee (goes to protocol)
        uint256 feeAmount = intent.sourceAmount * protocolFee / BPS_DENOMINATOR;
        uint256 bridgeAmount = intent.sourceAmount - feeAmount;

        // Update status before external call
        intent.status = IntentStatus.FILLED;

        // Accumulate fee
        accumulatedFees[intent.sourceToken] += feeAmount;

        // Transfer to bridge adapter
        IERC20(intent.sourceToken).safeTransfer(bridgeAdapter, bridgeAmount);

        // TODO: Call bridge adapter to initiate CCTP transfer
        // For now, emit event with placeholder
        emit SlowFillTriggered(intentId, bytes32(0), msg.sender);
    }

    // ============ Destination Chain Functions ============

    /// @inheritdoc IRozoIntentsDestination
    function fillAndNotify(
        bytes32 intentId,
        bytes32 receiver,
        address token,
        uint256 amount,
        uint256 sourceChainId
    ) external payable onlyRelayer nonReentrant {
        if (amount == 0) revert InsufficientAmount(0, 1);

        // Get source chain Axelar name
        string memory sourceChain = chainIdToAxelarName[sourceChainId];
        if (bytes(sourceChain).length == 0) revert UntrustedSource();

        // Get trusted contract on source chain
        string memory sourceContract = trustedContracts[sourceChain];
        if (bytes(sourceContract).length == 0) revert UntrustedSource();

        // Transfer tokens from relayer to receiver
        address receiverAddr = address(uint160(uint256(receiver)));
        IERC20(token).safeTransferFrom(msg.sender, receiverAddr, amount);

        // Build payload for source chain (5 parameters)
        bytes memory payload = abi.encode(
            intentId,
            amount,
            bytes32(uint256(uint160(msg.sender))),  // relayer address as bytes32
            receiver,
            bytes32(uint256(uint160(token)))         // destination token as bytes32
        );

        // Pay for gas on destination (source chain for the callback)
        if (msg.value > 0) {
            gasService.payNativeGasForContractCall{value: msg.value}(
                address(this),
                sourceChain,
                sourceContract,
                payload,
                msg.sender
            );
        }

        // Call Axelar Gateway to send message to source chain
        gateway.callContract(sourceChain, sourceContract, payload);

        emit FillAndNotifySent(intentId, msg.sender, receiver, amount);
    }

    // ============ Axelar Executable ============

    /// @notice Called by Axelar Gateway to deliver cross-chain message
    /// @dev Only callable by registered messenger (Axelar Gateway)
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external onlyMessenger {
        // Validate the contract call with Axelar Gateway
        bytes32 payloadHash = keccak256(payload);
        if (!gateway.validateContractCall(commandId, sourceChain, sourceAddress, payloadHash)) {
            revert NotApprovedByGateway();
        }

        // Verify source contract is trusted for this chain
        if (keccak256(bytes(sourceAddress)) != keccak256(bytes(trustedContracts[sourceChain]))) {
            revert UntrustedSource();
        }

        // Decode payload (5 parameters)
        (
            bytes32 intentId,
            uint256 amountPaid,
            bytes32 relayerBytes,
            bytes32 receiverBytes,
            bytes32 destinationTokenBytes
        ) = abi.decode(payload, (bytes32, uint256, bytes32, bytes32, bytes32));

        // Complete the fill
        _completeFill(intentId, relayerBytes, amountPaid, receiverBytes, destinationTokenBytes);
    }

    /// @dev Internal function to complete a fill after Axelar verification
    function _completeFill(
        bytes32 intentId,
        bytes32 relayerBytes,
        uint256 amountPaid,
        bytes32 receiverBytes,
        bytes32 destinationTokenBytes
    ) internal nonReentrant {
        Intent storage intent = _intents[intentId];

        if (intent.sender == address(0)) revert IntentNotFound();

        // Status must be NEW or FILLING
        if (intent.status != IntentStatus.NEW && intent.status != IntentStatus.FILLING) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }

        // Verify all parameters match the original intent
        bool valid = true;
        valid = valid && (intent.receiver == receiverBytes);
        valid = valid && (intent.destinationToken == destinationTokenBytes);
        valid = valid && (amountPaid >= intent.destinationAmount);

        address relayerAddr = address(uint160(uint256(relayerBytes)));

        // If FILLING, also verify relayer matches
        if (intent.status == IntentStatus.FILLING) {
            valid = valid && (intent.relayer == relayerAddr);
        }

        if (!valid) {
            // Set to FAILED for admin investigation
            intent.status = IntentStatus.FAILED;
            emit IntentFailed(intentId, "Verification failed");
            return;
        }

        // Mark as filled
        intent.status = IntentStatus.FILLED;

        // If was NEW (no fill() called), record relayer from payload
        if (intent.relayer == address(0)) {
            intent.relayer = relayerAddr;
        }

        // Calculate protocol fee (protocolFee is in bps)
        uint256 feeAmount = intent.sourceAmount * protocolFee / BPS_DENOMINATOR;
        uint256 payout = intent.sourceAmount - feeAmount;

        // Accumulate fee for admin withdrawal
        accumulatedFees[intent.sourceToken] += feeAmount;

        // Transfer payout to relayer
        IERC20(intent.sourceToken).safeTransfer(intent.relayer, payout);

        emit IntentFilled(intentId, intent.relayer, amountPaid);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IRozoIntentsAdmin
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setProtocolFee(uint256 feeBps) external onlyOwner {
        if (feeBps > MAX_PROTOCOL_FEE) revert InvalidFee();
        protocolFee = feeBps;
        emit ProtocolFeeSet(feeBps);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function withdrawFees(address token) external {
        if (msg.sender != feeRecipient) revert NotMessenger();
        uint256 amount = accumulatedFees[token];
        if (amount == 0) revert InsufficientAmount(0, 1);

        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, amount);

        emit FeesWithdrawn(token, feeRecipient, amount);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function addRelayer(address relayer) external onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        relayers[relayer] = true;
        emit RelayerAdded(relayer);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function removeRelayer(address relayer) external onlyOwner {
        relayers[relayer] = false;
        emit RelayerRemoved(relayer);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setTrustedContract(string calldata chainName, string calldata contractAddress) external onlyOwner {
        trustedContracts[chainName] = contractAddress;
        emit TrustedContractSet(chainName, contractAddress);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setMessenger(address messenger, bool allowed) external onlyOwner {
        if (messenger == address(0)) revert ZeroAddress();
        messengers[messenger] = allowed;
        emit MessengerSet(messenger, allowed);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setChainIdToAxelarName(uint256 chainId, string calldata axelarName) external onlyOwner {
        chainIdToAxelarName[chainId] = axelarName;
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setSlowFillBridge(
        uint256 destinationChainId,
        address sourceToken,
        bytes32 destinationToken,
        address bridgeAdapter
    ) external onlyOwner {
        if (bridgeAdapter == address(0)) revert ZeroAddress();
        bytes32 routeKey = keccak256(abi.encodePacked(destinationChainId, sourceToken, destinationToken));
        slowFillBridges[routeKey] = bridgeAdapter;
    }

    /// @inheritdoc IRozoIntentsAdmin
    function removeSlowFillBridge(
        uint256 destinationChainId,
        address sourceToken,
        bytes32 destinationToken
    ) external onlyOwner {
        bytes32 routeKey = keccak256(abi.encodePacked(destinationChainId, sourceToken, destinationToken));
        delete slowFillBridges[routeKey];
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setIntentStatus(bytes32 intentId, IntentStatus status) external onlyOwner {
        Intent storage intent = _intents[intentId];
        if (intent.sender == address(0)) revert IntentNotFound();

        IntentStatus oldStatus = intent.status;
        intent.status = status;

        emit IntentStatusChanged(intentId, oldStatus, status, msg.sender);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function setIntentRelayer(bytes32 intentId, address relayer) external onlyOwner {
        Intent storage intent = _intents[intentId];
        if (intent.sender == address(0)) revert IntentNotFound();

        address oldRelayer = intent.relayer;
        intent.relayer = relayer;

        emit IntentRelayerChanged(intentId, oldRelayer, relayer, msg.sender);
    }

    /// @inheritdoc IRozoIntentsAdmin
    function adminRefund(bytes32 intentId) external onlyOwner nonReentrant {
        Intent storage intent = _intents[intentId];
        if (intent.sender == address(0)) revert IntentNotFound();

        // Can only admin refund if not already FILLED or REFUNDED
        if (intent.status == IntentStatus.FILLED || intent.status == IntentStatus.REFUNDED) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }

        intent.status = IntentStatus.REFUNDED;
        IERC20(intent.sourceToken).safeTransfer(intent.refundAddress, intent.sourceAmount);

        emit IntentRefunded(intentId, intent.refundAddress, intent.sourceAmount);
    }

    // ============ Receive ETH ============
    receive() external payable {}
}
