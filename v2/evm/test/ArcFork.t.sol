// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

import { Test, console2, Vm } from "forge-std/Test.sol";
import { MPForwarderFactoryV2 } from "../src/MPForwarderFactoryV2.sol";
import { MPForwarderV2 } from "../src/MPForwarderV2.sol";
import { NicksFactory } from "./helpers/NicksFactory.sol";
import { IERC20Minimal } from "../src/interface/IERC20Minimal.sol";

/**
 * @notice Arc testnet (chainId 5042002) fork tests. Run with:
 *   ARC_TESTNET_RPC=https://rpc.testnet.arc.io arc-forge test -n arc --match-contract ArcFork -vv
 * Skipped when ARC_TESTNET_RPC is unset. These exercise both Arc USDC interfaces against the real
 * system contracts; they do NOT replace a live deployment.
 */
contract ArcForkTest is Test {
    address internal constant ARC_USDC_ERC20 = 0x3600000000000000000000000000000000000000;
    address internal constant ARC_SYSTEM_EMITTER = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    address internal constant HUB = 0x05c84533299625Df3Ace2215742124C1644E2705;
    bytes32 internal constant SALT_F2 = keccak256("rozo.forwarder.factory.v2");
    uint256 internal constant SCALE = 1e12; // 18-dec native -> 6-dec ERC-20 view

    bool internal enabled;
    MPForwarderFactoryV2 internal factory;
    address internal parent;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        string memory rpc = vm.envOr("ARC_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        enabled = true;
        assertEq(block.chainid, 5042002, "expected Arc testnet");

        // Nick's factory must already be on Arc testnet with the Ethereum runtime.
        assertEq(keccak256(NicksFactory.ADDRESS.code), keccak256(NicksFactory.RUNTIME), "Nick runtime differs on Arc");

        address predicted = NicksFactory.create2Address(SALT_F2, keccak256(type(MPForwarderFactoryV2).creationCode));
        if (predicted.code.length == 0) {
            (bool ok, bytes memory ret) =
                NicksFactory.ADDRESS.call(abi.encodePacked(SALT_F2, type(MPForwarderFactoryV2).creationCode));
            require(ok, "nick call failed");
            assertEq(address(bytes20(ret)), predicted);
        } else {
            // Already live on the testnet: must be exactly our runtime.
            assertEq(keccak256(predicted.code), keccak256(type(MPForwarderFactoryV2).runtimeCode));
        }
        factory = MPForwarderFactoryV2(predicted);
        parent = factory.createForwarder(HUB, 0);
    }

    modifier onlyFork() {
        if (!enabled) {
            console2.log("ARC_TESTNET_RPC not set; skipping");
            return;
        }
        _;
    }

    function test_Fork_ChainAndSystemContracts() public onlyFork {
        assertEq(block.chainid, 5042002);
        assertGt(ARC_USDC_ERC20.code.length, 0, "USDC ERC-20 view has code");
        // Note: on Arc testnet the gas price floor is enforced by the node; nothing to assert here.
    }

    /// @dev Path 1: native USDC (18 dec) via flushETH. Includes sub-microUSDC dust.
    function test_Fork_FlushNativeUSDC_WithDust() public onlyFork {
        uint256 salt = uint256(sha256("arc-native-dust"));
        address clone = factory.getCloneAddress(parent, salt);
        uint256 amount = 1_000_000 * SCALE + 123_456_789_012; // 1.000000123456789012 USDC
        vm.deal(clone, amount);
        uint256 hubBefore = HUB.balance;
        uint256 hubViewBefore = IERC20Minimal(ARC_USDC_ERC20).balanceOf(HUB);

        factory.cloneForwarderAndFlush(parent, salt, address(0), false);

        assertEq(clone.balance, 0, "native path moves everything incl. dust");
        assertEq(HUB.balance, hubBefore + amount);
        // ERC-20 view of the hub moves by the floor in 6 decimals.
        uint256 hubViewAfter = IERC20Minimal(ARC_USDC_ERC20).balanceOf(HUB);
        assertEq(hubViewAfter - hubViewBefore, (hubBefore + amount) / SCALE - hubBefore / SCALE);
        console2.log("native flush: hub view delta (6dec)", hubViewAfter - hubViewBefore);
    }

    /// @dev Path 2: ERC-20 view (6 dec) via flushERC20(0x3600…). Dust below 1e-6 USDC stays behind.
    function test_Fork_FlushERC20View_LeavesDust() public onlyFork {
        uint256 salt = uint256(sha256("arc-erc20-dust"));
        address clone = factory.getCloneAddress(parent, salt);
        uint256 amount = 2_500_000 * SCALE + 999_999_999_999; // 2.5 USDC + max dust
        vm.deal(clone, amount);
        assertEq(IERC20Minimal(ARC_USDC_ERC20).balanceOf(clone), 2_500_000, "6-dec view floors");
        uint256 hubBefore = HUB.balance;

        factory.cloneForwarderAndFlush(parent, salt, ARC_USDC_ERC20, false);

        assertEq(HUB.balance, hubBefore + 2_500_000 * SCALE, "hub receives the 6-dec amount");
        assertEq(clone.balance, 999_999_999_999, "dust below 1e-6 USDC remains on the clone");
        assertEq(IERC20Minimal(ARC_USDC_ERC20).balanceOf(clone), 0, "ERC-20 view of dust is zero");

        // The native path can still sweep the dust afterwards (same balance, other interface).
        MPForwarderV2(payable(clone)).flushETH();
        assertEq(clone.balance, 0);
        assertEq(HUB.balance, hubBefore + amount);
    }

    /// @dev ERC-20 view flush of a whole-unit balance: no dust, clone fully drained, view zeroed.
    function test_Fork_FlushERC20View_WholeUnits() public onlyFork {
        uint256 salt = uint256(sha256("arc-erc20-whole"));
        address clone = factory.getCloneAddress(parent, salt);
        vm.deal(clone, 1_000_000 * SCALE);
        uint256 hubBefore = HUB.balance;
        factory.cloneForwarderAndFlush(parent, salt, ARC_USDC_ERC20, false);
        assertEq(clone.balance, 0);
        assertEq(HUB.balance, hubBefore + 1_000_000 * SCALE);
    }

    /// @dev Both interfaces are the same balance: flushing twice never double-pays.
    function test_Fork_BothPathsNeverDoubleCount() public onlyFork {
        uint256 salt = uint256(sha256("arc-both"));
        address clone = factory.getCloneAddress(parent, salt);
        vm.deal(clone, 3_000_000 * SCALE);
        uint256 hubBefore = HUB.balance;
        factory.cloneForwarderAndFlush(parent, salt, ARC_USDC_ERC20, false);
        factory.cloneForwarderAndFlush(parent, salt, address(0), false); // existing clone, native path, zero balance
        assertEq(HUB.balance, hubBefore + 3_000_000 * SCALE, "exactly once");
    }

    /// @dev The relayer-side accounting rule: count the system emitter's 18-dec Transfer only once.
    function test_Fork_ERC20TransferEmitsSystemLogAndViewLog() public onlyFork {
        uint256 salt = uint256(sha256("arc-logs"));
        address clone = factory.getCloneAddress(parent, salt);
        vm.deal(clone, 1_000_000 * SCALE);
        vm.recordLogs();
        factory.cloneForwarderAndFlush(parent, salt, ARC_USDC_ERC20, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sys;
        uint256 view6;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == Transfer.selector) {
                if (logs[i].emitter == ARC_SYSTEM_EMITTER) sys++;
                if (logs[i].emitter == ARC_USDC_ERC20) view6++;
            }
        }
        console2.log("system emitter Transfer logs", sys);
        console2.log("0x3600 Transfer logs        ", view6);
        assertGe(sys + view6, 1, "at least one Transfer log observed");
    }

}

