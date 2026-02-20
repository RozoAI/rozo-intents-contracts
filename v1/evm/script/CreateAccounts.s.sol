// SPDX-License-Identifier: BSD-2-Clause
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

/**
 * @title CreateAccounts
 * @notice Script to display and verify account configuration from environment
 * @dev Run with: forge script script/CreateAccounts.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
 */
contract CreateAccounts is Script {
    function run() external view {
        // Load Base accounts from environment
        address baseUser = vm.envAddress("BASE_USER_PUBLIC");
        address baseTreasure = vm.envAddress("BASE_TREASURE_PUBLIC");

        console.log("=== Base (EVM) Accounts ===");
        console.log("User Address:     ", baseUser);
        console.log("Treasure Address: ", baseTreasure);

        // Load Stellar accounts from environment
        string memory stellarUser = vm.envString("STELLAR_USER_PUBLIC");
        string memory stellarTreasure = vm.envString("STELLAR_TREASURE_PUBLIC");

        console.log("");
        console.log("=== Stellar Accounts ===");
        console.log("User Address:     ", stellarUser);
        console.log("Treasure Address: ", stellarTreasure);
    }
}
