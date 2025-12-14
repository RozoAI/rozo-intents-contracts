// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RozoIntents.sol";
import "../src/interfaces/IRozoIntents.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockMessengerAdapter.sol";

contract RozoIntentsTest is Test {
    RozoIntents internal intents;
    MockERC20 internal token;
    MockMessengerAdapter internal rozoAdapter;
    MockMessengerAdapter internal axelarAdapter;

    address internal constant SENDER = address(0x1111);
    address internal constant RELAYER = address(0x2222);
    address internal constant RELAYER_TWO = address(0x2223);
    address internal constant ROZO_RELAYER = address(0x2224);
    address internal constant REFUND = address(0x3333);
    address internal constant RECEIVER = address(0x4444);
    address internal constant FEE_RECIPIENT = address(0x5555);

    uint256 internal constant SOURCE_AMOUNT = 1_000e6;
    uint256 internal constant DESTINATION_AMOUNT = 995e6;
    uint256 internal constant DEST_CHAIN_ID = 1500;
    uint256 internal constant SOURCE_CHAIN_ID = 8453;
    bytes32 internal constant DEST_TOKEN = bytes32(uint256(uint160(address(0x9999))));
    bytes32 internal constant RECEIVER_BYTES = bytes32(uint256(uint160(RECEIVER)));

    function setUp() public {
        token = new MockERC20("Mock USDC", "USDC", 6);

        intents = new RozoIntents(address(this), FEE_RECIPIENT);

        // Create and register messenger adapters
        rozoAdapter = new MockMessengerAdapter(0, address(intents)); // Rozo = 0
        axelarAdapter = new MockMessengerAdapter(1, address(intents)); // Axelar = 1

        intents.setMessengerAdapter(address(rozoAdapter));
        intents.setMessengerAdapter(address(axelarAdapter));

        vm.deal(RELAYER, 10 ether);
        vm.deal(RELAYER_TWO, 10 ether);
        vm.deal(ROZO_RELAYER, 10 ether);

        token.mint(SENDER, 100_000e6);
        token.mint(RELAYER, 100_000e6);
        token.mint(RELAYER_TWO, 100_000e6);
        token.mint(ROZO_RELAYER, 100_000e6);

        // Add relayers with types
        intents.addRelayer(RELAYER, RelayerType.EXTERNAL);
        intents.addRelayer(RELAYER_TWO, RelayerType.EXTERNAL);
        intents.addRelayer(ROZO_RELAYER, RelayerType.ROZO);

        // Configure Rozo fallback
        intents.setRozoRelayer(ROZO_RELAYER);
        intents.setRozoRelayerThreshold(10); // 10 seconds

        intents.setProtocolFee(3);
        intents.setTrustedContract("stellar", "stellar-contract");
        intents.setTrustedContract("base", "base-contract");
    }

    // ============ Create Intent Tests ============

    function testCreateIntentSuccess() public {
        bytes32 intentId = _createIntent();
        Intent memory stored = intents.intents(intentId);
        assertEq(uint256(stored.status), uint256(IntentStatus.PENDING));
        assertEq(stored.sender, SENDER);
        assertEq(stored.createdAt, block.timestamp);
        assertEq(token.balanceOf(address(intents)), SOURCE_AMOUNT);
    }

    function testCreateIntentWithAssignedRelayer() public {
        bytes32 intentId = _createIntentWithRelayer(_addressToBytes32(RELAYER));
        Intent memory stored = intents.intents(intentId);
        assertEq(stored.relayer, _addressToBytes32(RELAYER));
    }

    function testCreateIntentRevertsDuplicate() public {
        bytes32 intentId = _createIntent();
        vm.startPrank(SENDER);
        token.approve(address(intents), SOURCE_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.IntentAlreadyExists.selector);
        intents.createIntent(
            intentId,
            address(token),
            SOURCE_AMOUNT,
            DEST_CHAIN_ID,
            DEST_TOKEN,
            RECEIVER_BYTES,
            DESTINATION_AMOUNT,
            uint64(block.timestamp + 1 hours),
            REFUND,
            bytes32(0)
        );
        vm.stopPrank();
    }

    // ============ Fill And Notify Tests (Destination Chain) ============

    function testFillAndNotifySuccess() public {
        IntentData memory intentData = _createIntentData();

        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);
        vm.stopPrank();

        assertEq(token.balanceOf(RECEIVER), DESTINATION_AMOUNT);

        // Check fill record was stored
        bytes32 fillHash = keccak256(abi.encode(intentData));
        (address filledRelayer, bytes32 filledRepaymentAddress) = intents.filledIntents(fillHash);
        assertEq(filledRelayer, RELAYER);
        assertEq(filledRepaymentAddress, _addressToBytes32(RELAYER));
    }

    function testFillAndNotifyWithDifferentRepaymentAddress() public {
        IntentData memory intentData = _createIntentData();
        bytes32 repaymentAddress = _addressToBytes32(address(0x9876));

        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        intents.fillAndNotify(intentData, repaymentAddress, 0);
        vm.stopPrank();

        bytes32 fillHash = keccak256(abi.encode(intentData));
        (, bytes32 filledRepaymentAddress) = intents.filledIntents(fillHash);
        assertEq(filledRepaymentAddress, repaymentAddress);
    }

    function testFillAndNotifyRevertsForNonRelayer() public {
        IntentData memory intentData = _createIntentData();
        address stranger = address(0xABBA);
        token.mint(stranger, DESTINATION_AMOUNT);

        vm.startPrank(stranger);
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.NotRelayer.selector);
        intents.fillAndNotify(intentData, _addressToBytes32(stranger), 0);
        vm.stopPrank();
    }

    function testFillAndNotifyRevertsIfExpired() public {
        IntentData memory intentData = _createIntentData();
        intentData.deadline = uint64(block.timestamp - 1);

        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.IntentExpired.selector);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);
        vm.stopPrank();
    }

    function testFillAndNotifyRevertsIfWrongChain() public {
        IntentData memory intentData = _createIntentData();
        intentData.destinationChainId = 9999;

        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.WrongChain.selector);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);
        vm.stopPrank();
    }

    function testFillAndNotifyRevertsOnDoubleFill() public {
        IntentData memory intentData = _createIntentData();

        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT * 2);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);

        vm.expectRevert(IRozoIntentsErrors.AlreadyFilled.selector);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);
        vm.stopPrank();
    }

    function testFillAndNotifyRevertsIfNotAssignedRelayer() public {
        IntentData memory intentData = _createIntentData();
        intentData.relayer = _addressToBytes32(RELAYER_TWO); // Assign to RELAYER_TWO

        vm.startPrank(RELAYER); // But RELAYER tries to fill
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.NotAssignedRelayer.selector);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);
        vm.stopPrank();
    }

    function testFillAndNotifyRozoFallbackWorks() public {
        // Warp to a reasonable timestamp to avoid underflow
        vm.warp(1000);

        IntentData memory intentData = _createIntentData();
        intentData.relayer = _addressToBytes32(RELAYER); // Assign to RELAYER
        intentData.createdAt = uint64(block.timestamp - 15); // Created 15 seconds ago

        // ROZO_RELAYER can fill after threshold (10 seconds)
        vm.startPrank(ROZO_RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        intents.fillAndNotify(intentData, _addressToBytes32(ROZO_RELAYER), 0);
        vm.stopPrank();

        assertEq(token.balanceOf(RECEIVER), DESTINATION_AMOUNT);
    }

    function testFillAndNotifyRozoFallbackRevertsBeforeThreshold() public {
        // Warp to a reasonable timestamp to avoid underflow
        vm.warp(1000);

        IntentData memory intentData = _createIntentData();
        intentData.relayer = _addressToBytes32(RELAYER); // Assign to RELAYER
        intentData.createdAt = uint64(block.timestamp - 5); // Created 5 seconds ago

        // ROZO_RELAYER cannot fill before threshold (10 seconds)
        vm.startPrank(ROZO_RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.NotAssignedRelayer.selector);
        intents.fillAndNotify(intentData, _addressToBytes32(ROZO_RELAYER), 0);
        vm.stopPrank();
    }

    function testFillAndNotifyWithDifferentMessengers() public {
        IntentData memory intentData = _createIntentData();

        // Test with Axelar (messengerId = 1)
        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 1);
        vm.stopPrank();

        // Check that Axelar adapter received the message
        (uint256 destChainId,,) = axelarAdapter.lastSentMessage();
        assertEq(destChainId, intentData.sourceChainId);
    }

    function testFillAndNotifyRevertsInvalidMessenger() public {
        IntentData memory intentData = _createIntentData();

        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.InvalidMessenger.selector);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 99); // Invalid messengerId
        vm.stopPrank();
    }

    // ============ Retry Notify Tests ============

    function testRetryNotifySuccess() public {
        IntentData memory intentData = _createIntentData();

        // First fill with Rozo adapter
        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);

        // Retry with Axelar adapter
        intents.retryNotify(intentData, 1);
        vm.stopPrank();

        // Check Axelar adapter received retry message
        (uint256 destChainId,,) = axelarAdapter.lastSentMessage();
        assertEq(destChainId, intentData.sourceChainId);
    }

    function testRetryNotifyRevertsIfNotFilled() public {
        IntentData memory intentData = _createIntentData();

        vm.prank(RELAYER);
        vm.expectRevert(IRozoIntentsErrors.IntentNotFound.selector);
        intents.retryNotify(intentData, 1);
    }

    function testRetryNotifyRevertsIfNotOriginalFiller() public {
        IntentData memory intentData = _createIntentData();

        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        intents.fillAndNotify(intentData, _addressToBytes32(RELAYER), 0);
        vm.stopPrank();

        // Different relayer tries to retry
        vm.prank(RELAYER_TWO);
        vm.expectRevert(IRozoIntentsErrors.NotAssignedRelayer.selector);
        intents.retryNotify(intentData, 1);
    }

    // ============ Notify Tests (Source Chain) ============

    function testNotifyCompletesFill() public {
        bytes32 intentId = _createIntent();
        Intent memory stored = intents.intents(intentId);

        // Build IntentData from stored intent
        IntentData memory intentData = IntentData({
            intentId: intentId,
            sender: _addressToBytes32(stored.sender),
            refundAddress: _addressToBytes32(stored.refundAddress),
            sourceToken: _addressToBytes32(stored.sourceToken),
            sourceAmount: stored.sourceAmount,
            sourceChainId: block.chainid,
            destinationChainId: stored.destinationChainId,
            destinationToken: stored.destinationToken,
            receiver: stored.receiver,
            destinationAmount: stored.destinationAmount,
            deadline: stored.deadline,
            createdAt: stored.createdAt,
            relayer: stored.relayer
        });

        bytes32 fillHash = keccak256(abi.encode(intentData));
        bytes32 repaymentAddress = _addressToBytes32(RELAYER);
        bytes32 relayerBytes32 = _addressToBytes32(RELAYER);

        // Payload format: intentId, fillHash, repaymentAddress, relayer, amount
        bytes memory payload = abi.encode(intentId, fillHash, repaymentAddress, relayerBytes32, DESTINATION_AMOUNT);

        uint256 relayerBefore = token.balanceOf(RELAYER);

        // Simulate notify from messenger adapter
        rozoAdapter.simulateNotify(address(intents), DEST_CHAIN_ID, payload);

        Intent memory result = intents.intents(intentId);
        assertEq(uint256(result.status), uint256(IntentStatus.FILLED));
        assertEq(token.balanceOf(RELAYER), relayerBefore + SOURCE_AMOUNT - _fee());
        assertEq(intents.accumulatedFees(address(token)), _fee());
    }

    function testNotifySetsFailedOnFillHashMismatch() public {
        bytes32 intentId = _createIntent();

        // Create wrong fillHash
        bytes32 wrongFillHash = keccak256("wrong");
        bytes32 repaymentAddress = _addressToBytes32(RELAYER);
        bytes32 relayerBytes32 = _addressToBytes32(RELAYER);

        // Payload format: intentId, fillHash, repaymentAddress, relayer, amount
        bytes memory payload = abi.encode(intentId, wrongFillHash, repaymentAddress, relayerBytes32, DESTINATION_AMOUNT);

        rozoAdapter.simulateNotify(address(intents), DEST_CHAIN_ID, payload);

        Intent memory result = intents.intents(intentId);
        assertEq(uint256(result.status), uint256(IntentStatus.FAILED));
    }

    function testNotifyRevertsIfNotMessenger() public {
        bytes memory payload = abi.encode(bytes32(0), bytes32(0), bytes32(0), bytes32(0), uint256(0));

        vm.prank(address(0x1234));
        vm.expectRevert(IRozoIntentsErrors.NotMessenger.selector);
        intents.notify(0, DEST_CHAIN_ID, payload);
    }

    // ============ Refund Tests ============

    function testRefundAfterDeadline() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + 3 hours);

        uint256 beforeBalance = token.balanceOf(REFUND);
        vm.prank(SENDER);
        intents.refund(intentId);

        assertEq(token.balanceOf(REFUND), beforeBalance + SOURCE_AMOUNT);
        assertEq(uint256(intents.intents(intentId).status), uint256(IntentStatus.REFUNDED));
    }

    function testRefundRevertsBeforeDeadline() public {
        bytes32 intentId = _createIntent();
        vm.prank(SENDER);
        vm.expectRevert(IRozoIntentsErrors.IntentNotExpired.selector);
        intents.refund(intentId);
    }

    function testRefundRevertsIfNotPending() public {
        bytes32 intentId = _createIntent();

        // Admin sets to FILLED
        intents.setIntentStatus(intentId, IntentStatus.FILLED);

        vm.warp(block.timestamp + 3 hours);
        vm.prank(SENDER);
        vm.expectRevert(
            abi.encodeWithSelector(IRozoIntentsErrors.InvalidStatus.selector, IntentStatus.FILLED, IntentStatus.PENDING)
        );
        intents.refund(intentId);
    }

    // ============ Admin Tests ============

    function testAdminRefundByOwner() public {
        bytes32 intentId = _createIntent();
        uint256 beforeBalance = token.balanceOf(REFUND);
        intents.adminRefund(intentId);
        assertEq(token.balanceOf(REFUND), beforeBalance + SOURCE_AMOUNT);
    }

    function testSetIntentStatusAndRelayer() public {
        bytes32 intentId = _createIntent();
        intents.setIntentStatus(intentId, IntentStatus.FAILED);
        assertEq(uint256(intents.intents(intentId).status), uint256(IntentStatus.FAILED));

        intents.setIntentRelayer(intentId, _addressToBytes32(RELAYER));
        assertEq(intents.intents(intentId).relayer, _addressToBytes32(RELAYER));
    }

    function testWithdrawFeesSendsBalanceToRecipient() public {
        bytes32 intentId = _createIntent();
        Intent memory stored = intents.intents(intentId);

        // Build IntentData and complete fill
        IntentData memory intentData = IntentData({
            intentId: intentId,
            sender: _addressToBytes32(stored.sender),
            refundAddress: _addressToBytes32(stored.refundAddress),
            sourceToken: _addressToBytes32(stored.sourceToken),
            sourceAmount: stored.sourceAmount,
            sourceChainId: block.chainid,
            destinationChainId: stored.destinationChainId,
            destinationToken: stored.destinationToken,
            receiver: stored.receiver,
            destinationAmount: stored.destinationAmount,
            deadline: stored.deadline,
            createdAt: stored.createdAt,
            relayer: stored.relayer
        });

        bytes32 fillHash = keccak256(abi.encode(intentData));
        bytes32 relayerBytes32 = _addressToBytes32(RELAYER);
        // Payload format: intentId, fillHash, repaymentAddress, relayer, amount
        bytes memory payload = abi.encode(intentId, fillHash, relayerBytes32, relayerBytes32, DESTINATION_AMOUNT);
        rozoAdapter.simulateNotify(address(intents), DEST_CHAIN_ID, payload);

        uint256 recipientBefore = token.balanceOf(FEE_RECIPIENT);
        intents.withdrawFees(address(token));
        assertEq(token.balanceOf(FEE_RECIPIENT), recipientBefore + _fee());
        assertEq(intents.accumulatedFees(address(token)), 0);
    }

    function testSetProtocolFeeBounds() public {
        intents.setProtocolFee(0);
        assertEq(intents.protocolFee(), 0);

        vm.expectRevert(IRozoIntentsErrors.InvalidFee.selector);
        intents.setProtocolFee(31);
    }

    function testAddAndRemoveRelayer() public {
        address newRelayer = address(0x9999);

        intents.addRelayer(newRelayer, RelayerType.EXTERNAL);
        assertEq(uint256(intents.relayers(newRelayer)), uint256(RelayerType.EXTERNAL));

        intents.removeRelayer(newRelayer);
        assertEq(uint256(intents.relayers(newRelayer)), uint256(RelayerType.NONE));
    }

    function testSetRozoRelayerAndThreshold() public {
        address newRozoRelayer = address(0x8888);
        intents.setRozoRelayer(newRozoRelayer);
        assertEq(intents.rozoRelayer(), newRozoRelayer);

        intents.setRozoRelayerThreshold(60);
        assertEq(intents.rozoRelayerThreshold(), 60);
    }

    function testSetMessengerAdapter() public {
        MockMessengerAdapter newAdapter = new MockMessengerAdapter(2, address(intents));
        intents.setMessengerAdapter(address(newAdapter));
        assertEq(address(intents.messengerAdapters(2)), address(newAdapter));
    }

    // ============ View Functions Tests ============

    function testViewFunctions() public {
        assertEq(intents.rozoRelayer(), ROZO_RELAYER);
        assertEq(intents.rozoRelayerThreshold(), 10);
        assertEq(intents.protocolFee(), 3);
        assertEq(intents.feeRecipient(), FEE_RECIPIENT);
        assertEq(uint256(intents.relayers(RELAYER)), uint256(RelayerType.EXTERNAL));
        assertEq(address(intents.messengerAdapters(0)), address(rozoAdapter));
        assertEq(address(intents.messengerAdapters(1)), address(axelarAdapter));
    }

    // ============ Helper Functions ============

    function _createIntent() internal returns (bytes32 intentId) {
        return _createIntentWithRelayer(bytes32(0));
    }

    function _createIntentWithRelayer(bytes32 relayer) internal returns (bytes32 intentId) {
        intentId = keccak256(abi.encodePacked("intent-", block.timestamp, relayer));
        vm.startPrank(SENDER);
        token.approve(address(intents), SOURCE_AMOUNT);
        intents.createIntent(
            intentId,
            address(token),
            SOURCE_AMOUNT,
            DEST_CHAIN_ID,
            DEST_TOKEN,
            RECEIVER_BYTES,
            DESTINATION_AMOUNT,
            uint64(block.timestamp + 1 hours),
            REFUND,
            relayer
        );
        vm.stopPrank();
    }

    function _createIntentData() internal view returns (IntentData memory) {
        return IntentData({
            intentId: keccak256("test-intent"),
            sender: _addressToBytes32(SENDER),
            refundAddress: _addressToBytes32(REFUND),
            sourceToken: _addressToBytes32(address(token)),
            sourceAmount: SOURCE_AMOUNT,
            sourceChainId: SOURCE_CHAIN_ID,
            destinationChainId: block.chainid, // Current chain is destination
            destinationToken: _addressToBytes32(address(token)),
            receiver: RECEIVER_BYTES,
            destinationAmount: DESTINATION_AMOUNT,
            deadline: uint64(block.timestamp + 1 hours),
            createdAt: uint64(block.timestamp),
            relayer: bytes32(0) // Open intent
        });
    }

    function _fee() internal view returns (uint256) {
        return (SOURCE_AMOUNT * intents.protocolFee()) / 10_000;
    }

    function _addressToBytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
