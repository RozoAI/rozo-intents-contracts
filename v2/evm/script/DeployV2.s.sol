// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { MPForwarderFactoryV2 } from "../src/MPForwarderFactoryV2.sol";
import { MPForwarderV2 } from "../src/MPForwarderV2.sol";

/**
 * @title DeployV2
 * @notice Deploys MPForwarderFactoryV2 (F2) through Nick's deterministic deployment proxy and
 *         creates the production parent forwarder P2 = F2.createForwarder(HUB, 0).
 *
 * Guarantees enforced in code (not by the operator):
 *   - Nick's factory at 0x4e59… must hold the exact 69-byte runtime read from Ethereum mainnet.
 *   - F2 is asserted against CREATE2(0x4e59…, SALT_F2, keccak256(creationCode)) before and after.
 *   - Idempotent: an address that already holds the expected runtime is skipped; an address that
 *     holds any other code aborts the run (never deploy "next to" foreign code).
 *   - Broadcast allowlist: the chain id is read from the RPC and only 84532 / 5042002 / 11142220
 *     may be broadcast to in this (testnet) phase. Any other chain can only be queried / estimated.
 *   - Arc fee floor: on Arc chains a broadcast requires the effective gas price to be >= 25 gwei
 *     and >= the current base fee (pass --legacy --with-gas-price, or --with-gas-price plus
 *     --priority-gas-price; never both styles on one transaction).
 *   - The deployer key is read only from DEPLOYER_PRIVATE_KEY and is never logged.
 */
