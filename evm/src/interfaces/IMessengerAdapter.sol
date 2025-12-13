// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Messenger Adapter Interface
/// @notice Standard interface for cross-chain messenger adapters (Rozo, Axelar, etc.)
interface IMessengerAdapter {
    // ============ Errors ============

    /// @notice Thrown when message source is not a trusted contract
    error UntrustedSource();

    /// @notice Thrown when message is not approved by the underlying protocol (Axelar)
    error NotApproved();

    /// @notice Thrown when signature verification fails (Rozo)
    error InvalidSignature();

    /// @notice Thrown when chain ID is not supported
    error InvalidChainId();

    /// @notice Thrown when caller is not the RozoIntents contract
    error NotRozoIntents();

    // ============ Events ============

    /// @notice Emitted when a message is sent
    event MessageSent(
        uint256 indexed destinationChainId,
        bytes32 indexed messageId,
        bytes payload
    );

    /// @notice Emitted when a message is verified
    event MessageVerified(
        uint256 indexed sourceChainId,
        bytes32 indexed messageId
    );

    /// @notice Emitted when trusted contract is set
    event TrustedContractSet(uint256 indexed chainId, bytes32 contractAddress);

    // ============ Core Functions ============

    /// @notice Send a cross-chain message
    /// @param destinationChainId Target chain ID
    /// @param payload Encoded message payload
    /// @return messageId Unique identifier for tracking the message
    function sendMessage(
        uint256 destinationChainId,
        bytes calldata payload
    ) external payable returns (bytes32 messageId);

    /// @notice Verify and decode a received cross-chain message
    /// @param sourceChainId Chain where message originated
    /// @param messageData Raw message data from the messenger protocol
    /// @return payload Decoded and verified payload
    function verifyMessage(
        uint256 sourceChainId,
        bytes calldata messageData
    ) external returns (bytes memory payload);

    // ============ View Functions ============

    /// @notice Get the messenger ID (0=Rozo, 1=Axelar)
    /// @return Messenger identifier
    function messengerId() external pure returns (uint8);

    /// @notice Get the trusted contract address for a chain
    /// @param chainId Chain ID to query
    /// @return Trusted contract address (bytes32 for cross-chain compatibility)
    function trustedContracts(uint256 chainId) external view returns (bytes32);

    /// @notice Get the RozoIntents contract address
    /// @return RozoIntents contract address
    function rozoIntents() external view returns (address);
}
