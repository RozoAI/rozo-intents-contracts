// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAxelarGateway} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";

/// @title MockAxelarGateway
/// @notice Mock Axelar Gateway for testing
contract MockAxelarGateway {
    // Track commands that have been validated
    mapping(bytes32 => bool) public validatedCalls;

    // Track messages sent
    struct Message {
        string destinationChain;
        string contractAddress;
        bytes payload;
    }
    Message[] public messages;

    // For testing - allow setting command validation
    function setValidated(bytes32 commandId, bool validated) external {
        validatedCalls[commandId] = validated;
    }

    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        external
    {
        messages.push(Message(destinationChain, contractAddress, payload));
    }

    function validateContractCall(
        bytes32 commandId,
        string calldata, /* sourceChain */
        string calldata, /* sourceAddress */
        bytes32 /* payloadHash */
    )
        external
        view
        returns (bool)
    {
        return validatedCalls[commandId];
    }

    // Helper to get message count
    function getMessageCount() external view returns (uint256) {
        return messages.length;
    }

    // Helper to get message
    function getMessage(uint256 index)
        external
        view
        returns (string memory destinationChain, string memory contractAddress, bytes memory payload)
    {
        Message storage m = messages[index];
        return (m.destinationChain, m.contractAddress, m.payload);
    }

    // Required interface methods (stub implementations)
    function sendToken(string calldata, string calldata, string calldata, uint256) external pure {}

    function tokenAddresses(string calldata) external pure returns (address) {
        return address(0);
    }

    // Accept ETH for impersonation in tests
    receive() external payable {}
}
