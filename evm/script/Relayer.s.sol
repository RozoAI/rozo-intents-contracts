// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/RozoIntents.sol";

/// @notice Simple Foundry script that can act as a relayer for RozoIntents
/// @dev Configure env vars then run:
/// forge script script/Relayer.s.sol:RelayerScript --rpc-url $RPC --broadcast --slow
/// Required env vars:
/// - PRIVATE_KEY: relayer key on the current chain
/// - ROZO_ADDRESS: RozoIntents contract on current chain
/// - RELAYER_ACTION: "fillAndNotify" or "retryNotify"
///
/// For fillAndNotify:
/// - INTENT_ID, SENDER, REFUND_ADDRESS, SOURCE_TOKEN, SOURCE_AMOUNT
/// - SOURCE_CHAIN_ID, DEST_CHAIN_ID, DEST_TOKEN, RECEIVER, DEST_AMOUNT
/// - DEADLINE, CREATED_AT, RELAYER (all as bytes32/uint types)
/// - REPAYMENT_ADDRESS: bytes32 - where to receive payment on source chain
/// - MESSENGER_ID: uint8 - 0=Rozo, 1=Axelar
/// - NATIVE_GAS: uint256 (optional) - ETH to send for messenger fees
contract RelayerScript is Script {
    function run() external {
        string memory action = vm.envString("RELAYER_ACTION");
        address contractAddress = vm.envAddress("ROZO_ADDRESS");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        if (_eq(action, "fillAndNotify")) {
            _fillAndNotify(contractAddress);
        } else if (_eq(action, "retryNotify")) {
            _retryNotify(contractAddress);
        } else {
            revert("UNKNOWN_ACTION: use fillAndNotify or retryNotify");
        }
        vm.stopBroadcast();
    }

    function _fillAndNotify(address contractAddress) internal {
        IntentData memory intentData = _buildIntentData();
        bytes32 repaymentAddress = vm.envBytes32("REPAYMENT_ADDRESS");
        uint8 messengerId = uint8(vm.envUint("MESSENGER_ID"));
        uint256 nativeGas = vm.envOr("NATIVE_GAS", uint256(0));

        RozoIntents rozo = RozoIntents(contractAddress);
        rozo.fillAndNotify{value: nativeGas}(intentData, repaymentAddress, messengerId);
    }

    function _retryNotify(address contractAddress) internal {
        IntentData memory intentData = _buildIntentData();
        uint8 messengerId = uint8(vm.envUint("MESSENGER_ID"));
        uint256 nativeGas = vm.envOr("NATIVE_GAS", uint256(0));

        RozoIntents rozo = RozoIntents(contractAddress);
        rozo.retryNotify{value: nativeGas}(intentData, messengerId);
    }

    function _buildIntentData() internal view returns (IntentData memory) {
        return IntentData({
            intentId: vm.envBytes32("INTENT_ID"),
            sender: vm.envBytes32("SENDER"),
            refundAddress: vm.envBytes32("REFUND_ADDRESS"),
            sourceToken: vm.envBytes32("SOURCE_TOKEN"),
            sourceAmount: vm.envUint("SOURCE_AMOUNT"),
            sourceChainId: vm.envUint("SOURCE_CHAIN_ID"),
            destinationChainId: vm.envUint("DEST_CHAIN_ID"),
            destinationToken: vm.envBytes32("DEST_TOKEN"),
            receiver: vm.envBytes32("RECEIVER"),
            destinationAmount: vm.envUint("DEST_AMOUNT"),
            deadline: uint64(vm.envUint("DEADLINE")),
            createdAt: uint64(vm.envUint("CREATED_AT")),
            relayer: vm.envBytes32("RELAYER")
        });
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
