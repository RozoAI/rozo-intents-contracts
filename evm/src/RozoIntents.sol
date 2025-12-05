// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "./utils/Ownable.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "./utils/SafeERC20.sol";
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
import {IAxelarGateway, IAxelarGasService} from "./interfaces/axelar/IAxelarGateway.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";

/// @title RozoIntents
/// @notice Intent-based cross-chain settlement manager for Base ↔ Stellar and EVM routes
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

    uint256 private constant MAX_PROTOCOL_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    mapping(bytes32 => Intent) private _intents;
    mapping(address => bool) public relayers;
    mapping(address => bool) public messengers;
    mapping(string => string) public trustedContracts;
    mapping(uint256 => string) public chainIdToAxelarName;
    mapping(bytes32 => address) public slowFillBridges;
    mapping(address => uint256) public accumulatedFees;

    uint256 public protocolFee; // in basis points
    address public feeRecipient;
    IAxelarGateway public gateway;
    IAxelarGasService public gasService;

    constructor(address owner_, address gateway_, address gasService_, address feeRecipient_) Ownable(owner_) {
        if (gateway_ != address(0)) {
            gateway = IAxelarGateway(gateway_);
            messengers[gateway_] = true;
            emit MessengerSet(gateway_, true);
        }
        if (gasService_ != address(0)) {
            gasService = IAxelarGasService(gasService_);
        }
        if (feeRecipient_ != address(0)) {
            feeRecipient = feeRecipient_;
            emit FeeRecipientSet(feeRecipient_);
        }
    }

    // ========= User Functions =========

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
    ) external override nonReentrant {
        if (intentId == bytes32(0)) revert InvalidPayload();
        if (sourceToken == address(0)) revert ZeroAddress();
        if (sourceAmount == 0 || destinationAmount == 0) revert InvalidPayload();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        Intent storage existing = _intents[intentId];
        if (existing.sender != address(0)) revert IntentAlreadyExists();

        address refund = refundAddress == address(0) ? msg.sender : refundAddress;

        IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), sourceAmount);

        _intents[intentId] = Intent({
            intentId: intentId,
            sender: msg.sender,
            refundAddress: refund,
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

        emit IntentCreated(
            intentId, msg.sender, sourceToken, sourceAmount, destinationChainId, receiver, destinationAmount, deadline
        );
    }

    function refund(bytes32 intentId) external override nonReentrant {
        Intent storage intent = _requireIntent(intentId);
        if (intent.status != IntentStatus.NEW && intent.status != IntentStatus.FILLING) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }
        if (block.timestamp < intent.deadline) revert IntentNotExpired();
        if (msg.sender != intent.sender && msg.sender != intent.refundAddress) revert NotRelayer();

        intent.status = IntentStatus.REFUNDED;
        IERC20(intent.sourceToken).safeTransfer(intent.refundAddress, intent.sourceAmount);

        emit IntentRefunded(intentId, intent.refundAddress, intent.sourceAmount);
    }

    // ========= Relayer Functions =========

    function fill(bytes32 intentId) external override nonReentrant {
        if (!relayers[msg.sender]) revert NotRelayer();
        Intent storage intent = _requireIntent(intentId);
        if (intent.status != IntentStatus.NEW) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }
        if (block.timestamp >= intent.deadline) revert IntentExpired();

        intent.status = IntentStatus.FILLING;
        intent.relayer = msg.sender;

        emit IntentFilling(intentId, msg.sender);
    }

    function slowFill(bytes32 intentId) external override nonReentrant {
        if (!relayers[msg.sender]) revert NotRelayer();
        Intent storage intent = _requireIntent(intentId);
        if (intent.status != IntentStatus.NEW) revert InvalidStatus(intent.status, IntentStatus.NEW);
        if (block.timestamp >= intent.deadline) revert IntentExpired();

        bytes32 routeKey = _routeKey(intent.destinationChainId, intent.sourceToken, intent.destinationToken);
        address bridge = slowFillBridges[routeKey];
        if (bridge == address(0)) revert SlowFillUnsupported();

        uint256 feeAmount = _calculateProtocolFee(intent.sourceAmount);
        uint256 amountToBridge = intent.sourceAmount - feeAmount;
        if (amountToBridge < intent.destinationAmount) {
            revert InsufficientAmount(amountToBridge, intent.destinationAmount);
        }

        intent.status = IntentStatus.FILLED;
        accumulatedFees[intent.sourceToken] += feeAmount;

        IERC20(intent.sourceToken).safeTransfer(bridge, amountToBridge);

        bytes32 bridgeMessageId = IBridgeAdapter(bridge)
            .bridge(
                intent.destinationChainId,
                intent.receiver,
                intent.sourceToken,
                intent.destinationToken,
                amountToBridge,
                intent.refundAddress
            );

        emit SlowFillTriggered(intentId, bridgeMessageId, msg.sender);
    }

    // ========= Destination Functions =========

    function fillAndNotify(bytes32 intentId, bytes32 receiver, address token, uint256 amount, uint256 sourceChainId)
        external
        payable
        override
        nonReentrant
    {
        if (!relayers[msg.sender]) revert NotRelayer();
        if (token == address(0) || amount == 0) revert InvalidPayload();
        address receiverAddress = _bytes32ToAddress(receiver);
        if (receiverAddress == address(0)) revert InvalidPayload();

        IERC20(token).safeTransferFrom(msg.sender, receiverAddress, amount);

        string memory sourceChainName = chainIdToAxelarName[sourceChainId];
        if (bytes(sourceChainName).length == 0) revert UntrustedSource();

        string memory destinationAddress = trustedContracts[sourceChainName];
        if (bytes(destinationAddress).length == 0) revert UntrustedSource();

        bytes memory payload =
            abi.encode(intentId, amount, _addressToBytes32(msg.sender), receiver, _addressToBytes32(token));

        address gasServiceAddress = address(gasService);
        if (msg.value > 0) {
            if (gasServiceAddress == address(0)) revert ZeroAddress();
            gasService.payNativeGasForContractCall{value: msg.value}(
                address(this), sourceChainName, destinationAddress, payload, msg.sender
            );
        }

        address gatewayAddress = address(gateway);
        if (gatewayAddress == address(0)) revert NotGateway();
        gateway.callContract(sourceChainName, destinationAddress, payload);

        emit FillAndNotifySent(intentId, msg.sender, receiver, amount);
    }

    // ========= Messenger Callback =========

    function notify(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external nonReentrant {
        if (!messengers[msg.sender]) revert NotMessenger();
        if (msg.sender != address(gateway)) revert NotGateway();

        bytes32 payloadHash = keccak256(payload);
        bool approved = gateway.validateContractCall(commandId, sourceChain, sourceAddress, payloadHash);
        if (!approved) revert NotApprovedByGateway();

        string memory trusted = trustedContracts[sourceChain];
        if (bytes(trusted).length == 0 || keccak256(bytes(trusted)) != keccak256(bytes(sourceAddress))) {
            revert UntrustedSource();
        }

        (bytes32 intentId, uint256 amountPaid, bytes32 relayerBytes, bytes32 receiver, bytes32 destinationToken) =
            abi.decode(payload, (bytes32, uint256, bytes32, bytes32, bytes32));

        _completeFill(intentId, amountPaid, relayerBytes, receiver, destinationToken);
    }

    // ========= Admin =========

    function setFeeRecipient(address recipient) external override onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setProtocolFee(uint256 feeBps) external override onlyOwner {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert InvalidFee();
        protocolFee = feeBps;
        emit ProtocolFeeSet(feeBps);
    }

    function withdrawFees(address token) external override onlyOwner nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (feeRecipient == address(0)) revert ZeroAddress();

        uint256 amount = accumulatedFees[token];
        if (amount == 0) return;

        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, amount);

        emit FeesWithdrawn(token, feeRecipient, amount);
    }

    function addRelayer(address relayer) external override onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        relayers[relayer] = true;
        emit RelayerAdded(relayer);
    }

    function removeRelayer(address relayer) external override onlyOwner {
        relayers[relayer] = false;
        emit RelayerRemoved(relayer);
    }

    function setTrustedContract(string calldata chainName, string calldata contractAddress)
        external
        override
        onlyOwner
    {
        if (bytes(chainName).length == 0) revert InvalidPayload();
        trustedContracts[chainName] = contractAddress;
        emit TrustedContractSet(chainName, contractAddress);
    }

    function setMessenger(address messenger, bool allowed) external override onlyOwner {
        if (messenger == address(0)) revert ZeroAddress();
        messengers[messenger] = allowed;
        if (allowed) {
            gateway = IAxelarGateway(messenger);
        } else if (address(gateway) == messenger) {
            gateway = IAxelarGateway(address(0));
        }
        emit MessengerSet(messenger, allowed);
    }

    function setChainIdToAxelarName(uint256 chainId, string calldata axelarName) external override onlyOwner {
        if (bytes(axelarName).length == 0) revert InvalidPayload();
        chainIdToAxelarName[chainId] = axelarName;
    }

    function setSlowFillBridge(
        uint256 destinationChainId,
        address sourceToken,
        bytes32 destinationToken,
        address bridgeAdapter
    ) external override onlyOwner {
        if (bridgeAdapter == address(0) || sourceToken == address(0)) revert ZeroAddress();
        bytes32 key = _routeKey(destinationChainId, sourceToken, destinationToken);
        slowFillBridges[key] = bridgeAdapter;
    }

    function removeSlowFillBridge(uint256 destinationChainId, address sourceToken, bytes32 destinationToken)
        external
        override
        onlyOwner
    {
        bytes32 key = _routeKey(destinationChainId, sourceToken, destinationToken);
        slowFillBridges[key] = address(0);
    }

    function setIntentStatus(bytes32 intentId, IntentStatus status) external override onlyOwner {
        Intent storage intent = _requireIntent(intentId);
        IntentStatus old = intent.status;
        intent.status = status;
        emit IntentStatusChanged(intentId, old, status, msg.sender);
    }

    function setIntentRelayer(bytes32 intentId, address relayer) external override onlyOwner {
        Intent storage intent = _requireIntent(intentId);
        address oldRelayer = intent.relayer;
        intent.relayer = relayer;
        emit IntentRelayerChanged(intentId, oldRelayer, relayer, msg.sender);
    }

    function adminRefund(bytes32 intentId) external override onlyOwner nonReentrant {
        Intent storage intent = _requireIntent(intentId);
        if (intent.status == IntentStatus.FILLED || intent.status == IntentStatus.REFUNDED) {
            revert InvalidStatus(intent.status, IntentStatus.REFUNDED);
        }

        intent.status = IntentStatus.REFUNDED;
        IERC20(intent.sourceToken).safeTransfer(intent.refundAddress, intent.sourceAmount);

        emit IntentRefunded(intentId, intent.refundAddress, intent.sourceAmount);
    }

    // ========= Views =========

    function intents(bytes32 intentId) external view override returns (Intent memory) {
        return _intents[intentId];
    }

    // ========= Internal =========

    function _completeFill(
        bytes32 intentId,
        uint256 amountPaid,
        bytes32 relayerBytes,
        bytes32 receiver,
        bytes32 destinationToken
    ) internal {
        Intent storage intent = _requireIntent(intentId);
        if (intent.status != IntentStatus.NEW && intent.status != IntentStatus.FILLING) {
            revert InvalidStatus(intent.status, IntentStatus.NEW);
        }

        address relayerAddress = _bytes32ToAddress(relayerBytes);
        if (relayerAddress == address(0)) revert InvalidPayload();

        if (intent.status == IntentStatus.FILLING) {
            if (intent.relayer != relayerAddress) revert NotRelayer();
        } else {
            if (!relayers[relayerAddress]) revert NotRelayer();
            intent.relayer = relayerAddress;
        }

        if (intent.receiver != receiver || intent.destinationToken != destinationToken) {
            intent.status = IntentStatus.FAILED;
            emit IntentFailed(intentId, "MISMATCH");
            return;
        }

        if (amountPaid < intent.destinationAmount) {
            intent.status = IntentStatus.FAILED;
            emit IntentFailed(intentId, "AMOUNT");
            return;
        }

        uint256 feeAmount = _calculateProtocolFee(intent.sourceAmount);
        uint256 relayerPayout = intent.sourceAmount - feeAmount;
        accumulatedFees[intent.sourceToken] += feeAmount;
        intent.status = IntentStatus.FILLED;

        IERC20(intent.sourceToken).safeTransfer(relayerAddress, relayerPayout);

        emit IntentFilled(intentId, relayerAddress, amountPaid);
    }

    function _calculateProtocolFee(uint256 amount) internal view returns (uint256) {
        return (amount * protocolFee) / BPS_DENOMINATOR;
    }

    function _routeKey(uint256 destinationChainId, address sourceToken, bytes32 destinationToken)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(destinationChainId, sourceToken, destinationToken));
    }

    function _addressToBytes32(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _bytes32ToAddress(bytes32 value) internal pure returns (address) {
        return address(uint160(uint256(value)));
    }

    function _requireIntent(bytes32 intentId) internal view returns (Intent storage) {
        Intent storage intent = _intents[intentId];
        if (intent.sender == address(0)) revert IntentNotFound();
        return intent;
    }
}
