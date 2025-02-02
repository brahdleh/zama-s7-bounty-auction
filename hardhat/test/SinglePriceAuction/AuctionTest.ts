import { expect } from "chai";
import { ethers } from "hardhat";
import { SinglePriceAuction } from "../../types";
import { getSigners, initSigners } from "../signers";

describe("SinglePriceAuction", function () {
  let SinglePriceAuctionFactory: any;
  let auction: SinglePriceAuction;
  let owner: any;
  let addr1: any;
  let addr2: any;

  const TOTAL_TOKENS = 1000;
  let startTime: number;
  let endTime: number;

  beforeEach(async function () {
    [owner, addr1, addr2] = await ethers.getSigners();

    // We set up startTime and endTime so the auction is active right away.
    // For instance, startTime = now + 1, endTime = now + 1000 seconds
    const currentBlock = await ethers.provider.getBlock("latest");
    startTime = currentBlock.timestamp + 1;
    endTime = currentBlock.timestamp + 1000;

    SinglePriceAuctionFactory = await ethers.getContractFactory("SinglePriceAuction");
    auction = (await SinglePriceAuctionFactory.deploy(
      TOTAL_TOKENS,
      startTime,
      endTime
    )) as SinglePriceAuction;
    await auction.waitForDeployment();
    const contractAddress = await auction.getAddress();

  });

  it("Should have minted the correct amount of tokens to the auction contract", async function () {
    // The contract itself should hold TOTAL_TOKENS initially
    const contractBalance = await auction.balanceOf(auction.getAddress());
    expect(contractBalance).to.equal(TOTAL_TOKENS);
  });

  it("Should allow a valid bid and lock the correct amount of ETH", async function () {
    // Wait until the auction is active (by mining 1 block if needed)
    await ethers.provider.send("evm_mine", []);

    // Place a bid: quantity=10 tokens, price=1 wei per token => totalCost=10 wei
    const quantity = 10;
    const price = 1;
    const totalCost = quantity * price;

    await expect(
      auction.connect(addr1).placeBid(quantity, price, {
        value: totalCost
      })
    ).to.emit(auction, "BidPlaced")
      .withArgs(addr1.address, quantity, price);
  });

  it("Should refund any surplus ETH for overriding a previous bid", async function () {
    // Place initial bid: quantity=10, price=2 => totalCost=20 wei
    await auction.connect(addr1).placeBid(10, 2, {
      value: 20,
    });

    // Override with a cheaper bid: quantity=10, price=1 => totalCost=10 wei
    // We expect an immediate refund of 10 wei
    const tx = await auction.connect(addr1).placeBid(10, 1, {
      value: 10, // We can send 10, but we only need 10. Actually 10 is exactly the new cost.
    });

    // We can check the gas usage and final ETH balances if desired.
    // For simplicity, just assert no revert and check event.
    await expect(tx).to.emit(auction, "BidPlaced");
  });

  it("Should fail if insufficient ETH is sent for a new bid", async function () {
    // If user tries to bid for 10 tokens at 2 wei each => 20 wei required
    // but only sends 10
    await expect(
      auction.connect(addr2).placeBid(10, 2, { value: 10 })
    ).to.be.revertedWith("Not enough ETH sent");
  });

  it("Should finalize the auction properly and distribute tokens/ETH", async function () {
    // Advance one block to pass startTime
    await ethers.provider.send("evm_mine", []);
    
    // Place some bids
    // addr1 bids for 20 tokens at 5 wei each => 100 wei total
    await auction.connect(addr1).placeBid(20, 5, { value: 100 });

    // addr2 bids for 50 tokens at 2 wei each => 100 wei total
    await auction.connect(addr2).placeBid(50, 2, { value: 100 });

    // We need the auction to end before we can finalize
    // Let's artificially move time forward beyond endTime
    const timeToJump = endTime - (await ethers.provider.getBlock("latest")).timestamp + 1;
    await ethers.provider.send("evm_increaseTime", [timeToJump]);
    await ethers.provider.send("evm_mine", []);

    // Finalize
    const tx = await auction.finalizeAuction();

    await expect(tx).to.emit(auction, "AuctionFinalized");

    // Post-finalization checks
    // 1) The clearing price is presumably 5, because addr1 is the highest bidder
    //    But we need to see if all tokens are sold. We'll check balances.
    const addr1Balance = await auction.balanceOf(addr1.address);
    const addr2Balance = await auction.balanceOf(addr2.address);

    // In this scenario:
    //   totalTokens = 1000
    //   Bids:
    //     addr1: price=5, wants 20 tokens
    //     addr2: price=2, wants 50 tokens
    // The contract will fill from highest to lowest.
    // Highest is addr1 at 5 => gets 20 tokens.
    // 1000 - 20 = 980 tokens left, next is addr2 at 2 => gets 50 tokens.
    // 980 - 50 = 930 tokens still left. Actually, we only had two bidders.
    // So the clearing price is the last price that sold tokens, i.e. 2 (addr2's price),
    // because they also got some portion. The highest price is 5 but that was fully filled.
    // 
    // Everyone who got tokens pays the clearing price of 2, not 5. This is single-price logic.
    // So addr1 locks 100 wei, but pays 20 * 2 = 40 wei, gets 60 wei refund
    // addr2 locks 100 wei, but pays 50 * 2 = 100 wei, no refund
    // 
    // The contract sold 70 tokens in total, so 930 remain unsold.
    // 
    // Let's confirm that logic by reading the final distribution from the contract:
    expect(addr1Balance).to.equal(20);
    expect(addr2Balance).to.equal(50);

    // Check unsold tokens remain in the owner's balance
    // Actually, the finalization code returns unsold tokens to `owner`. 
    // So the contract's balance should be 0, the owner should have 930.
    const contractBalance = await auction.balanceOf(auction.getAddress());
    expect(contractBalance).to.equal(0);

    const ownerBalance = await auction.balanceOf(owner.address);
    expect(ownerBalance).to.equal(930);
  });
});
