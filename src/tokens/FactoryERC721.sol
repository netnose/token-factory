// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {MintRevenue} from "./MintRevenue.sol";

/// @title FactoryERC721
/// @notice ERC721 collection deployed as a minimal proxy clone by the TokenFactory.
///         - The owner can mint for free (`mint`, `mintBatch`).
///         - Anyone can `publicMint` while the sale is open, paying the owner-set price per token (0 = free).
///         - `maxSupply` caps all mints (0 = unlimited) and can only be lowered once set.
///         - `maxPerWallet` caps public mints per address (0 = unlimited).
///         Token ids start at 1 and increment; metadata lives at `baseURI + tokenId`.
contract FactoryERC721 is ERC721Upgradeable, MintRevenue {
    struct SaleConfig {
        uint256 price;
        uint64 maxSupply;
        uint64 maxPerWallet;
        bool active;
    }

    string private _baseTokenURI;
    uint256 public totalMinted;
    uint256 public price;
    uint64 public maxSupply;
    uint64 public maxPerWallet;
    bool public saleActive;
    /// @notice Tokens each address has bought through `publicMint`.
    mapping(address => uint256) public publicMinted;

    event BaseURIUpdated(string baseURI);
    event SaleUpdated(uint256 price, uint64 maxPerWallet, bool active);
    event MaxSupplyUpdated(uint64 maxSupply);

    error SaleNotActive();
    error ExceedsMaxSupply();
    error ExceedsWalletLimit();
    error InvalidMaxSupply();
    error ZeroQuantity();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata baseURI_,
        address owner_,
        uint16 protocolShareBps_,
        SaleConfig calldata sale
    ) external initializer {
        __ERC721_init(name_, symbol_);
        __MintRevenue_init(owner_, protocolShareBps_);
        _baseTokenURI = baseURI_;
        maxSupply = sale.maxSupply;
        _setSale(sale.price, sale.maxPerWallet, sale.active);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Buys `quantity` tokens at `price` each, minted to the caller. Returns the first token id.
    function publicMint(uint256 quantity) external payable returns (uint256 firstTokenId) {
        if (!saleActive) revert SaleNotActive();
        if (quantity == 0) revert ZeroQuantity();
        uint256 minted = publicMinted[msg.sender] + quantity;
        if (maxPerWallet != 0 && minted > maxPerWallet) revert ExceedsWalletLimit();
        publicMinted[msg.sender] = minted;
        _collect(price * quantity);
        return _mintMany(msg.sender, quantity);
    }

    /// @notice Owner mint of the next token id to `to`.
    function mint(address to) external onlyOwner returns (uint256 tokenId) {
        return _mintMany(to, 1);
    }

    /// @notice Owner mint of `quantity` consecutive token ids to `to`. Returns the first id.
    function mintBatch(address to, uint256 quantity) external onlyOwner returns (uint256 firstTokenId) {
        if (quantity == 0) revert ZeroQuantity();
        return _mintMany(to, quantity);
    }

    /// @dev Reserves the ids before minting, so re-entering through onERC721Received sees the updated supply.
    function _mintMany(address to, uint256 quantity) internal returns (uint256 firstTokenId) {
        firstTokenId = totalMinted + 1;
        uint256 newTotal = totalMinted + quantity;
        if (maxSupply != 0 && newTotal > maxSupply) revert ExceedsMaxSupply();
        totalMinted = newTotal;
        for (uint256 i; i < quantity; ++i) {
            _safeMint(to, firstTokenId + i);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Owner config
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets the public sale price (0 = free), per-wallet limit (0 = unlimited) and whether the sale is open.
    function setSale(uint256 price_, uint64 maxPerWallet_, bool active) external onlyOwner {
        _setSale(price_, maxPerWallet_, active);
    }

    /// @notice Caps the supply. Once capped it can only be lowered, and never below what is already minted.
    function setMaxSupply(uint64 maxSupply_) external onlyOwner {
        if (maxSupply_ == 0 || maxSupply_ < totalMinted || (maxSupply != 0 && maxSupply_ >= maxSupply)) {
            revert InvalidMaxSupply();
        }
        maxSupply = maxSupply_;
        emit MaxSupplyUpdated(maxSupply_);
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }

    function _setSale(uint256 price_, uint64 maxPerWallet_, bool active) internal {
        price = price_;
        maxPerWallet = maxPerWallet_;
        saleActive = active;
        emit SaleUpdated(price_, maxPerWallet_, active);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
}
