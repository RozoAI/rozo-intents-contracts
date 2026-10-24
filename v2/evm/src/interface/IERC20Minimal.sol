// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

/**
 * @dev Minimal ERC-20 surface used by the forwarder. `transfer` is declared
 * here only for its selector; the forwarder never relies on its return value
 * through this interface (see MPForwarderV2._safeTransfer).
 */
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);
}
