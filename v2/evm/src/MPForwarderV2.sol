// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

import { IERC20Minimal } from "./interface/IERC20Minimal.sol";

/**
 * @title MPForwarderV2
 * @notice Payment forwarder used as the EIP-1167 clone implementation ("parent")
 *         by MPForwarderFactoryV2. Funds sent to a clone can only ever leave
 *         towards `destination`; anyone may trigger a flush.
 *
 * @dev Based on v1/evm/src/MPForwarderV1.sol with two changes:
 *   1. ERC-20 flushes use a safe transfer wrapper: a `transfer` that returns
 *      `false` reverts (V1 silently treated it as success), tokens that return
 *      no data (USDT style) are accepted, and any revert bubbles up.
 *      `flushUSDT` is kept for ABI compatibility and shares the same path.
 *   2. Arc USDC is reachable through both of its interfaces with no extra code:
 *      the native 18-decimal balance is flushed with `flushETH`, the ERC-20
 *      6-decimal view at 0x3600000000000000000000000000000000000000 with
 *      `flushERC20`. Both move the same underlying balance; the backend must
 *      configure exactly one of them per chain.
 *
 * Security invariants (tested in test/):
 *   - `factory` is immutable and lives in the runtime code, so every clone
 *     delegating to this implementation sees the same factory.
 *   - `init` / `initAndFlush` are factory-only and succeed at most once.
 *   - `destination` can never be zero after initialisation and can never change.
 *   - Flushes are permissionless but always pay `destination`.
 */
contract MPForwarderV2 {
    address public immutable factory;
    address public destination;

    error OnlyFactory();
    error AlreadyInitialized();
    error InvalidDestination();
    error InvalidFactory();
    error FlushETHFailed();
    error TransferFailed();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    /**
     * @param _factory The factory that is allowed to initialise clones.
     * @param _destination Destination for the implementation itself (parent
     *        forwarder). Clones read their destination from here via the
     *        factory, so it must be non-zero.
     */
    constructor(address _factory, address _destination) {
        if (_factory == address(0)) revert InvalidFactory();
        if (_destination == address(0)) revert InvalidDestination();
        factory = _factory;
        destination = _destination;
    }

    /// @notice Initialise a clone. Factory-only, once.
    function init(address _destination) external onlyFactory {
        _init(_destination);
    }

    /// @notice Initialise a clone and flush one asset in the same transaction. Factory-only, once.
    function initAndFlush(address _destination, address _tokenAddress, bool _isUSDT) external onlyFactory {
        _init(_destination);
        _flush(_tokenAddress, _isUSDT);
    }

    receive() external payable { }

    // ============ Permissionless flushes: funds always go to `destination` ============

    function flushETH() external {
        _flushETH();
    }

    function flushERC20(address tokenContractAddress) external {
        _flushERC20(tokenContractAddress);
    }

    /// @dev Kept for ABI compatibility with V1 callers; same safe path as flushERC20.
    function flushUSDT(address tokenContractAddress) external {
        _flushERC20(tokenContractAddress);
    }

    // ============ Internal ============

    function _init(address _destination) internal {
        if (destination != address(0)) revert AlreadyInitialized();
        if (_destination == address(0)) revert InvalidDestination();
        destination = _destination;
    }

    function _flush(address tokenAddress, bool /* isUSDT */ ) internal {
        if (tokenAddress == address(0)) {
            _flushETH();
        } else {
            _flushERC20(tokenAddress);
        }
    }

    function _flushETH() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success,) = destination.call{ value: balance }("");
            if (!success) revert FlushETHFailed();
        }
    }

    function _flushERC20(address tokenContractAddress) internal {
        // High-level staticcall: reverts if `tokenContractAddress` has no code.
        uint256 balance = IERC20Minimal(tokenContractAddress).balanceOf(address(this));
        if (balance > 0) {
            _safeTransfer(tokenContractAddress, destination, balance);
        }
    }

    /**
     * @dev Safe ERC-20 transfer:
     *  - the call must not revert,
     *  - the token must have code (a call to an empty account "succeeds" with no data),
     *  - if data is returned it must decode to `true`; no data (USDT style) is accepted.
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok) revert TransferFailed();
        if (data.length != 0) {
            if (data.length < 32 || !abi.decode(data, (bool))) revert TransferFailed();
        }
    }
}
