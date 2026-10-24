// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

/**
 * @dev Constants for Nick Johnson's deterministic deployment proxy
 *      (https://github.com/Arachnid/deterministic-deployment-proxy).
 *      RUNTIME is the 69-byte code read from Ethereum mainnet with eth_getCode on 2026-10-25.
 */
library NicksFactory {
    address internal constant ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes internal constant RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function create2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), ADDRESS, salt, initCodeHash)))));
    }
}
