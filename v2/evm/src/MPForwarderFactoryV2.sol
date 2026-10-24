// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

import { MPForwarderV2 } from "./MPForwarderV2.sol";

/**
 * @title MPForwarderFactoryV2
 * @notice Ownerless, constructor-less factory for MPForwarderV2 parents and their
 *         EIP-1167 clones. Deployed on every EVM chain at the same address through
 *         Nick's deterministic deployment proxy (0x4e59b44847b379578588920cA78FbF26c0B4956C)
 *         with salt keccak256("rozo.forwarder.factory.v2"), so parents and clones
 *         derive to identical addresses on every chain.
 *
 * Address derivation (chain independent):
 *   parent = CREATE2(this, salt, keccak256(type(MPForwarderV2).creationCode ‖ abi.encode(this, destination)))
 *   clone  = CREATE2(this, salt, keccak256(0x3d602d80600a3d3981f3363d3d373d3d3d363d73 ‖ parent ‖ 0x5af43d82803e903d91602b57fd5bf3))
 *
 * Security invariants (tested in test/):
 *   - No owner, no admin, no upgrade path, holds no funds.
 *   - A clone can only be created for a parent this factory created (`isParent`),
 *     so its destination is always the parent's `destination()`; callers cannot
 *     choose it. A clone initialised by this factory always points at a non-zero
 *     destination because `createForwarder` rejects zero.
 *   - `cloneForwarderAndFlush` deploys, initialises and flushes in one transaction;
 *     any failure reverts the whole thing. If the clone already exists it only flushes.
 *   - Front-running `cloneForwarder` with our salt produces the same clone with the
 *     same destination; the funds still reach the hub.
 */
contract MPForwarderFactoryV2 {
    /// @dev Standard EIP-1167 minimal proxy creation code split around the 20-byte implementation.
    bytes private constant CLONE_PREFIX = hex"3d602d80600a3d3981f3363d3d373d3d3d363d73";
    bytes private constant CLONE_SUFFIX = hex"5af43d82803e903d91602b57fd5bf3";

    /// @notice Parents created by this factory. Only these may be cloned.
    mapping(address => bool) public isParent;

    event ForwarderCreated(address indexed forwarder, address indexed destination, uint256 salt);
    event CloneCreated(address indexed clone, address indexed parentForwarder, uint256 salt);

    error InvalidDestination();
    error UnknownParent();
    error AddressMismatch();
    error CloneDeployFailed();

    // ============ Parent forwarders ============

    /**
     * @notice Create (or return the existing) parent forwarder for `destination` / `salt`.
     * @dev Idempotent: if the deterministic address already has code it must be a parent
     *      we created (nobody else can deploy to that address) and it is returned as is.
     */
    function createForwarder(address destination, uint256 salt) external returns (address forwarder) {
        if (destination == address(0)) revert InvalidDestination();
        address predicted = getForwarderAddress(destination, salt);
        if (predicted.code.length != 0) {
            if (!isParent[predicted]) revert AddressMismatch();
            return predicted;
        }
        forwarder = address(new MPForwarderV2{ salt: bytes32(salt) }(address(this), destination));
        if (forwarder != predicted) revert AddressMismatch();
        isParent[forwarder] = true;
        emit ForwarderCreated(forwarder, destination, salt);
    }

    /// @notice Deterministic address of the parent forwarder for `destination` / `salt`.
    function getForwarderAddress(address destination, uint256 salt) public view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(MPForwarderV2).creationCode, abi.encode(address(this), destination)));
        return _create2Address(bytes32(salt), initCodeHash);
    }

    // ============ Clones ============

    /**
     * @notice Deploy and initialise the clone of `parent` for `salt`. Returns the existing
     *         clone if it was already deployed (e.g. front-run with the same salt).
     */
    function cloneForwarder(address parent, uint256 salt) external returns (address clone) {
        if (!isParent[parent]) revert UnknownParent();
        clone = getCloneAddress(parent, salt);
        if (clone.code.length != 0) return clone;
        _deployClone(parent, salt, clone);
        MPForwarderV2(payable(clone)).init(MPForwarderV2(payable(parent)).destination());
    }

    /**
     * @notice Deploy + initialise + flush in one transaction. If the clone already exists
     *         only the flush runs. `tokenAddress == address(0)` flushes the native asset.
     */
    function cloneForwarderAndFlush(address parent, uint256 salt, address tokenAddress, bool isUSDT)
        external
        returns (address clone)
    {
        if (!isParent[parent]) revert UnknownParent();
        clone = getCloneAddress(parent, salt);
        MPForwarderV2 c = MPForwarderV2(payable(clone));
        if (clone.code.length != 0) {
            if (tokenAddress == address(0)) {
                c.flushETH();
            } else if (isUSDT) {
                c.flushUSDT(tokenAddress);
            } else {
                c.flushERC20(tokenAddress);
            }
            return clone;
        }
        _deployClone(parent, salt, clone);
        c.initAndFlush(MPForwarderV2(payable(parent)).destination(), tokenAddress, isUSDT);
    }

    /// @notice Deterministic address of the clone of `parent` for `salt`.
    function getCloneAddress(address parent, uint256 salt) public view returns (address) {
        return _create2Address(bytes32(salt), keccak256(_cloneCreationCode(parent)));
    }

    // ============ Internal ============

    function _cloneCreationCode(address parent) internal pure returns (bytes memory) {
        return abi.encodePacked(CLONE_PREFIX, parent, CLONE_SUFFIX);
    }

    function _deployClone(address parent, uint256 salt, address predicted) internal {
        bytes memory code = _cloneCreationCode(parent);
        address clone;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            clone := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (clone == address(0)) revert CloneDeployFailed();
        if (clone != predicted) revert AddressMismatch();
        emit CloneCreated(clone, parent, salt);
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
