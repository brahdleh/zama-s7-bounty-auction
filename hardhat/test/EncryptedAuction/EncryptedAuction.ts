import { expect } from "chai";
import { network, ethers } from "hardhat";

import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";
import { createInstance } from "../instance";
import { reencryptEuint64 } from "../reencrypt";
import { getSigners, initSigners } from "../signers";
import { debug } from "../utils";
import { deployEncryptedAuction } from "./EncryptedAuction.fixture";

describe("EncryptedAuction", function () {
  before(async function () {
    await initSigners();
    this.signers = await getSigners();
    await initGateway();
  });

  beforeEach(async function () {
    this.auction = await deployEncryptedAuction();
    this.contractAddress = await this.auction.getAddress();
    this.fhevm = await createInstance();
  });

  it("Should have minted the correct amount of tokens to the auction contract", async function () {
    // The contract itself should hold TOTAL_TOKENS initially, as set in the fixture  
    const totalSupply = await this.auction.totalSupply();
    expect(totalSupply).to.equal(1000);
  });

  it("Should allow a valid bid and lock the correct amount of ETH", async function () {
    // Make sure the auction is active
    // (If the fixture sets a future start time, you may need to manipulate the block timestamp here.)
    await ethers.provider.send("evm_mine", []); // Mines a new block to move forward in time

    // Suppose we want to bid on 10 tokens, at 1 wei each => totalCost = 10 wei
    const rawQuantity = 10;
    const rawPrice = 1;
    const totalCost = rawQuantity * rawPrice; // 10

    // Create FHE-encrypted inputs for quantity and price
    const quantity = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    quantity.add64(rawQuantity);
    const encQuantity = await quantity.encrypt();

    const price = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    price.add64(rawPrice);
    const encPrice = await price.encrypt();

    // Place the bid via Alice, sending 10 wei
    const tx = await this.auction
      .connect(this.signers.alice)
      ["placeBid(bytes32,bytes32,bytes,bytes)"](
        encQuantity.handles[0],
        encPrice.handles[0],
        encQuantity.inputProof,
        encPrice.inputProof,
        { value: totalCost }
      );
    const receipt = await tx.wait();
    expect(receipt?.status).to.eq(1);

    // Check that the bid data is stored properly
    const idx = await this.auction.bidderIndex(this.signers.alice.address);
    expect(idx).to.equal(1, "Bidder index should be 1 for first-time bidder");

    // allBids is an array of structs; index in storage is idx-1
    const storedBid = await this.auction.allBids(0);
    expect(storedBid.bidder).to.equal(this.signers.alice.address, "Bidder address should match");
    expect(storedBid.totalDeposit).to.equal(totalCost, "Should lock exactly 10 wei for deposit");
    expect(storedBid.exists).to.be.true;
  });

  it("Should allow rebidding by the same bidder and update total deposit", async function () {
    // Move into the valid time window for the auction
    await ethers.provider.send("evm_mine", []);

    // First bid from Alice
    const rawQuantity1 = 5;
    const rawPrice1 = 2;
    const totalCost1 = rawQuantity1 * rawPrice1;

    const quantity1 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    quantity1.add64(rawQuantity1);
    const encQuantity1 = await quantity1.encrypt();

    const price1 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    price1.add64(rawPrice1);
    const encPrice1 = await price1.encrypt();

    await this.auction
      .connect(this.signers.alice)
      ["placeBid(bytes32,bytes32,bytes,bytes)"](
        encQuantity1.handles[0],
        encPrice1.handles[0],
        encQuantity1.inputProof,
        encPrice1.inputProof,
        { value: totalCost1 }
      );

    // Now rebid with new quantity and/or price (e.g., quantity=10, price=1)
    const rawQuantity2 = 10;
    const rawPrice2 = 1;
    const totalCost2 = rawQuantity2 * rawPrice2; // 10

    const quantity2 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    quantity2.add64(rawQuantity2);
    const encQuantity2 = await quantity2.encrypt();

    const price2 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    price2.add64(rawPrice2);
    const encPrice2 = await price2.encrypt();

    await this.auction
      .connect(this.signers.alice)
      ["placeBid(bytes32,bytes32,bytes,bytes)"](
        encQuantity2.handles[0],
        encPrice2.handles[0],
        encQuantity2.inputProof,
        encPrice2.inputProof,
        { value: totalCost2 }
      );

    // Check that deposit is the sum of both bids
    // The contract code accumulates deposit by doing `existingBid.totalDeposit += msg.value`
    const idx = await this.auction.bidderIndex(this.signers.alice.address);
    const storedBid = await this.auction.allBids(0);
    expect(storedBid.totalDeposit).to.equal(totalCost1 + totalCost2);
    expect(storedBid.exists).to.be.true;
  });

  it("Should allow auction finalization", async function () {
    // Move into the valid time window for the auction
    await ethers.provider.send("evm_mine", []);

    // First bid from Alice
    const rawQuantity1 = 5;
    const rawPrice1 = 2;
    const totalCost1 = rawQuantity1 * rawPrice1;

    const quantity1 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    quantity1.add64(rawQuantity1);
    const encQuantity1 = await quantity1.encrypt();

    const price1 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.alice.address);
    price1.add64(rawPrice1);
    const encPrice1 = await price1.encrypt();

    await this.auction
      .connect(this.signers.alice)
      ["placeBid(bytes32,bytes32,bytes,bytes)"](
        encQuantity1.handles[0],
        encPrice1.handles[0],
        encQuantity1.inputProof,
        encPrice1.inputProof,
        { value: totalCost1 }
      );

    // Now Second bid from a different wallet
    const rawQuantity2 = 10;
    const rawPrice2 = 1;
    const totalCost2 = rawQuantity2 * rawPrice2; // 10

    const quantity2 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.bob.address);
    quantity2.add64(rawQuantity2);
    const encQuantity2 = await quantity2.encrypt();

    const price2 = this.fhevm.createEncryptedInput(this.contractAddress, this.signers.bob.address);
    price2.add64(rawPrice2);
    const encPrice2 = await price2.encrypt();

    await this.auction
      .connect(this.signers.bob)
      ["placeBid(bytes32,bytes32,bytes,bytes)"](
        encQuantity2.handles[0],
        encPrice2.handles[0],
        encQuantity2.inputProof,
        encPrice2.inputProof,
        { value: totalCost2 }
      );
    
    //await ethers.provider.send("evm_increaseTime", [5000])
    //await ethers.provider.send("evm_mine", []);

    await this.auction.connect(this.signers.alice)["finalizeAuction()"]();

    
    //const finalized = await this.auction.finalized();
    //expect(finalized).to.equal(true);

  });
});
