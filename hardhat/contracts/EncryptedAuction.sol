// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "fhevm/config/ZamaGatewayConfig.sol";
import "fhevm/gateway/GatewayCaller.sol";
import "fhevm-contracts/contracts/token/ERC20/extensions/ConfidentialERC20Mintable.sol";

/// @notice This contract implements an encrypted ERC20-like token with confidential balances using Zama's FHE library.
/// @dev It supports typical ERC20 functionality such as transferring tokens, minting, and setting allowances,
/// @dev but uses encrypted data types.
contract EncryptedAuction is
    SepoliaZamaFHEVMConfig,
    SepoliaZamaGatewayConfig,
    GatewayCaller,
    ConfidentialERC20Mintable
{   
    // @note `SECRET` is not so secret, since it is trivially encrypted and just to have a decryption test
    euint64 internal immutable SECRET;
    // @note `revealedSecret` will hold the decrypted result once the Gateway will relay the decryption of `SECRET`
    uint64 public revealedSecret;

    uint64 public totalTokens;     // Total tokens available for sale

    uint64 public startTime;       // Auction start time (in Unix timestamp)
    uint64 public endTime;         // Auction end time (in Unix timestamp)
    bool public finalized;          // Flag indicating if auction is finalized

    // Store each bid information
    struct Bid {
        address bidder;
        euint64 quantity; // Tokens the bidder wants to buy - ENCRYPTED
        euint64 price;    // Price (in wei) per token the bidder is willing to pay per token - ENCRYPTED
        uint256 totalDeposit;
        bool exists;
    }

    Bid[] public allBids;  // Array of all bids
    mapping(address => uint256) public bidderIndex; 
    // bidderIndex is 1-based: 0 means no bid. If 1-based, index in `allBids` is idx-1.

    // Events
    event AuctionCreated(
        address indexed owner,
        uint64 totalTokens,
        uint64 startTime,
        uint64 endTime
    );
    event BidPlaced(
        address indexed bidder,
        euint64 quantity,
        euint64 price
    );
    event AuctionFinalized(
        uint64 clearingPrice,
        uint64 tokensSold,
        uint64 totalProceeds
    );
    event Claimed(
        address indexed bidder,
        euint64 quantityPurchased,
        euint64 refund
    );

    /// @notice Constructor to initialize the token's name and symbol, and set up the owner
    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    constructor(
        string memory name_, 
        string memory symbol_,
        uint64 _totalTokens,
        uint64 _startTime,
        uint64 _endTime
        ) ConfidentialERC20Mintable(name_, symbol_, msg.sender) {
        require(_totalTokens > 0, "No tokens to auction");
        require(_startTime < _endTime, "Invalid auction window");

        totalTokens = _totalTokens;

        startTime = _startTime;
        endTime = _endTime;

        // Mint tokens to this contract so it can sell them.
        mint(address(this), _totalTokens);

        // Secret testing setup
        SECRET = TFHE.asEuint64(42);
        TFHE.allowThis(SECRET);

        emit AuctionCreated(msg.sender, _totalTokens, _startTime, _endTime);
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
     * @notice Place a bid for tokens at a given price (both provided as encrypted values).
     * @dev    The bidder must include a zero‐knowledge proof with each encrypted input
     *         that attests to its validity (e.g. non‑zero, within allowed bounds, etc).
     * @param encryptedQuantity The encrypted bid quantity.
     * @param encryptedPrice The encrypted bid price (in wei per token).
     * @param proofQuantity The proof attesting that the encrypted quantity is well formed.
     * @param proofPrice The proof attesting that the encrypted price is well formed.
     */
    function placeBid(
        einput encryptedQuantity,
        einput encryptedPrice,
        bytes calldata proofQuantity,
        bytes calldata proofPrice
    )
        external
        payable
        auctionOngoing
    {
        // Convert the provided encrypted inputs (with proofs) into FHE handles.
        euint64 quantity = TFHE.asEuint64(encryptedQuantity, proofQuantity);
        euint64 price    = TFHE.asEuint64(encryptedPrice, proofPrice);

        // Handle whether this bidder already has a bid stored.
        if (bidderIndex[msg.sender] == 0) {
            // New bid – simply add a new Bid struct with the encrypted parameters.
            allBids.push(Bid({
                bidder: msg.sender,
                quantity: quantity,
                price: price,
                totalDeposit: msg.value,
                exists: true
            }));
            bidderIndex[msg.sender] = allBids.length; // store 1-based index
        } else {
            // Updating an existing bid.
            uint256 idx = bidderIndex[msg.sender] - 1;
            Bid storage existingBid = allBids[idx];

            // Update the stored bid with the new encrypted values.
            existingBid.quantity = quantity;
            existingBid.price = price;
            existingBid.totalDeposit = existingBid.totalDeposit + msg.value;
        }

        // Make sure the bid values can be re‑encrypted by both the contract and the bidder.
        uint256 bidIdx = bidderIndex[msg.sender] - 1;
        Bid storage bid = allBids[bidIdx];
        TFHE.allowThis(bid.quantity);
        TFHE.allow(bid.quantity, msg.sender);
        TFHE.allowThis(bid.price);
        TFHE.allow(bid.price, msg.sender);

        // Emit an event that includes the encrypted bid parameters.
        emit BidPlaced(msg.sender, quantity, price);
    }
    
    /// @notice Request decryption of `SECRET`
    function requestSecret() public {
        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(SECRET);
        Gateway.requestDecryption(cts, this.callbackSecret.selector, 0, block.timestamp + 100, false);
    }

    /// @notice Callback function for `SECRET` decryption
    /// @param `decryptedValue` The decrypted 64-bit unsigned integer
    function callbackSecret(uint256, uint64 decryptedValue) public onlyGateway {
        revealedSecret = decryptedValue;
    }

    function finalizeAuction() internal {
        
    }
}
