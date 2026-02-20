// SPDX-License-Identifier: BSD-2-Clause
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/MPForwarderV2.sol";

contract MPForwarderV2Test is Test {
    MPForwarderV2 public forwarder;
    address public destination;
    address public relayer;
    address public user;

    function setUp() public {
        destination = makeAddr("destination");
        relayer = makeAddr("relayer");
        user = makeAddr("user");

        forwarder = new MPForwarderV2(destination, relayer);
    }

    function test_Constructor() public view {
        assertEq(forwarder.destination(), destination);
        assertEq(forwarder.relayer(), relayer);
    }

    function test_ReceiveETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success,) = address(forwarder).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(forwarder).balance, 1 ether);
    }

    function test_FlushETH() public {
        vm.deal(address(forwarder), 1 ether);
        uint256 destBalanceBefore = destination.balance;

        forwarder.flushETH();

        assertEq(address(forwarder).balance, 0);
        assertEq(destination.balance, destBalanceBefore + 1 ether);
    }

    function test_TransferETH_OnlyRelayer() public {
        vm.deal(address(forwarder), 1 ether);

        vm.prank(user);
        vm.expectRevert("only relayer");
        forwarder.transferETH(user, 0.5 ether);
    }

    function test_TransferETH() public {
        vm.deal(address(forwarder), 1 ether);

        vm.prank(relayer);
        forwarder.transferETH(user, 0.5 ether);

        // 0.5 ETH to user, remaining 0.5 ETH flushed to destination
        assertEq(user.balance, 0.5 ether);
        assertEq(destination.balance, 0.5 ether);
        assertEq(address(forwarder).balance, 0);
    }

    function test_Init_OnlyOnce() public {
        // Trying to init an already initialized forwarder should revert
        vm.expectRevert("already initialized");
        forwarder.init(destination, relayer);
    }
}
