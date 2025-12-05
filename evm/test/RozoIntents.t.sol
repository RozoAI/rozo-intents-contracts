// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RozoIntents.sol";
import "../src/interfaces/IRozoIntents.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAxelarGateway.sol";
import "./mocks/MockGasService.sol";
import "./mocks/MockBridgeAdapter.sol";

contract RozoIntentsTest is Test {
    RozoIntents internal intents;
    MockERC20 internal token;
    MockAxelarGateway internal gateway;
    MockGasService internal gasService;
    MockBridgeAdapter internal bridge;

    address internal constant SENDER = address(0x1111);
    address internal constant RELAYER = address(0x2222);
    address internal constant RELAYER_TWO = address(0x2223);
    address internal constant REFUND = address(0x3333);
    address internal constant RECEIVER = address(0x4444);
    address internal constant FEE_RECIPIENT = address(0x5555);

    uint256 internal constant SOURCE_AMOUNT = 1_000e6;
    uint256 internal constant DESTINATION_AMOUNT = 995e6;
    uint256 internal constant DEST_CHAIN_ID = 1500;
    uint256 internal constant SOURCE_CHAIN_ID = 8453;
    bytes32 internal constant DEST_TOKEN = bytes32(uint256(uint160(address(0x9999))));
    bytes32 internal constant RECEIVER_BYTES = bytes32(uint256(uint160(RECEIVER)));

    string internal constant SOURCE_CHAIN_NAME = "stellar";
    string internal constant CALLBACK_CHAIN_NAME = "base";
    string internal constant SOURCE_CONTRACT = "stellar-contract";
    string internal constant DEST_CONTRACT = "base-contract";

    function setUp() public {
        token = new MockERC20("Mock USDC", "USDC", 6);
        gateway = new MockAxelarGateway();
        gasService = new MockGasService();
        bridge = new MockBridgeAdapter();

        intents = new RozoIntents(address(this), address(gateway), address(gasService), FEE_RECIPIENT);

        vm.deal(RELAYER, 10 ether);
        vm.deal(RELAYER_TWO, 10 ether);

        token.mint(SENDER, 100_000e6);
        token.mint(RELAYER, 100_000e6);
        token.mint(RELAYER_TWO, 100_000e6);

        intents.addRelayer(RELAYER);
        intents.addRelayer(RELAYER_TWO);
        intents.setProtocolFee(3);
        intents.setChainIdToAxelarName(SOURCE_CHAIN_ID, CALLBACK_CHAIN_NAME);
        intents.setTrustedContract(SOURCE_CHAIN_NAME, SOURCE_CONTRACT);
        intents.setTrustedContract(CALLBACK_CHAIN_NAME, DEST_CONTRACT);
    }

    function testCreateIntentSuccess() public {
        bytes32 intentId = _createIntent();
        Intent memory stored = intents.intents(intentId);
        assertEq(uint256(stored.status), uint256(IntentStatus.NEW));
        assertEq(stored.sender, SENDER);
        assertEq(token.balanceOf(address(intents)), SOURCE_AMOUNT);
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
            REFUND
        );
        vm.stopPrank();
    }

    function testFillSuccess() public {
        bytes32 intentId = _createIntent();
        vm.prank(RELAYER);
        intents.fill(intentId);
        Intent memory stored = intents.intents(intentId);
        assertEq(uint256(stored.status), uint256(IntentStatus.FILLING));
        assertEq(stored.relayer, RELAYER);
    }

    function testFillRevertsIfNotRelayer() public {
        bytes32 intentId = _createIntent();
        address stranger = address(0xAAAA);
        vm.prank(stranger);
        vm.expectRevert(IRozoIntentsErrors.NotRelayer.selector);
        intents.fill(intentId);
    }

    function testFillRevertsIfExpired() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(RELAYER);
        vm.expectRevert(IRozoIntentsErrors.IntentExpired.selector);
        intents.fill(intentId);
    }

    function testNotifyCompletesFillFromFilling() public {
        bytes32 intentId = _createIntent();
        vm.prank(RELAYER);
        intents.fill(intentId);

        uint256 relayerBefore = token.balanceOf(RELAYER);
        bytes memory payload =
            abi.encode(intentId, DESTINATION_AMOUNT, _addressToBytes32(RELAYER), RECEIVER_BYTES, DEST_TOKEN);
        bytes32 commandId = keccak256("cmd");
        gateway.approve(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);

        vm.prank(address(gateway));
        intents.notify(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);

        Intent memory stored = intents.intents(intentId);
        assertEq(uint256(stored.status), uint256(IntentStatus.FILLED));
        assertEq(token.balanceOf(RELAYER), relayerBefore + SOURCE_AMOUNT - _fee());
        assertEq(intents.accumulatedFees(address(token)), _fee());
    }

    function testNotifyCompletesFillFromNew() public {
        bytes32 intentId = _createIntent();
        uint256 relayerBefore = token.balanceOf(RELAYER_TWO);
        bytes memory payload =
            abi.encode(intentId, DESTINATION_AMOUNT, _addressToBytes32(RELAYER_TWO), RECEIVER_BYTES, DEST_TOKEN);
        bytes32 commandId = keccak256("cmd-new");
        gateway.approve(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);

        vm.prank(address(gateway));
        intents.notify(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);

        Intent memory stored = intents.intents(intentId);
        assertEq(uint256(stored.status), uint256(IntentStatus.FILLED));
        assertEq(stored.relayer, RELAYER_TWO);
        assertEq(token.balanceOf(RELAYER_TWO), relayerBefore + SOURCE_AMOUNT - _fee());
    }

    function testNotifySetsFailedOnMismatch() public {
        bytes32 intentId = _createIntent();
        vm.prank(RELAYER);
        intents.fill(intentId);

        bytes32 wrongReceiver = bytes32(uint256(uint160(address(0xABC))));
        bytes memory payload =
            abi.encode(intentId, DESTINATION_AMOUNT, _addressToBytes32(RELAYER), wrongReceiver, DEST_TOKEN);
        bytes32 commandId = keccak256("cmd-fail");
        gateway.approve(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);

        vm.prank(address(gateway));
        intents.notify(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);

        Intent memory stored = intents.intents(intentId);
        assertEq(uint256(stored.status), uint256(IntentStatus.FAILED));
    }

    function testNotifyRevertsIfNotMessenger() public {
        bytes32 intentId = _createIntent();
        bytes memory payload =
            abi.encode(intentId, DESTINATION_AMOUNT, _addressToBytes32(RELAYER), RECEIVER_BYTES, DEST_TOKEN);
        vm.prank(address(0x1234));
        vm.expectRevert(IRozoIntentsErrors.NotMessenger.selector);
        intents.notify(bytes32(0), SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);
    }

    function testNotifyRevertsIfNotApproved() public {
        bytes32 intentId = _createIntent();
        bytes memory payload =
            abi.encode(intentId, DESTINATION_AMOUNT, _addressToBytes32(RELAYER), RECEIVER_BYTES, DEST_TOKEN);
        vm.prank(address(gateway));
        vm.expectRevert(IRozoIntentsErrors.NotApprovedByGateway.selector);
        intents.notify(bytes32("unknown"), SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);
    }

    function testSlowFillTransfersFundsAndCallsBridge() public {
        bytes32 intentId = _createIntent();
        intents.setSlowFillBridge(DEST_CHAIN_ID, address(token), DEST_TOKEN, address(bridge));

        vm.prank(RELAYER);
        intents.slowFill(intentId);

        Intent memory stored = intents.intents(intentId);
        assertEq(uint256(stored.status), uint256(IntentStatus.FILLED));
        assertEq(token.balanceOf(address(intents)), _fee());
        assertEq(token.balanceOf(address(bridge)), SOURCE_AMOUNT - _fee());
        assertEq(bridge.lastCall.amount, SOURCE_AMOUNT - _fee());
    }

    function testSlowFillRevertsWhenUnsupported() public {
        bytes32 intentId = _createIntent();
        vm.prank(RELAYER);
        vm.expectRevert(IRozoIntentsErrors.SlowFillUnsupported.selector);
        intents.slowFill(intentId);
    }

    function testSlowFillRevertsIfDestinationAmountTooHigh() public {
        bytes32 intentId = _createIntentWithDestination(SOURCE_AMOUNT);
        intents.setSlowFillBridge(DEST_CHAIN_ID, address(token), DEST_TOKEN, address(bridge));

        vm.prank(RELAYER);
        vm.expectRevert(IRozoIntentsErrors.InsufficientAmount.selector);
        intents.slowFill(intentId);
    }

    function testRefundAfterDeadline() public {
        bytes32 intentId = _createIntent();
        vm.warp(block.timestamp + 3 hours);

        uint256 beforeBalance = token.balanceOf(SENDER);
        vm.prank(SENDER);
        intents.refund(intentId);

        assertEq(token.balanceOf(SENDER), beforeBalance + SOURCE_AMOUNT);
        assertEq(uint256(intents.intents(intentId).status), uint256(IntentStatus.REFUNDED));
    }

    function testRefundRevertsBeforeDeadline() public {
        bytes32 intentId = _createIntent();
        vm.prank(SENDER);
        vm.expectRevert(IRozoIntentsErrors.IntentNotExpired.selector);
        intents.refund(intentId);
    }

    function testRefundFromFillingState() public {
        bytes32 intentId = _createIntent();
        vm.prank(RELAYER);
        intents.fill(intentId);

        vm.warp(block.timestamp + 3 hours);
        vm.prank(SENDER);
        intents.refund(intentId);

        assertEq(uint256(intents.intents(intentId).status), uint256(IntentStatus.REFUNDED));
    }

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

        intents.setIntentRelayer(intentId, RELAYER);
        assertEq(intents.intents(intentId).relayer, RELAYER);
    }

    function testWithdrawFeesSendsBalanceToRecipient() public {
        bytes32 intentId = _createIntent();
        vm.prank(RELAYER);
        intents.fill(intentId);
        bytes memory payload =
            abi.encode(intentId, DESTINATION_AMOUNT, _addressToBytes32(RELAYER), RECEIVER_BYTES, DEST_TOKEN);
        bytes32 commandId = keccak256("cmd-fee");
        gateway.approve(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);
        vm.prank(address(gateway));
        intents.notify(commandId, SOURCE_CHAIN_NAME, SOURCE_CONTRACT, payload);

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

    function testFillAndNotifyTransfersAndSendsPayload() public {
        bytes32 intentId = keccak256("dest-intent");
        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        intents.fillAndNotify{value: 1 ether}(
            intentId, RECEIVER_BYTES, address(token), DESTINATION_AMOUNT, SOURCE_CHAIN_ID
        );
        vm.stopPrank();

        assertEq(token.balanceOf(RECEIVER), DESTINATION_AMOUNT);
        assertEq(keccak256(bytes(gateway.lastCall.destinationChain)), keccak256(bytes(CALLBACK_CHAIN_NAME)));
        assertEq(keccak256(bytes(gateway.lastCall.destinationAddress)), keccak256(bytes(DEST_CONTRACT)));
    }

    function testFillAndNotifyRevertsWithoutChainMapping() public {
        bytes32 intentId = keccak256("dest-intent2");
        vm.startPrank(RELAYER);
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.UntrustedSource.selector);
        intents.fillAndNotify(intentId, RECEIVER_BYTES, address(token), DESTINATION_AMOUNT, 9999);
        vm.stopPrank();
    }

    function testFillAndNotifyRevertsForNonRelayer() public {
        address stranger = address(0xABBA);
        token.mint(stranger, DESTINATION_AMOUNT);
        vm.startPrank(stranger);
        token.approve(address(intents), DESTINATION_AMOUNT);
        vm.expectRevert(IRozoIntentsErrors.NotRelayer.selector);
        intents.fillAndNotify(
            keccak256("intent-x"), RECEIVER_BYTES, address(token), DESTINATION_AMOUNT, SOURCE_CHAIN_ID
        );
        vm.stopPrank();
    }

    function _createIntent() internal returns (bytes32 intentId) {
        intentId = keccak256(abi.encodePacked("intent-", block.timestamp));
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
            REFUND
        );
        vm.stopPrank();
    }

    function _createIntentWithDestination(uint256 destinationAmount) internal returns (bytes32 intentId) {
        intentId = keccak256(abi.encodePacked("intent-dest-", destinationAmount, block.timestamp));
        vm.startPrank(SENDER);
        token.approve(address(intents), SOURCE_AMOUNT);
        intents.createIntent(
            intentId,
            address(token),
            SOURCE_AMOUNT,
            DEST_CHAIN_ID,
            DEST_TOKEN,
            RECEIVER_BYTES,
            destinationAmount,
            uint64(block.timestamp + 1 hours),
            REFUND
        );
        vm.stopPrank();
    }

    function _fee() internal view returns (uint256) {
        return (SOURCE_AMOUNT * intents.protocolFee()) / 10_000;
    }

    function _addressToBytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
