// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

import { Test } from "forge-std/Test.sol";
import { DeployV2 } from "../script/DeployV2.s.sol";
import { MPForwarderFactoryV2 } from "../src/MPForwarderFactoryV2.sol";
import { MPForwarderV2 } from "../src/MPForwarderV2.sol";
import { NicksFactory } from "./helpers/NicksFactory.sol";

contract DeployV2Test is Test {
    DeployV2 internal s;

    function setUp() public {
        s = new DeployV2();
    }

    function _etchNick() internal {
        vm.etch(NicksFactory.ADDRESS, NicksFactory.RUNTIME);
    }

    // ============ Allowlist ============

    function test_BroadcastAllowlist_TestnetsOnly() public view {
        assertTrue(s.isBroadcastAllowed(84532));
        assertTrue(s.isBroadcastAllowed(5042002));
        assertTrue(s.isBroadcastAllowed(11142220));
        uint256[9] memory mainnets = [uint256(1), 8453, 56, 42161, 137, 999, 480, 5042, 42220];
        for (uint256 i; i < mainnets.length; i++) {
            assertFalse(s.isBroadcastAllowed(mainnets[i]), "mainnet must not be broadcastable in this phase");
        }
        assertFalse(s.isBroadcastAllowed(11155111)); // Ethereum Sepolia is not a target either
        assertFalse(s.isBroadcastAllowed(31337));
    }

    // ============ Nick's factory checks ============

    function test_VerifyNick_MissingReverts() public {
        // Foundry pre-deploys the CREATE2 proxy in test environments; remove it first.
        vm.etch(NicksFactory.ADDRESS, "");
        vm.expectRevert(DeployV2.NicksFactoryMissing.selector);
        s.verifyNicksFactory();
    }

    function test_VerifyNick_ForeignRuntimeReverts() public {
        vm.etch(NicksFactory.ADDRESS, hex"6000600055"); // some other code at the proxy address
        vm.expectRevert(DeployV2.NicksFactoryRuntimeMismatch.selector);
        s.verifyNicksFactory();
        vm.expectRevert(DeployV2.NicksFactoryRuntimeMismatch.selector);
        s.deployOrVerifyFactory();
    }

    function test_VerifyNick_OneByteDifferenceReverts() public {
        bytes memory tampered = NicksFactory.RUNTIME;
        tampered[tampered.length - 1] = 0xfd; // f3 (RETURN) -> fd (REVERT)
        vm.etch(NicksFactory.ADDRESS, tampered);
        vm.expectRevert(DeployV2.NicksFactoryRuntimeMismatch.selector);
        s.verifyNicksFactory();
    }

    // ============ Factory deploy / idempotency / foreign code ============

    function test_Deploy_FactoryLandsAtPredictedAddress() public {
        _etchNick();
        (address f2, bool deployed) = s.deployOrVerifyFactory();
        assertTrue(deployed);
        assertEq(f2, s.predictFactory());
        assertEq(keccak256(f2.code), s.factoryRuntimeHash());
        assertEq(keccak256(f2.code), keccak256(type(MPForwarderFactoryV2).runtimeCode));
    }

    function test_Deploy_SecondRunIsIdempotentSkip() public {
        _etchNick();
        (address a,) = s.deployOrVerifyFactory();
        (address b, bool deployed) = s.deployOrVerifyFactory();
        assertEq(a, b);
        assertFalse(deployed, "already deployed with matching hash => skip");
    }

    function test_Deploy_ForeignCodeAtF2Reverts() public {
        _etchNick();
        address f2 = s.predictFactory();
        vm.etch(f2, hex"60006000fd"); // wrong code sitting at our address
        vm.expectRevert(abi.encodeWithSelector(DeployV2.ForeignCodeAtFactoryAddress.selector, f2));
        s.deployOrVerifyFactory();
    }

    function test_Deploy_TamperedFactoryCodeAtF2Reverts() public {
        _etchNick();
        address f2 = s.predictFactory();
        bytes memory rt = type(MPForwarderFactoryV2).runtimeCode;
        rt[10] = bytes1(uint8(rt[10]) ^ 0x01);
        vm.etch(f2, rt);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.ForeignCodeAtFactoryAddress.selector, f2));
        s.deployOrVerifyFactory();
    }

    // ============ Parent ============

    function test_Parent_CreatedAtPredictedAddressAndVerified() public {
        _etchNick();
        (address f2,) = s.deployOrVerifyFactory();
        bytes32 rt = s.expectedParentRuntimeHash(f2);
        (address p2, bool created) = s.createOrVerifyParent(f2, rt);
        assertTrue(created);
        assertEq(p2, s.predictParent(f2));
        assertEq(p2, MPForwarderFactoryV2(f2).getForwarderAddress(s.HUB(), 0));
        assertEq(MPForwarderV2(payable(p2)).factory(), f2);
        assertEq(MPForwarderV2(payable(p2)).destination(), s.HUB());
        assertEq(keccak256(p2.code), rt);
        (, bool createdAgain) = s.createOrVerifyParent(f2, rt);
        assertFalse(createdAgain);
    }

    function test_Parent_WrongRuntimeExpectationReverts() public {
        _etchNick();
        (address f2,) = s.deployOrVerifyFactory();
        bytes32 rt = s.expectedParentRuntimeHash(f2);
        address p2 = s.predictParent(f2);
        s.createOrVerifyParent(f2, rt);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.ParentRuntimeMismatch.selector, p2));
        s.verifyParent(f2, p2, bytes32(uint256(1)));
    }

    function test_Parent_DestinationIsProductionHub() public view {
        assertEq(s.HUB(), 0x05c84533299625Df3Ace2215742124C1644E2705);
        assertEq(s.P2_SALT(), 0);
    }

    // ============ Arc fee floor ============

    function test_ArcFee_NotArcIsNoop() public view {
        s.requireArcFee(84532);
    }

    function test_ArcFee_BelowFloorReverts() public {
        vm.txGasPrice(10 gwei);
        vm.fee(1 gwei);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.GasPriceTooLow.selector, 10 gwei, 25 gwei));
        s.requireArcFee(5042002);
    }

    function test_ArcFee_BelowBaseFeeReverts() public {
        vm.txGasPrice(30 gwei);
        vm.fee(40 gwei);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.GasPriceTooLow.selector, 30 gwei, 40 gwei));
        s.requireArcFee(5042);
    }

    function test_ArcFee_AtFloorPasses() public {
        vm.txGasPrice(25 gwei);
        vm.fee(20 gwei);
        s.requireArcFee(5042002);
    }

    // ============ Salt ============

    function test_SaltIsKeccakOfLabel() public view {
        assertEq(s.SALT_F2(), keccak256("rozo.forwarder.factory.v2"));
    }
}