contract DeployV2 is Script {
    address public constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev eth_getCode(0x4e59…, latest) on Ethereum mainnet, 2026-10-25. 69 bytes.
    bytes public constant NICKS_FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    bytes32 public constant SALT_F2 = keccak256("rozo.forwarder.factory.v2");
    address public constant HUB = 0x05c84533299625Df3Ace2215742124C1644E2705;
    uint256 public constant P2_SALT = 0;

    uint256 public constant ARC_MAINNET = 5042;
    uint256 public constant ARC_TESTNET = 5042002;
    uint256 public constant ARC_MIN_GAS_PRICE = 25 gwei;

    error ChainIdMismatch(uint256 rpc, uint256 evm);
    error BroadcastNotAllowed(uint256 chainId);
    error NicksFactoryMissing();
    error NicksFactoryRuntimeMismatch();
    error ForeignCodeAtFactoryAddress(address f2);
    error FactoryAddressMismatch(address expected, address actual);
    error FactoryRuntimeMismatch();
    error ParentAddressMismatch(address expected, address actual);
    error ParentNotRegistered(address p2);
    error ParentFactoryMismatch(address p2);
    error ParentDestinationMismatch(address p2);
    error ParentRuntimeMismatch(address p2);
    error GasPriceTooLow(uint256 gasPrice, uint256 required);
    error MissingDeployerKey();

    // ============ Pure helpers (also used by tests) ============

    /// @notice Testnet-phase broadcast allowlist. Mainnet chain ids are deliberately absent.
    function isBroadcastAllowed(uint256 chainId) public pure returns (bool) {
        return chainId == 84532 || chainId == ARC_TESTNET || chainId == 11142220;
    }

    function isArc(uint256 chainId) public pure returns (bool) {
        return chainId == ARC_MAINNET || chainId == ARC_TESTNET;
    }

    function factoryCreationCode() public pure returns (bytes memory) {
        return type(MPForwarderFactoryV2).creationCode;
    }

    function factoryCreationCodeHash() public pure returns (bytes32) {
        return keccak256(type(MPForwarderFactoryV2).creationCode);
    }

    function factoryRuntimeHash() public pure returns (bytes32) {
        return keccak256(type(MPForwarderFactoryV2).runtimeCode);
    }

    /// @notice Predicted F2 = CREATE2(Nick's factory, SALT_F2, keccak256(creationCode)).
    function predictFactory() public pure returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), NICKS_FACTORY, SALT_F2, factoryCreationCodeHash())))
            )
        );
    }

    /// @notice Predicted P2 for a given F2 (same formula as MPForwarderFactoryV2.getForwarderAddress).
    function predictParent(address f2) public pure returns (address) {
        bytes32 h = keccak256(abi.encodePacked(type(MPForwarderV2).creationCode, abi.encode(f2, HUB)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), f2, bytes32(P2_SALT), h)))));
    }

    /// @notice Expected runtime hash of P2: MPForwarderV2 with immutable `factory` = f2.
    function expectedParentRuntimeHash(address f2) public returns (bytes32) {
        // Reference instance deployed in simulation only (never inside a broadcast window).
        MPForwarderV2 ref = new MPForwarderV2(f2, HUB);
        return keccak256(address(ref).code);
    }

    // ============ Checks ============

    function verifyNicksFactory() public view {
        bytes memory code = NICKS_FACTORY.code;
        if (code.length == 0) revert NicksFactoryMissing();
        if (keccak256(code) != keccak256(NICKS_FACTORY_RUNTIME)) revert NicksFactoryRuntimeMismatch();
    }

    /// @dev Reads eth_chainId from the RPC and checks it against the EVM view.
    function rpcChainId() public returns (uint256 id) {
        bytes memory raw = vm.rpc("eth_chainId", "[]");
        for (uint256 i; i < raw.length; i++) {
            id = (id << 8) | uint8(raw[i]);
        }
        if (id != block.chainid) revert ChainIdMismatch(id, block.chainid);
    }

    function requireArcFee(uint256 chainId) public view {
        if (!isArc(chainId)) return;
        uint256 required = ARC_MIN_GAS_PRICE > block.basefee ? ARC_MIN_GAS_PRICE : block.basefee;
        if (tx.gasprice < required) revert GasPriceTooLow(tx.gasprice, required);
    }

    // ============ Deploy / verify (callable with or without an active broadcast) ============

    /// @notice Deploys F2 through Nick's factory, or verifies the existing deployment. Returns F2.
    function deployOrVerifyFactory() public returns (address f2, bool deployed) {
        verifyNicksFactory();
        f2 = predictFactory();
        bytes32 rt = factoryRuntimeHash();
        if (f2.code.length != 0) {
            if (keccak256(f2.code) != rt) revert ForeignCodeAtFactoryAddress(f2);
            return (f2, false);
        }
        (bool ok, bytes memory ret) = NICKS_FACTORY.call(abi.encodePacked(SALT_F2, factoryCreationCode()));
        if (!ok || ret.length != 20) revert FactoryAddressMismatch(f2, address(0));
        address actual = address(bytes20(ret));
        if (actual != f2) revert FactoryAddressMismatch(f2, actual);
        if (keccak256(f2.code) != rt) revert FactoryRuntimeMismatch();
        deployed = true;
    }

    /// @notice Creates P2 = F2.createForwarder(HUB, 0), or verifies the existing one. Returns P2.
    function createOrVerifyParent(address f2, bytes32 expectedRuntime) public returns (address p2, bool created) {
        MPForwarderFactoryV2 factory = MPForwarderFactoryV2(f2);
        p2 = predictParent(f2);
        if (factory.getForwarderAddress(HUB, P2_SALT) != p2) revert ParentAddressMismatch(p2, factory.getForwarderAddress(HUB, P2_SALT));
        if (p2.code.length == 0) {
            address actual = factory.createForwarder(HUB, P2_SALT);
            if (actual != p2) revert ParentAddressMismatch(p2, actual);
            created = true;
        }
        verifyParent(f2, p2, expectedRuntime);
    }

    function verifyParent(address f2, address p2, bytes32 expectedRuntime) public view {
        if (!MPForwarderFactoryV2(f2).isParent(p2)) revert ParentNotRegistered(p2);
        MPForwarderV2 fwd = MPForwarderV2(payable(p2));
        if (fwd.factory() != f2) revert ParentFactoryMismatch(p2);
        if (fwd.destination() != HUB) revert ParentDestinationMismatch(p2);
        if (keccak256(p2.code) != expectedRuntime) revert ParentRuntimeMismatch(p2);
    }

    // ============ Entry point ============

    function run() external {
        uint256 chainId = rpcChainId();
        bool broadcasting = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        if (broadcasting && !isBroadcastAllowed(chainId)) revert BroadcastNotAllowed(chainId);

        verifyNicksFactory();
        address f2 = predictFactory();
        address p2 = predictParent(f2);
        bytes32 p2Runtime = expectedParentRuntimeHash(f2);

        console2.log("chainId                     ", chainId);
        console2.log("broadcast                   ", broadcasting);
        console2.log("Nick's factory runtime ok    ", true);
        console2.log("F2 (predicted)              ", f2);
        console2.log("P2 (predicted)              ", p2);
        console2.logBytes32(factoryCreationCodeHash());
        console2.logBytes32(factoryRuntimeHash());
        console2.log("F2 code on chain (bytes)    ", f2.code.length);
        console2.log("P2 code on chain (bytes)    ", p2.code.length);
        console2.log("basefee (wei)               ", block.basefee);
        console2.log("tx.gasprice (wei)           ", tx.gasprice);

        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (broadcasting) {
            if (pk == 0) revert MissingDeployerKey();
            requireArcFee(chainId);
            vm.startBroadcast(pk);
        } else if (pk != 0) {
            // Dry run with the real sender so gas estimates match the broadcast.
            vm.startBroadcast(pk);
        }

        (, bool deployed) = deployOrVerifyFactory();
        (, bool created) = createOrVerifyParent(f2, p2Runtime);

        if (broadcasting || pk != 0) vm.stopBroadcast();

        console2.log("F2 deployed this run        ", deployed);
        console2.log("P2 created this run         ", created);
        console2.log("F2 runtime hash matches     ", keccak256(f2.code) == factoryRuntimeHash());
        console2.log("P2 runtime hash matches     ", keccak256(p2.code) == p2Runtime);
    }
}
