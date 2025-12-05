const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("RozoIntents", function () {
  // Constants
  const STELLAR_CHAIN_ID = 1500;
  const BASE_CHAIN_ID = 8453;
  const PROTOCOL_FEE = 3; // 3 bps = 0.03%
  const SOURCE_AMOUNT = ethers.parseUnits("1000", 6); // 1000 USDC (6 decimals)
  const DEST_AMOUNT = ethers.parseUnits("995", 6); // 995 USDC

  // Contracts
  let rozoIntents;
  let mockToken;
  let mockGateway;
  let mockGasService;

  // Accounts
  let owner;
  let sender;
  let relayer;
  let receiver;
  let feeRecipient;

  // Helper to create bytes32 address
  function addressToBytes32(address) {
    return ethers.zeroPadValue(address, 32);
  }

  // Helper to create intent ID
  function generateIntentId() {
    return ethers.keccak256(ethers.toUtf8Bytes(Date.now().toString() + Math.random()));
  }

  beforeEach(async function () {
    [owner, sender, relayer, receiver, feeRecipient] = await ethers.getSigners();

    // Deploy mocks
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20.deploy("Mock USDC", "USDC", 6);

    const MockAxelarGateway = await ethers.getContractFactory("MockAxelarGateway");
    mockGateway = await MockAxelarGateway.deploy();

    const MockAxelarGasService = await ethers.getContractFactory("MockAxelarGasService");
    mockGasService = await MockAxelarGasService.deploy();

    // Deploy RozoIntents with new constructor signature:
    // constructor(owner_, gateway_, gasService_, feeRecipient_)
    const RozoIntents = await ethers.getContractFactory("RozoIntents");
    rozoIntents = await RozoIntents.deploy(
      owner.address,
      await mockGateway.getAddress(),
      await mockGasService.getAddress(),
      feeRecipient.address
    );

    // Configure
    await rozoIntents.connect(owner).setProtocolFee(PROTOCOL_FEE);
    await rozoIntents.connect(owner).addRelayer(relayer.address);
    await rozoIntents.connect(owner).setTrustedContract("stellar", "STELLAR_CONTRACT_ADDRESS");
    await rozoIntents.connect(owner).setChainIdToAxelarName(STELLAR_CHAIN_ID, "stellar");
    await rozoIntents.connect(owner).setChainIdToAxelarName(BASE_CHAIN_ID, "base");

    // Fund sender with tokens
    await mockToken.mint(sender.address, SOURCE_AMOUNT * 10n);
  });

  describe("createIntent", function () {
    it("should create intent successfully", async function () {
      const intentId = generateIntentId();
      const deadline = BigInt(await time.latest()) + 3600n; // 1 hour from now
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      // Approve tokens
      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);

      // Create intent
      await expect(
        rozoIntents.connect(sender).createIntent(
          intentId,
          await mockToken.getAddress(),
          SOURCE_AMOUNT,
          STELLAR_CHAIN_ID,
          destTokenBytes32,
          receiverBytes32,
          DEST_AMOUNT,
          deadline,
          sender.address
        )
      ).to.emit(rozoIntents, "IntentCreated");

      // Verify intent
      const intent = await rozoIntents.intents(intentId);
      expect(intent.sender).to.equal(sender.address);
      expect(intent.sourceAmount).to.equal(SOURCE_AMOUNT);
      expect(intent.status).to.equal(0); // NEW
    });

    it("should revert on duplicate intent ID", async function () {
      const intentId = generateIntentId();
      const deadline = BigInt(await time.latest()) + 3600n;
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT * 2n);

      // Create first intent
      await rozoIntents.connect(sender).createIntent(
        intentId,
        await mockToken.getAddress(),
        SOURCE_AMOUNT,
        STELLAR_CHAIN_ID,
        destTokenBytes32,
        receiverBytes32,
        DEST_AMOUNT,
        deadline,
        sender.address
      );

      // Try to create second with same ID
      await expect(
        rozoIntents.connect(sender).createIntent(
          intentId,
          await mockToken.getAddress(),
          SOURCE_AMOUNT,
          STELLAR_CHAIN_ID,
          destTokenBytes32,
          receiverBytes32,
          DEST_AMOUNT,
          deadline,
          sender.address
        )
      ).to.be.revertedWithCustomError(rozoIntents, "IntentAlreadyExists");
    });

    it("should revert on expired deadline", async function () {
      const intentId = generateIntentId();
      const deadline = BigInt(await time.latest()) - 1n; // Past deadline
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);

      await expect(
        rozoIntents.connect(sender).createIntent(
          intentId,
          await mockToken.getAddress(),
          SOURCE_AMOUNT,
          STELLAR_CHAIN_ID,
          destTokenBytes32,
          receiverBytes32,
          DEST_AMOUNT,
          deadline,
          sender.address
        )
      ).to.be.revertedWithCustomError(rozoIntents, "InvalidDeadline");
    });
  });

  describe("fill", function () {
    let intentId;
    let deadline;

    beforeEach(async function () {
      intentId = generateIntentId();
      deadline = BigInt(await time.latest()) + 3600n;
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);
      await rozoIntents.connect(sender).createIntent(
        intentId,
        await mockToken.getAddress(),
        SOURCE_AMOUNT,
        STELLAR_CHAIN_ID,
        destTokenBytes32,
        receiverBytes32,
        DEST_AMOUNT,
        deadline,
        sender.address
      );
    });

    it("should allow relayer to fill", async function () {
      await expect(rozoIntents.connect(relayer).fill(intentId))
        .to.emit(rozoIntents, "IntentFilling")
        .withArgs(intentId, relayer.address);

      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(1); // FILLING
      expect(intent.relayer).to.equal(relayer.address);
    });

    it("should revert if not relayer", async function () {
      await expect(rozoIntents.connect(sender).fill(intentId))
        .to.be.revertedWithCustomError(rozoIntents, "NotRelayer");
    });

    it("should revert if intent expired", async function () {
      await time.increase(3700); // Past deadline

      await expect(rozoIntents.connect(relayer).fill(intentId))
        .to.be.revertedWithCustomError(rozoIntents, "IntentExpired");
    });

    it("should revert if already filled", async function () {
      await rozoIntents.connect(relayer).fill(intentId);

      await expect(rozoIntents.connect(relayer).fill(intentId))
        .to.be.revertedWithCustomError(rozoIntents, "InvalidStatus");
    });
  });

  describe("refund", function () {
    let intentId;
    let deadline;

    beforeEach(async function () {
      intentId = generateIntentId();
      deadline = BigInt(await time.latest()) + 3600n;
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);
      await rozoIntents.connect(sender).createIntent(
        intentId,
        await mockToken.getAddress(),
        SOURCE_AMOUNT,
        STELLAR_CHAIN_ID,
        destTokenBytes32,
        receiverBytes32,
        DEST_AMOUNT,
        deadline,
        sender.address
      );
    });

    it("should allow refund after deadline", async function () {
      await time.increase(3700); // Past deadline

      const balanceBefore = await mockToken.balanceOf(sender.address);

      await expect(rozoIntents.connect(sender).refund(intentId))
        .to.emit(rozoIntents, "IntentRefunded")
        .withArgs(intentId, sender.address, SOURCE_AMOUNT);

      const balanceAfter = await mockToken.balanceOf(sender.address);
      expect(balanceAfter - balanceBefore).to.equal(SOURCE_AMOUNT);

      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(4); // REFUNDED
    });

    it("should revert if not expired", async function () {
      await expect(rozoIntents.connect(sender).refund(intentId))
        .to.be.revertedWithCustomError(rozoIntents, "IntentNotExpired");
    });

    it("should allow refund from FILLING status", async function () {
      await rozoIntents.connect(relayer).fill(intentId);
      await time.increase(3700); // Past deadline

      await expect(rozoIntents.connect(sender).refund(intentId))
        .to.emit(rozoIntents, "IntentRefunded");

      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(4); // REFUNDED
    });
  });

  describe("fillAndNotify", function () {
    it("should execute fillAndNotify successfully", async function () {
      const intentId = generateIntentId();
      const receiverBytes32 = addressToBytes32(receiver.address);

      // Fund relayer with tokens
      await mockToken.mint(relayer.address, DEST_AMOUNT);
      await mockToken.connect(relayer).approve(await rozoIntents.getAddress(), DEST_AMOUNT);

      // Set up trusted contract for BASE chain
      await rozoIntents.connect(owner).setTrustedContract("base", "BASE_CONTRACT_ADDRESS");

      await expect(
        rozoIntents.connect(relayer).fillAndNotify(
          intentId,
          receiverBytes32,
          await mockToken.getAddress(),
          DEST_AMOUNT,
          BASE_CHAIN_ID
        )
      ).to.emit(rozoIntents, "FillAndNotifySent");

      // Verify tokens transferred
      expect(await mockToken.balanceOf(receiver.address)).to.equal(DEST_AMOUNT);

      // Verify Axelar message was sent
      expect(await mockGateway.getMessageCount()).to.equal(1);
    });

    it("should revert if not relayer", async function () {
      const intentId = generateIntentId();
      const receiverBytes32 = addressToBytes32(receiver.address);

      await expect(
        rozoIntents.connect(sender).fillAndNotify(
          intentId,
          receiverBytes32,
          await mockToken.getAddress(),
          DEST_AMOUNT,
          BASE_CHAIN_ID
        )
      ).to.be.revertedWithCustomError(rozoIntents, "NotRelayer");
    });
  });

  describe("notify (Axelar callback)", function () {
    let intentId;
    let deadline;
    let receiverBytes32;
    let destTokenBytes32;

    beforeEach(async function () {
      intentId = generateIntentId();
      deadline = BigInt(await time.latest()) + 3600n;
      receiverBytes32 = addressToBytes32(receiver.address);
      destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);
      await rozoIntents.connect(sender).createIntent(
        intentId,
        await mockToken.getAddress(),
        SOURCE_AMOUNT,
        STELLAR_CHAIN_ID,
        destTokenBytes32,
        receiverBytes32,
        DEST_AMOUNT,
        deadline,
        sender.address
      );
    });

    it("should complete fill from FILLING status", async function () {
      // Relayer fills first
      await rozoIntents.connect(relayer).fill(intentId);

      // Build payload
      const relayerBytes32 = addressToBytes32(relayer.address);
      const payload = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint256", "bytes32", "bytes32", "bytes32"],
        [intentId, DEST_AMOUNT, relayerBytes32, receiverBytes32, destTokenBytes32]
      );

      const commandId = ethers.keccak256(ethers.toUtf8Bytes("command-1"));

      // Set command as validated
      await mockGateway.setValidated(commandId, true);

      // Call notify from gateway
      const relayerBalanceBefore = await mockToken.balanceOf(relayer.address);

      // Impersonate the gateway to call notify
      const gatewayAddress = await mockGateway.getAddress();
      await ethers.provider.send("hardhat_impersonateAccount", [gatewayAddress]);
      await owner.sendTransaction({ to: gatewayAddress, value: ethers.parseEther("1") });
      const gatewaySigner = await ethers.getSigner(gatewayAddress);

      await rozoIntents.connect(gatewaySigner).notify(
        commandId,
        "stellar",
        "STELLAR_CONTRACT_ADDRESS",
        payload
      );

      // Verify intent is filled
      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(2); // FILLED

      // Verify relayer received payment (minus fee)
      const expectedPayout = SOURCE_AMOUNT - (SOURCE_AMOUNT * BigInt(PROTOCOL_FEE) / 10000n);
      const relayerBalanceAfter = await mockToken.balanceOf(relayer.address);
      expect(relayerBalanceAfter - relayerBalanceBefore).to.equal(expectedPayout);

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [gatewayAddress]);
    });

    it("should complete fill from NEW status (skip fill())", async function () {
      // Build payload - relayer didn't call fill() first
      const relayerBytes32 = addressToBytes32(relayer.address);
      const payload = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint256", "bytes32", "bytes32", "bytes32"],
        [intentId, DEST_AMOUNT, relayerBytes32, receiverBytes32, destTokenBytes32]
      );

      const commandId = ethers.keccak256(ethers.toUtf8Bytes("command-2"));
      await mockGateway.setValidated(commandId, true);

      // Impersonate the gateway
      const gatewayAddress = await mockGateway.getAddress();
      await ethers.provider.send("hardhat_impersonateAccount", [gatewayAddress]);
      await owner.sendTransaction({ to: gatewayAddress, value: ethers.parseEther("1") });
      const gatewaySigner = await ethers.getSigner(gatewayAddress);

      await rozoIntents.connect(gatewaySigner).notify(
        commandId,
        "stellar",
        "STELLAR_CONTRACT_ADDRESS",
        payload
      );

      // Verify intent is filled and relayer recorded from payload
      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(2); // FILLED
      expect(intent.relayer).to.equal(relayer.address);

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [gatewayAddress]);
    });

    it("should set FAILED on receiver mismatch", async function () {
      await rozoIntents.connect(relayer).fill(intentId);

      // Wrong receiver in payload
      const wrongReceiverBytes32 = addressToBytes32(owner.address);
      const relayerBytes32 = addressToBytes32(relayer.address);
      const payload = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint256", "bytes32", "bytes32", "bytes32"],
        [intentId, DEST_AMOUNT, relayerBytes32, wrongReceiverBytes32, destTokenBytes32]
      );

      const commandId = ethers.keccak256(ethers.toUtf8Bytes("command-3"));
      await mockGateway.setValidated(commandId, true);

      // Impersonate the gateway
      const gatewayAddress = await mockGateway.getAddress();
      await ethers.provider.send("hardhat_impersonateAccount", [gatewayAddress]);
      await owner.sendTransaction({ to: gatewayAddress, value: ethers.parseEther("1") });
      const gatewaySigner = await ethers.getSigner(gatewayAddress);

      await expect(
        rozoIntents.connect(gatewaySigner).notify(
          commandId,
          "stellar",
          "STELLAR_CONTRACT_ADDRESS",
          payload
        )
      ).to.emit(rozoIntents, "IntentFailed");

      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(3); // FAILED

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [gatewayAddress]);
    });

    it("should set FAILED on insufficient amount", async function () {
      await rozoIntents.connect(relayer).fill(intentId);

      const relayerBytes32 = addressToBytes32(relayer.address);
      const insufficientAmount = DEST_AMOUNT - 1n; // Less than required
      const payload = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint256", "bytes32", "bytes32", "bytes32"],
        [intentId, insufficientAmount, relayerBytes32, receiverBytes32, destTokenBytes32]
      );

      const commandId = ethers.keccak256(ethers.toUtf8Bytes("command-4"));
      await mockGateway.setValidated(commandId, true);

      // Impersonate the gateway
      const gatewayAddress = await mockGateway.getAddress();
      await ethers.provider.send("hardhat_impersonateAccount", [gatewayAddress]);
      await owner.sendTransaction({ to: gatewayAddress, value: ethers.parseEther("1") });
      const gatewaySigner = await ethers.getSigner(gatewayAddress);

      await rozoIntents.connect(gatewaySigner).notify(
        commandId,
        "stellar",
        "STELLAR_CONTRACT_ADDRESS",
        payload
      );

      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(3); // FAILED

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [gatewayAddress]);
    });

    it("should revert on untrusted source", async function () {
      const relayerBytes32 = addressToBytes32(relayer.address);
      const payload = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint256", "bytes32", "bytes32", "bytes32"],
        [intentId, DEST_AMOUNT, relayerBytes32, receiverBytes32, destTokenBytes32]
      );

      const commandId = ethers.keccak256(ethers.toUtf8Bytes("command-5"));
      await mockGateway.setValidated(commandId, true);

      // Impersonate the gateway
      const gatewayAddress = await mockGateway.getAddress();
      await ethers.provider.send("hardhat_impersonateAccount", [gatewayAddress]);
      await owner.sendTransaction({ to: gatewayAddress, value: ethers.parseEther("1") });
      const gatewaySigner = await ethers.getSigner(gatewayAddress);

      await expect(
        rozoIntents.connect(gatewaySigner).notify(
          commandId,
          "stellar",
          "WRONG_CONTRACT_ADDRESS", // Untrusted source
          payload
        )
      ).to.be.revertedWithCustomError(rozoIntents, "UntrustedSource");

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [gatewayAddress]);
    });
  });

  describe("Admin functions", function () {
    it("should set protocol fee", async function () {
      await rozoIntents.connect(owner).setProtocolFee(10);
      expect(await rozoIntents.protocolFee()).to.equal(10);
    });

    it("should revert if fee too high", async function () {
      await expect(rozoIntents.connect(owner).setProtocolFee(31))
        .to.be.revertedWithCustomError(rozoIntents, "InvalidFee");
    });

    it("should add and remove relayer", async function () {
      const newRelayer = owner.address;
      await rozoIntents.connect(owner).addRelayer(newRelayer);
      expect(await rozoIntents.relayers(newRelayer)).to.be.true;

      await rozoIntents.connect(owner).removeRelayer(newRelayer);
      expect(await rozoIntents.relayers(newRelayer)).to.be.false;
    });

    it("should allow admin to change intent status", async function () {
      const intentId = generateIntentId();
      const deadline = BigInt(await time.latest()) + 3600n;
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);
      await rozoIntents.connect(sender).createIntent(
        intentId,
        await mockToken.getAddress(),
        SOURCE_AMOUNT,
        STELLAR_CHAIN_ID,
        destTokenBytes32,
        receiverBytes32,
        DEST_AMOUNT,
        deadline,
        sender.address
      );

      await expect(rozoIntents.connect(owner).setIntentStatus(intentId, 3)) // FAILED
        .to.emit(rozoIntents, "IntentStatusChanged")
        .withArgs(intentId, 0, 3, owner.address);

      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(3); // FAILED
    });

    it("should allow admin to refund", async function () {
      const intentId = generateIntentId();
      const deadline = BigInt(await time.latest()) + 3600n;
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);
      await rozoIntents.connect(sender).createIntent(
        intentId,
        await mockToken.getAddress(),
        SOURCE_AMOUNT,
        STELLAR_CHAIN_ID,
        destTokenBytes32,
        receiverBytes32,
        DEST_AMOUNT,
        deadline,
        sender.address
      );

      await expect(rozoIntents.connect(owner).adminRefund(intentId))
        .to.emit(rozoIntents, "IntentRefunded");

      const intent = await rozoIntents.intents(intentId);
      expect(intent.status).to.equal(4); // REFUNDED
    });

    it("should withdraw accumulated fees", async function () {
      // Create and fill an intent to accumulate fees
      const intentId = generateIntentId();
      const deadline = BigInt(await time.latest()) + 3600n;
      const receiverBytes32 = addressToBytes32(receiver.address);
      const destTokenBytes32 = addressToBytes32(await mockToken.getAddress());

      await mockToken.connect(sender).approve(await rozoIntents.getAddress(), SOURCE_AMOUNT);
      await rozoIntents.connect(sender).createIntent(
        intentId,
        await mockToken.getAddress(),
        SOURCE_AMOUNT,
        STELLAR_CHAIN_ID,
        destTokenBytes32,
        receiverBytes32,
        DEST_AMOUNT,
        deadline,
        sender.address
      );

      await rozoIntents.connect(relayer).fill(intentId);

      // Execute notify to accumulate fees
      const relayerBytes32 = addressToBytes32(relayer.address);
      const payload = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint256", "bytes32", "bytes32", "bytes32"],
        [intentId, DEST_AMOUNT, relayerBytes32, receiverBytes32, destTokenBytes32]
      );
      const commandId = ethers.keccak256(ethers.toUtf8Bytes("command-fees"));
      await mockGateway.setValidated(commandId, true);

      // Impersonate the gateway
      const gatewayAddress = await mockGateway.getAddress();
      await ethers.provider.send("hardhat_impersonateAccount", [gatewayAddress]);
      await owner.sendTransaction({ to: gatewayAddress, value: ethers.parseEther("1") });
      const gatewaySigner = await ethers.getSigner(gatewayAddress);

      await rozoIntents.connect(gatewaySigner).notify(
        commandId,
        "stellar",
        "STELLAR_CONTRACT_ADDRESS",
        payload
      );

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [gatewayAddress]);

      // Verify fees accumulated
      const expectedFee = SOURCE_AMOUNT * BigInt(PROTOCOL_FEE) / 10000n;
      expect(await rozoIntents.accumulatedFees(await mockToken.getAddress())).to.equal(expectedFee);

      // Withdraw fees (now only owner can withdraw)
      const feeRecipientBalanceBefore = await mockToken.balanceOf(feeRecipient.address);
      await rozoIntents.connect(owner).withdrawFees(await mockToken.getAddress());
      const feeRecipientBalanceAfter = await mockToken.balanceOf(feeRecipient.address);

      expect(feeRecipientBalanceAfter - feeRecipientBalanceBefore).to.equal(expectedFee);
      expect(await rozoIntents.accumulatedFees(await mockToken.getAddress())).to.equal(0);
    });
  });
});
