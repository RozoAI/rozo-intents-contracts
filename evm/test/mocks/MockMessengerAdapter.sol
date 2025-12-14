// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMessengerAdapter} from "../../src/interfaces/IMessengerAdapter.sol";

/// @title MockMessengerAdapter
/// @notice Mock implementation of messenger adapter for testing
contract MockMessengerAdapter is IMessengerAdapter {
    uint8 private immutable _messengerId;
    address public rozoIntents;
    mapping(uint256 => bytes32) private _trustedContracts;

    // For testing: store last sent message
    struct SentMessage {
        uint256 destinationChainId;
        bytes payload;
        bytes32 messageId;
    }
    SentMessage public lastSentMessage;

    // For testing: pending messages to be verified
    mapping(bytes32 => bytes) public pendingMessages;

    constructor(uint8 messengerId_, address rozoIntents_) {
        _messengerId = messengerId_;
        rozoIntents = rozoIntents_;
    }

    function setRozoIntents(address rozoIntents_) external {
        rozoIntents = rozoIntents_;
    }

    function setTrustedContract(uint256 chainId, bytes32 contractAddress) external {
        _trustedContracts[chainId] = contractAddress;
        emit TrustedContractSet(chainId, contractAddress);
    }

    function sendMessage(
        uint256 destinationChainId,
        bytes calldata payload
    ) external payable override returns (bytes32 messageId) {
        messageId = keccak256(abi.encode(destinationChainId, payload, block.timestamp));
        lastSentMessage = SentMessage({
            destinationChainId: destinationChainId,
            payload: payload,
            messageId: messageId
        });
        pendingMessages[messageId] = payload;
        emit MessageSent(destinationChainId, messageId, payload);
        return messageId;
    }

    function verifyMessage(
        uint256 sourceChainId,
        bytes calldata messageData
    ) external override returns (bytes memory payload) {
        // In mock, messageData is the raw payload directly
        // In production, this would verify signatures, check Axelar approval, etc.
        (bytes32 messageId, bytes memory innerPayload) = abi.decode(messageData, (bytes32, bytes));

        // Simple verification: just return the payload
        emit MessageVerified(sourceChainId, messageId);
        return innerPayload;
    }

    // Simplified verifyMessage for testing - directly returns messageData as payload
    function verifyMessageDirect(
        uint256 sourceChainId,
        bytes calldata messageData
    ) external returns (bytes memory) {
        bytes32 messageId = keccak256(messageData);
        emit MessageVerified(sourceChainId, messageId);
        return messageData;
    }

    function messengerId() external view override returns (uint8) {
        return _messengerId;
    }

    function trustedContracts(uint256 chainId) external view override returns (bytes32) {
        return _trustedContracts[chainId];
    }

    // Helper to simulate receiving a notification
    function simulateNotify(
        address target,
        uint256 sourceChainId,
        bytes calldata payload
    ) external {
        // Encode the message data in a way that verifyMessage expects
        bytes32 messageId = keccak256(payload);
        bytes memory messageData = abi.encode(messageId, payload);

        // Call notify on target
        (bool success,) = target.call(
            abi.encodeWithSignature(
                "notify(uint8,uint256,bytes)",
                _messengerId,
                sourceChainId,
                messageData
            )
        );
        require(success, "notify failed");
    }
}
