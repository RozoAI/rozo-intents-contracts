// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockAxelarGasService
/// @notice Mock Axelar Gas Service for testing
contract MockAxelarGasService {
    // Track gas payments
    struct GasPayment {
        address sender;
        string destinationChain;
        string destinationAddress;
        bytes payload;
        address refundAddress;
        uint256 value;
    }
    GasPayment[] public gasPayments;

    function payNativeGasForContractCall(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable {
        gasPayments.push(GasPayment(
            sender,
            destinationChain,
            destinationAddress,
            payload,
            refundAddress,
            msg.value
        ));
    }

    function payNativeGasForContractCallWithToken(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        string calldata,
        uint256,
        address refundAddress
    ) external payable {
        gasPayments.push(GasPayment(
            sender,
            destinationChain,
            destinationAddress,
            payload,
            refundAddress,
            msg.value
        ));
    }

    // Helper to get payment count
    function getPaymentCount() external view returns (uint256) {
        return gasPayments.length;
    }

    // Helper to get payment
    function getPayment(uint256 index) external view returns (
        address sender,
        string memory destinationChain,
        string memory destinationAddress,
        bytes memory payload,
        address refundAddress,
        uint256 value
    ) {
        GasPayment storage p = gasPayments[index];
        return (p.sender, p.destinationChain, p.destinationAddress, p.payload, p.refundAddress, p.value);
    }
}
