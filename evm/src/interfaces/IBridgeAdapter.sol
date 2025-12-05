// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Generic bridge adapter interface used by SlowFill
interface IBridgeAdapter {
    function bridge(
        uint256 destinationChainId,
        bytes32 receiver,
        address sourceToken,
        bytes32 destinationToken,
        uint256 amount,
        address refundAddress
    ) external returns (bytes32 bridgeMessageId);
}
