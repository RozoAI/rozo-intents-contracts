// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";

contract MockBridgeAdapter is IBridgeAdapter {
    struct BridgeCall {
        uint256 destinationChainId;
        bytes32 receiver;
        address sourceToken;
        bytes32 destinationToken;
        uint256 amount;
        address refundAddress;
    }

    BridgeCall public lastCall;
    bool public shouldRevert;
    bytes32 public nextMessageId;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setNextMessageId(bytes32 messageId) external {
        nextMessageId = messageId;
    }

    function bridge(
        uint256 destinationChainId,
        bytes32 receiver,
        address sourceToken,
        bytes32 destinationToken,
        uint256 amount,
        address refundAddress
    ) external override returns (bytes32 bridgeMessageId) {
        if (shouldRevert) {
            revert("BRIDGE_REVERT");
        }
        lastCall = BridgeCall(destinationChainId, receiver, sourceToken, destinationToken, amount, refundAddress);
        return nextMessageId;
    }
}
