// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title SinglePriceAuction
 * @notice Demonstration of a Single-Price (Uniform-Price) Auction
 *         where bidders pay only in ETH, and the contract mints the
 *         tokens being sold. The tokens are minted to this contract
 *         (as the holder/seller) upon creation.
 *
 * @dev This code is for demonstration purposes and is *not* production ready.
 */
contract SinglePriceAuction is ERC20 {
    address public owner;           // Auction creator
    uint256 public totalTokens;     // Total tokens available for sale

    uint256 public startTime;       // Auction start time (in Unix timestamp)
    uint256 public endTime;         // Auction end time (in Unix timestamp)
    bool public finalized;          // Flag indicating if auction is finalized

    // Store each bid information
    struct Bid {
        address bidder;
        uint256 quantity; // Tokens the bidder wants to buy
        uint256 price;    // Price (in wei) per token the bidder is willing to pay
        bool exists;
    }

    Bid[] public allBids;  // Array of all bids
    mapping(address => uint256) public bidderIndex; 
    // bidderIndex is 1-based: 0 means no bid. If 1-based, index in `allBids` is idx-1.

    // Events
    event AuctionCreated(
        address indexed owner,
        uint256 totalTokens,
        uint256 startTime,
        uint256 endTime
    );
    event BidPlaced(
        address indexed bidder,
        uint256 quantity,
        uint256 price
    );
    event AuctionFinalized(
        uint256 clearingPrice,
        uint256 tokensSold,
        uint256 totalProceeds
    );
    event Claimed(
        address indexed bidder,
        uint256 quantityPurchased,
        uint256 refund
    );

    /**
     * @dev The constructor also mints `totalTokens` to this contract
     *      (making this contract the "seller").
     */
    constructor(
        uint256 _totalTokens,
        uint256 _startTime,
        uint256 _endTime
    ) ERC20("AuctionToken", "ATKN") {
        require(_totalTokens > 0, "No tokens to auction");
        require(_startTime < _endTime, "Invalid auction window");

        owner = msg.sender;
        totalTokens = _totalTokens;

        startTime = _startTime;
        endTime = _endTime;

        // Mint tokens to this contract so it can sell them.
        _mint(address(this), _totalTokens);

        emit AuctionCreated(msg.sender, _totalTokens, _startTime, _endTime);
    }

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier auctionOngoing() {
        require(block.timestamp >= startTime && block.timestamp < endTime, "Auction not active");
        _;
    }

    modifier auctionEnded() {
        require(block.timestamp >= endTime, "Auction not ended");
        _;
    }

    /**
     * @notice Place a bid for `quantity` tokens at a `price` (in wei per token).
     * @dev    Caller sends ETH = (quantity * price). Surplus ETH over totalCost
     *         (if any) stays locked in the contract until final settlement.
     */
    function placeBid(uint256 quantity, uint256 price) external payable auctionOngoing {
        require(quantity > 0 && price > 0, "Invalid bid parameters");

        uint256 totalCost = quantity * price;
        require(msg.value >= totalCost, "Not enough ETH sent");

        // If there is an existing bid by the same bidder, handle override
        if (bidderIndex[msg.sender] == 0) {
            // No existing bid: create a new one
            allBids.push(Bid({
                bidder: msg.sender,
                quantity: quantity,
                price: price,
                exists: true
            }));
            bidderIndex[msg.sender] = allBids.length; // store 1-based index
        } else {
            // Update existing bid
            uint256 idx = bidderIndex[msg.sender] - 1;
            Bid storage existingBid = allBids[idx];

            uint256 oldCost = existingBid.quantity * existingBid.price;

            // If new totalCost < oldCost, refund difference right now
            if (totalCost < oldCost) {
                uint256 refund = oldCost - totalCost;
                payable(msg.sender).transfer(refund);
            }
            // If totalCost > oldCost, bidder must have sent enough additional ETH
            // in this transaction. The require(msg.value >= totalCost) check covers that.

            // Update the existing bid to the new terms
            existingBid.quantity = quantity;
            existingBid.price = price;
        }

        // If the bidder sends more ETH than totalCost for some reason, it remains locked
        // in the contract until the auction finalizes (or if they update their bid again).

        emit BidPlaced(msg.sender, quantity, price);
    }

    /**
     * @notice Finalize the auction once it has ended:
     *         1) Determine the clearing price (last price that sells remaining tokens).
     *         2) Everyone allocated tokens at that clearing price.
     *         3) Refund surplus deposits.
     *         4) Transfer proceeds to the contract owner (seller).
     *         5) Return any unsold tokens to the owner (if not fully sold).
     */
    function finalizeAuction() external auctionEnded {
        require(!finalized, "Auction already finalized");
        finalized = true;

        // Sort bids by descending price
        sortBidsDescending();

        // Determine clearing price by allocating tokens from highest to lowest bidder
        uint256 tokensRemaining = totalTokens;
        uint256 clearingPrice = 0;
        uint256[] memory tokensWon = new uint256[](allBids.length);

        for (uint256 i = 0; i < allBids.length && tokensRemaining > 0; i++) {
            if (!allBids[i].exists) continue;
            uint256 quantityWanted = allBids[i].quantity;

            if (quantityWanted > tokensRemaining) {
                quantityWanted = tokensRemaining; // partial fill for last bidder
            }

            if (quantityWanted > 0) {
                clearingPrice = allBids[i].price;
                tokensWon[i] = quantityWanted;
                tokensRemaining -= quantityWanted;
            }
        }

        // Now we know the clearingPrice. Everyone who got tokens pays (clearingPrice * tokensWon).
        // Non-winners or non-filled portion get full or partial refund.

        uint256 totalProceeds = 0;

        for (uint256 i = 0; i < allBids.length; i++) {
            if (!allBids[i].exists) continue;

            uint256 allocated = tokensWon[i];
            uint256 bidDeposit = allBids[i].quantity * allBids[i].price;
            if (allocated == 0) {
                // This bidder wins no tokens -> full refund
                refundBid(allBids[i].bidder, 0, bidDeposit);
            } else {
                // Bidder gets allocated tokens. They owe clearingPrice * allocated
                uint256 costAtClearing = clearingPrice * allocated;
                totalProceeds += costAtClearing;

                // If their locked deposit is bigger than costAtClearing, refund the difference
                uint256 refund = 0;
                if (bidDeposit > costAtClearing) {
                    refund = bidDeposit - costAtClearing;
                }

                // Transfer the purchased tokens
                _transfer(address(this), allBids[i].bidder, allocated);

                // Refund any leftover
                refundBid(allBids[i].bidder, allocated, refund);
            }
        }

        // Transfer proceeds in ETH to the auction owner
        payable(owner).transfer(totalProceeds);

        // Return unsold tokens (if not fully sold) to owner
        if (tokensRemaining > 0) {
            _transfer(address(this), owner, tokensRemaining);
        }

        emit AuctionFinalized(clearingPrice, totalTokens - tokensRemaining, totalProceeds);
    }

    /**
     * @notice Refund a bidder in ETH.
     * @param bidder The address receiving the refund
     * @param quantityPurchased For logging purposes, how many tokens were purchased
     * @param amountToRefund The refund amount in wei
     */
    function refundBid(
        address bidder,
        uint256 quantityPurchased,
        uint256 amountToRefund
    ) internal {
        if (amountToRefund > 0) {
            payable(bidder).transfer(amountToRefund);
        }
        emit Claimed(bidder, quantityPurchased, amountToRefund);
    }

    /**
     * @notice Sorts all bids in descending order of price (naive bubble sort).
     *         In a real-world scenario, consider a more efficient or off-chain approach.
     */
    function sortBidsDescending() internal {
        uint256 n = allBids.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n - 1; j++) {
                if (allBids[j].price < allBids[j + 1].price) {
                    // Swap
                    Bid memory temp = allBids[j];
                    allBids[j] = allBids[j + 1];
                    allBids[j + 1] = temp;
                }
            }
        }
    }
}
