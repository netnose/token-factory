// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MintRevenue} from "./MintRevenue.sol";

/// @title FactoryERC721
/// @notice ERC721 collection deployed as a minimal proxy clone by the TokenFactory.
///         - The owner can mint for free (`mint`, `mintBatch`).
///         - Anyone can `publicMint` while the sale is open, paying the owner-set price per token (0 = free).
///         - `maxSupply` caps all mints (0 = unlimited) and can only be lowered once set.
///         - `maxPerWallet` caps public mints per address (0 = unlimited).
///         - ERC-2981 royalties (max 10%), set at creation and managed by the owner.
///         - EIP-4906: changing the base URI emits `BatchMetadataUpdate` so marketplaces refresh every token.
///         - EIP-7572: collection-level metadata via `contractURI()`.
///         Token ids start at 1 and increment; metadata lives at `baseURI + tokenId`.
contract FactoryERC721 is ERC721Upgradeable, MintRevenue, IERC4906 {
    struct SaleConfig {
        uint256 price;
        uint64 maxSupply;
        uint64 maxPerWallet;
        bool active;
    }

    struct RoyaltyConfig {
        /// Defaults to the owner when zero.
        address receiver;
        /// Max 1000 (10%). 0 = no royalty.
        uint96 bps;
    }

    /// @dev Everything `initialize` needs, in one struct (too many separate arguments exceed the EVM stack).
    struct InitParams {
        string name;
        string symbol;
        string baseURI;
        string contractURI;
        address owner;
        uint16 protocolShareBps;
        SaleConfig sale;
        RoyaltyConfig royalty;
    }

    string private _baseTokenURI;
    uint256 public totalMinted;
    uint256 public price;
    uint64 public maxSupply;
    uint64 public maxPerWallet;
    bool public saleActive;
    /// @notice Tokens each address has bought through `publicMint`.
    mapping(address => uint256) public publicMinted;

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

    function initialize(InitParams calldata p) external initializer {
        __ERC721_init(p.name, p.symbol);
        __MintRevenue_init(p.owner, p.protocolShareBps, p.contractURI, p.royalty.receiver, p.royalty.bps);
        _baseTokenURI = p.baseURI;
        maxSupply = p.sale.maxSupply;
        _setSale(p.sale.price, p.sale.maxPerWallet, p.sale.active);
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
        firstTokenId = _reserve(quantity);
        _collect(price * quantity);
        _mintIds(msg.sender, firstTokenId, quantity);
    }

    /// @notice Owner mint of the next token id to `to`.
    function mint(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = _reserve(1);
        _mintIds(to, tokenId, 1);
    }

    /// @notice Owner mint of `quantity` consecutive token ids to `to`. Returns the first id.
    function mintBatch(address to, uint256 quantity) external onlyOwner returns (uint256 firstTokenId) {
        if (quantity == 0) revert ZeroQuantity();
        firstTokenId = _reserve(quantity);
        _mintIds(to, firstTokenId, quantity);
    }

    /// @dev Books `quantity` ids against the supply cap before any external call (payment forwarding, the
    ///      onERC721Received callback), so re-entering sees the updated supply. Returns the first reserved id.
    function _reserve(uint256 quantity) internal returns (uint256 firstTokenId) {
        firstTokenId = totalMinted + 1;
        uint256 newTotal = totalMinted + quantity;
        if (maxSupply != 0 && newTotal > maxSupply) revert ExceedsMaxSupply();
        totalMinted = newTotal;
    }

    function _mintIds(address to, uint256 firstTokenId, uint256 quantity) internal {
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

    /// @notice Changes where every token's metadata lives (`baseURI + tokenId`). Emits the EIP-4906 batch event over
    ///         the whole id range, so marketplaces refresh all tokens.
    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit BatchMetadataUpdate(0, type(uint256).max);
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

    /// @dev ERC-721, ERC-721 Metadata, ERC-2981, ERC-165, and EIP-4906 (whose interface id is fixed by the EIP to
    ///      0x49064906).
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC2981Upgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }
}
