// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAxelarGateway} from "../../src/interfaces/axelar/IAxelarGateway.sol";

contract MockAxelarGateway is IAxelarGateway {
    struct CallData {
        string destinationChain;
        string destinationAddress;
        bytes payload;
    }

    CallData public lastCall;
    mapping(bytes32 => bool) public approvals;

    function callContract(string calldata destinationChain, string calldata destinationAddress, bytes calldata payload)
        external
        override
    {
        lastCall = CallData(destinationChain, destinationAddress, payload);
    }

    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external view override returns (bool) {
        bytes32 key = keccak256(abi.encode(commandId, sourceChain, sourceAddress, payloadHash));
        return approvals[key];
    }

    function approve(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        bytes32 key = keccak256(abi.encode(commandId, sourceChain, sourceAddress, keccak256(payload)));
        approvals[key] = true;
    }
}
