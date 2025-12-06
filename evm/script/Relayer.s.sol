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
/// - RELAYER_ACTION: "fill", "fillAndNotify", or "slowFill"
/// - INTENT_ID: bytes32 intent identifier
/// Additional env vars per action:
/// - fillAndNotify: RECEIVER (address), TOKEN (address), DEST_AMOUNT (uint256), SOURCE_CHAIN_ID (uint256), NATIVE_GAS (uint256, optional)
/// - slowFill: none
contract RelayerScript is Script {
    function run() external {
        string memory action = vm.envString("RELAYER_ACTION");
        address contractAddress = vm.envAddress("ROZO_ADDRESS");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        bytes32 intentId = vm.envBytes32("INTENT_ID");

        vm.startBroadcast(privateKey);
        if (_eq(action, "fill")) {
            RozoIntents(contractAddress).fill(intentId);
        } else if (_eq(action, "fillAndNotify")) {
            _fillAndNotify(contractAddress, intentId);
        } else if (_eq(action, "slowFill")) {
            RozoIntents(contractAddress).slowFill(intentId);
        } else {
            revert("UNKNOWN_ACTION");
        }
        vm.stopBroadcast();
    }

    function _fillAndNotify(address contractAddress, bytes32 intentId) internal {
        address receiver = vm.envAddress("RECEIVER");
        address token = vm.envAddress("TOKEN");
        uint256 destinationAmount = vm.envUint("DEST_AMOUNT");
        uint256 sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        uint256 nativeGas = vm.envOr("NATIVE_GAS", uint256(0));

        bytes32 receiverBytes = bytes32(uint256(uint160(receiver)));
        RozoIntents rozo = RozoIntents(contractAddress);

        if (nativeGas > 0) {
            rozo.fillAndNotify{value: nativeGas}(intentId, receiverBytes, token, destinationAmount, sourceChainId);
        } else {
            rozo.fillAndNotify(intentId, receiverBytes, token, destinationAmount, sourceChainId);
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
