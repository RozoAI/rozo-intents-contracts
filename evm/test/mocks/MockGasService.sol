// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAxelarGasService} from "../../src/interfaces/axelar/IAxelarGateway.sol";

contract MockGasService is IAxelarGasService {
    event GasPaid(
        address indexed source,
        string destinationChain,
        string destinationAddress,
        bytes payload,
        address refundAddress,
        uint256 value
    );

    function payNativeGasForContractCall(
        address sourceAddress,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable override {
        emit GasPaid(sourceAddress, destinationChain, destinationAddress, payload, refundAddress, msg.value);
    }
}
