// SPDX-License-Identifier: BSD-2-Clause
pragma solidity ^0.8.0;

/**
 * @dev Interface for USDT-style ERC-20 tokens that don't return bool on transfer.
 * USDT's transfer function doesn't follow the standard ERC-20 interface.
 */
interface USDTERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 value) external;

    function transferFrom(address from, address to, uint256 value) external;
}
