// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

import { Test } from "forge-std/Test.sol";
import { MPForwarderFactoryV2 } from "../src/MPForwarderFactoryV2.sol";
import { MPForwarderV2 } from "../src/MPForwarderV2.sol";
import { NicksFactory } from "./helpers/NicksFactory.sol";
import {
    MockERC20,
    MockERC20NoReturn,
    MockERC20ReturnsFalse,
    MockERC20Reverts,
    MockERC20ShortReturn,
    RejectingReceiver,
    MaliciousParent
} from "./helpers/Mocks.sol";

contract MPForwarderFactoryV2Test is Test {
    bytes32 internal constant SALT_F2 = keccak256("rozo.forwarder.factory.v2");
    address internal constant HUB = 0x05c84533299625Df3Ace2215742124C1644E2705;

    MPForwarderFactoryV2 internal factory;
    MPForwarderV2 internal parent; // P2: destination = HUB, salt 0
    address internal attacker = makeAddr("attacker");
    address internal relayer = makeAddr("relayer");

    event ForwarderCreated(address indexed forwarder, address indexed destination, uint256 salt);
    event CloneCreated(address indexed clone, address indexed parentForwarder, uint256 salt);

    function setUp() public {
        // Put Nick's factory where it lives on every chain and deploy F2 through it,
        // exactly like script/DeployV2.s.sol does.
        vm.etch(NicksFactory.ADDRESS, NicksFactory.RUNTIME);
        bytes memory initcode = type(MPForwarderFactoryV2).creationCode;
        (bool ok, bytes memory ret) = NicksFactory.ADDRESS.call(abi.encodePacked(SALT_F2, initcode));
        require(ok, "nick call failed");
        factory = MPForwarderFactoryV2(address(bytes20(ret)));
        parent = MPForwarderV2(payable(factory.createForwarder(HUB, 0)));
    }

    // ============ Factory deployment / addressing ============

    function test_FactoryAddressMatchesCreate2ThroughNick() public view {
        bytes32 h = keccak256(type(MPForwarderFactoryV2).creationCode);
        assertEq(address(factory), NicksFactory.create2Address(SALT_F2, h));
        assertEq(keccak256(address(factory).code), keccak256(type(MPForwarderFactoryV2).runtimeCode));
    }

    function test_FactoryHasNoOwnerSelector() public view {
        // owner() = 0x8da5cb5b, transferOwnership(address) = 0xf2fde38b
        bytes memory code = address(factory).code;
        assertFalse(_contains(code, hex"8da5cb5b"));
        assertFalse(_contains(code, hex"f2fde38b"));
    }

    function test_NickRuntimeIs69Bytes() public pure {
        assertEq(NicksFactory.RUNTIME.length, 69);
    }

    // ============ Parent forwarder ============

    function test_CreateForwarder_RejectsZeroDestination() public {
        vm.expectRevert(MPForwarderFactoryV2.InvalidDestination.selector);
        factory.createForwarder(address(0), 1);
    }

    function test_CreateForwarder_MatchesCreate2Formula() public view {
        bytes32 h = keccak256(abi.encodePacked(type(MPForwarderV2).creationCode, abi.encode(address(factory), HUB)));
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(0), h)))));
        assertEq(factory.getForwarderAddress(HUB, 0), expected);
        assertEq(address(parent), expected);
        assertTrue(factory.isParent(address(parent)));
        assertEq(parent.factory(), address(factory));
        assertEq(parent.destination(), HUB);
    }

    function testFuzz_GetForwarderAddress_MatchesFormula(address dest, uint256 salt) public view {
        bytes32 h = keccak256(abi.encodePacked(type(MPForwarderV2).creationCode, abi.encode(address(factory), dest)));
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(salt), h)))));
        assertEq(factory.getForwarderAddress(dest, salt), expected);
    }

    function test_CreateForwarder_Idempotent() public {
        vm.recordLogs();
        address again = factory.createForwarder(HUB, 0);
        assertEq(again, address(parent));
        assertEq(vm.getRecordedLogs().length, 0, "no event on repeat");
    }

    function test_CreateForwarder_DifferentSaltDifferentAddress() public {
        address other = factory.createForwarder(HUB, 1);
        assertTrue(other != address(parent));
        assertTrue(factory.isParent(other));
    }

    function test_CreateForwarder_EmitsEvent() public {
        address predicted = factory.getForwarderAddress(relayer, 7);
        vm.expectEmit(true, true, false, true);
        emit ForwarderCreated(predicted, relayer, 7);
        factory.createForwarder(relayer, 7);
    }

    // ============ Clone addressing ============

    function test_GetCloneAddress_Matches55ByteCloneCode() public {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", address(parent), hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(code.length, 55);
        uint256 salt = uint256(sha256("payment_1700000000"));
        address expected = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(salt), keccak256(code)))))
        );
        assertEq(factory.getCloneAddress(address(parent), salt), expected);
        address clone = factory.cloneForwarder(address(parent), salt);
        assertEq(clone, expected);
        assertEq(clone.code.length, 45, "EIP-1167 runtime is 45 bytes");
    }

    function testFuzz_GetCloneAddress_MatchesFormula(address p, uint256 salt) public view {
        bytes memory code =
            abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", p, hex"5af43d82803e903d91602b57fd5bf3");
        address expected = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(salt), keccak256(code)))))
        );
        assertEq(factory.getCloneAddress(p, salt), expected);
    }

    // ============ cloneForwarder ============

    function test_CloneForwarder_DestinationComesFromParent() public {
        address clone = factory.cloneForwarder(address(parent), 42);
        MPForwarderV2 c = MPForwarderV2(payable(clone));
        assertEq(c.destination(), HUB);
        assertEq(c.factory(), address(factory));
    }

    function test_CloneForwarder_EmitsEvent() public {
        address predicted = factory.getCloneAddress(address(parent), 42);
        vm.expectEmit(true, true, false, true);
        emit CloneCreated(predicted, address(parent), 42);
        factory.cloneForwarder(address(parent), 42);
    }

    function test_CloneForwarder_IdempotentReturnsExisting() public {
        address a = factory.cloneForwarder(address(parent), 42);
        vm.recordLogs();
        address b = factory.cloneForwarder(address(parent), 42);
        assertEq(a, b);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_CloneForwarder_RejectsMaliciousParent() public {
        MaliciousParent evil = new MaliciousParent(address(factory), attacker);
        vm.expectRevert(MPForwarderFactoryV2.UnknownParent.selector);
        factory.cloneForwarder(address(evil), 42);
        vm.expectRevert(MPForwarderFactoryV2.UnknownParent.selector);
        factory.cloneForwarderAndFlush(address(evil), 42, address(0), false);
    }

    function test_CloneForwarder_RejectsForeignParentWithSameCode() public {
        // A real MPForwarderV2 deployed by someone else (not through createForwarder) is still not a parent.
        MPForwarderV2 foreign = new MPForwarderV2(address(factory), attacker);
        vm.expectRevert(MPForwarderFactoryV2.UnknownParent.selector);
        factory.cloneForwarder(address(foreign), 42);
    }

    function test_CloneForwarder_RejectsEOAParent() public {
        vm.expectRevert(MPForwarderFactoryV2.UnknownParent.selector);
        factory.cloneForwarder(attacker, 42);
    }

    // ============ cloneForwarderAndFlush paths ============

    function test_CloneAndFlush_ETH() public {
        address clone = factory.getCloneAddress(address(parent), 1);
        vm.deal(clone, 1 ether);
        uint256 before = HUB.balance;
        vm.prank(relayer);
        factory.cloneForwarderAndFlush(address(parent), 1, address(0), false);
        assertEq(HUB.balance, before + 1 ether);
        assertEq(clone.balance, 0);
        assertEq(MPForwarderV2(payable(clone)).destination(), HUB);
    }

    function test_CloneAndFlush_ERC20() public {
        MockERC20 t = new MockERC20();
        address clone = factory.getCloneAddress(address(parent), 2);
        t.mint(clone, 1_000_000);
        factory.cloneForwarderAndFlush(address(parent), 2, address(t), false);
        assertEq(t.balanceOf(HUB), 1_000_000);
        assertEq(t.balanceOf(clone), 0);
    }

    function test_CloneAndFlush_USDTNoReturn() public {
        MockERC20NoReturn t = new MockERC20NoReturn();
        address clone = factory.getCloneAddress(address(parent), 3);
        t.mint(clone, 5_000_000);
        factory.cloneForwarderAndFlush(address(parent), 3, address(t), true);
        assertEq(t.balanceOf(HUB), 5_000_000);
    }

    function test_CloneAndFlush_USDTNoReturn_ViaERC20PathAlsoWorks() public {
        // isUSDT is informational in V2: the safe transfer accepts empty return data either way.
        MockERC20NoReturn t = new MockERC20NoReturn();
        address clone = factory.getCloneAddress(address(parent), 4);
        t.mint(clone, 5_000_000);
        factory.cloneForwarderAndFlush(address(parent), 4, address(t), false);
        assertEq(t.balanceOf(HUB), 5_000_000);
    }

    function test_CloneAndFlush_ExistingClone_OnlyFlushes() public {
        address clone = factory.cloneForwarder(address(parent), 5);
        vm.deal(clone, 0.5 ether);
        MockERC20 t = new MockERC20();
        t.mint(clone, 7);
        vm.recordLogs();
        factory.cloneForwarderAndFlush(address(parent), 5, address(0), false);
        factory.cloneForwarderAndFlush(address(parent), 5, address(t), false);
        factory.cloneForwarderAndFlush(address(parent), 5, address(t), true); // USDT path on existing clone, zero balance
        assertEq(HUB.balance, 0.5 ether);
        assertEq(t.balanceOf(HUB), 7);
        // No CloneCreated events on the existing-clone path.
        for (uint256 i; i < vm.getRecordedLogs().length; i++) {
            assertTrue(vm.getRecordedLogs()[i].topics[0] != CloneCreated.selector);
        }
    }

    function test_CloneAndFlush_ZeroBalanceIsNoop() public {
        MockERC20 t = new MockERC20();
        address clone = factory.cloneForwarderAndFlush(address(parent), 6, address(t), false);
        assertEq(t.balanceOf(HUB), 0);
        assertEq(MPForwarderV2(payable(clone)).destination(), HUB);
    }

    // ============ Whole-transaction rollback ============

    function test_CloneAndFlush_TransferReturnsFalse_RevertsAndDoesNotDeploy() public {
        MockERC20ReturnsFalse t = new MockERC20ReturnsFalse();
        address clone = factory.getCloneAddress(address(parent), 10);
        t.mint(clone, 1);
        vm.expectRevert(MPForwarderV2.TransferFailed.selector);
        factory.cloneForwarderAndFlush(address(parent), 10, address(t), false);
        assertEq(clone.code.length, 0, "clone must not exist after revert");
    }

    function test_CloneAndFlush_TransferReverts_RevertsAndDoesNotDeploy() public {
        MockERC20Reverts t = new MockERC20Reverts();
        address clone = factory.getCloneAddress(address(parent), 11);
        t.mint(clone, 1);
        vm.expectRevert(MPForwarderV2.TransferFailed.selector);
        factory.cloneForwarderAndFlush(address(parent), 11, address(t), false);
        assertEq(clone.code.length, 0);
    }

    function test_CloneAndFlush_ShortReturnData_Reverts() public {
        MockERC20ShortReturn t = new MockERC20ShortReturn();
        address clone = factory.getCloneAddress(address(parent), 12);
        t.mint(clone, 1);
        vm.expectRevert(MPForwarderV2.TransferFailed.selector);
        factory.cloneForwarderAndFlush(address(parent), 12, address(t), false);
    }

    function test_CloneAndFlush_TokenWithoutCode_Reverts() public {
        address clone = factory.cloneForwarder(address(parent), 13);
        vm.expectRevert();
        MPForwarderV2(payable(clone)).flushERC20(makeAddr("not-a-token"));
    }

    function test_CloneAndFlush_DestinationRejectsETH_Reverts() public {
        RejectingReceiver bad = new RejectingReceiver();
        address badParent = factory.createForwarder(address(bad), 99);
        address clone = factory.getCloneAddress(badParent, 1);
        vm.deal(clone, 1 ether);
        vm.expectRevert(MPForwarderV2.FlushETHFailed.selector);
        factory.cloneForwarderAndFlush(badParent, 1, address(0), false);
        assertEq(clone.code.length, 0);
    }

    // ============ Front-running ============

    function test_FrontRun_SameSaltStillPaysHub() public {
        uint256 salt = uint256(sha256("payment_frontrun"));
        address predicted = factory.getCloneAddress(address(parent), salt);
        // Attacker deploys the clone first with our salt.
        vm.prank(attacker);
        address clone = factory.cloneForwarder(address(parent), salt);
        assertEq(clone, predicted);
        assertEq(MPForwarderV2(payable(clone)).destination(), HUB, "attacker cannot choose destination");
        // Customer pays, relayer flushes as usual.
        vm.deal(clone, 1 ether);
        vm.prank(relayer);
        factory.cloneForwarderAndFlush(address(parent), salt, address(0), false);
        assertEq(HUB.balance, 1 ether);
        assertEq(attacker.balance, 0);
    }

    function test_FrontRun_AttackerParentDoesNotCollideWithOurClone() public {
        uint256 salt = uint256(sha256("payment_x"));
        address ours = factory.getCloneAddress(address(parent), salt);
        address evilParent = factory.createForwarder(attacker, 0);
        address theirs = factory.getCloneAddress(evilParent, salt);
        assertTrue(ours != theirs, "different parent => different clone address");
    }

    // ============ Initialisation guards ============

    function test_Init_UnauthorizedCallerReverts() public {
        address clone = factory.cloneForwarder(address(parent), 20);
        vm.prank(attacker);
        vm.expectRevert(MPForwarderV2.OnlyFactory.selector);
        MPForwarderV2(payable(clone)).init(attacker);
        vm.prank(attacker);
        vm.expectRevert(MPForwarderV2.OnlyFactory.selector);
        MPForwarderV2(payable(clone)).initAndFlush(attacker, address(0), false);
        assertEq(MPForwarderV2(payable(clone)).destination(), HUB);
    }

    function test_Init_SecondInitByFactoryReverts() public {
        address clone = factory.cloneForwarder(address(parent), 21);
        vm.prank(address(factory));
        vm.expectRevert(MPForwarderV2.AlreadyInitialized.selector);
        MPForwarderV2(payable(clone)).init(attacker);
        vm.prank(address(factory));
        vm.expectRevert(MPForwarderV2.AlreadyInitialized.selector);
        MPForwarderV2(payable(clone)).initAndFlush(attacker, address(0), false);
    }

    function test_Init_ParentCannotBeReinitialized() public {
        vm.prank(address(factory));
        vm.expectRevert(MPForwarderV2.AlreadyInitialized.selector);
        parent.init(attacker);
        vm.prank(attacker);
        vm.expectRevert(MPForwarderV2.OnlyFactory.selector);
        parent.init(attacker);
    }

    function test_Init_UninitializedRawCloneRejectsZeroDestination() public {
        // Deploy a raw EIP-1167 clone of `parent` ourselves (not through the factory).
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", address(parent), hex"5af43d82803e903d91602b57fd5bf3"
        );
        address raw;
        assembly {
            raw := create(0, add(code, 0x20), mload(code))
        }
        vm.prank(address(factory));
        vm.expectRevert(MPForwarderV2.InvalidDestination.selector);
        MPForwarderV2(payable(raw)).init(address(0));
    }

    function test_Constructor_RejectsZeroFactoryOrDestination() public {
        vm.expectRevert(MPForwarderV2.InvalidFactory.selector);
        new MPForwarderV2(address(0), HUB);
        vm.expectRevert(MPForwarderV2.InvalidDestination.selector);
        new MPForwarderV2(address(factory), address(0));
    }

    // ============ Direct flushes on a clone ============

    function test_DirectFlushes_ArePermissionlessAndPayHub() public {
        address clone = factory.cloneForwarder(address(parent), 30);
        MockERC20 t = new MockERC20();
        MockERC20NoReturn u = new MockERC20NoReturn();
        vm.deal(clone, 1 wei);
        t.mint(clone, 2);
        u.mint(clone, 3);
        vm.startPrank(attacker);
        MPForwarderV2(payable(clone)).flushETH();
        MPForwarderV2(payable(clone)).flushERC20(address(t));
        MPForwarderV2(payable(clone)).flushUSDT(address(u));
        vm.stopPrank();
        assertEq(HUB.balance, 1);
        assertEq(t.balanceOf(HUB), 2);
        assertEq(u.balanceOf(HUB), 3);
    }

    // ============ helpers ============

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; i++) {
            bool m = true;
            for (uint256 j; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }
}
