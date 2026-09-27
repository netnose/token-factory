// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {MintRevenue} from "./MintRevenue.sol";

/// @title FactoryERC1155
/// @notice ERC1155 collection deployed as a minimal proxy clone by the TokenFactory.
///         - The owner can mint any id for free (`mint`, `mintBatch`).
///         - Each token id has its own public sale: price (0 = free), max supply (0 = unlimited, can only be lowered
///           once set), per-wallet limit (0 = unlimited) and an open/closed switch.
///         - Anyone can `publicMint(id, quantity)` while that id's sale is open.
///         - Each token id can have its own metadata URI; ids without one use the collection's base URI.
///         - ERC-2981 royalties (max 10%): collection-wide default, overridable per id.
///         `name` and `symbol` are exposed for wallets and marketplaces.
contract FactoryERC1155 is ERC1155Upgradeable, MintRevenue {
    struct Sale {
        uint256 price;
        uint64 maxSupply;
        uint64 maxPerWallet;
        bool active;
    }

    string public name;
    string public symbol;
    mapping(uint256 id => Sale) public sales;
    /// @notice Total minted per id, by the owner and publicly.
    mapping(uint256 id => uint256) public totalMinted;
    /// @notice Amount of each id each address has bought through `publicMint`.
    mapping(uint256 id => mapping(address => uint256)) public publicMinted;
    mapping(uint256 id => string) private _tokenURIs;

    event SaleUpdated(uint256 indexed id, uint256 price, uint64 maxPerWallet, bool active);
    event MaxSupplyUpdated(uint256 indexed id, uint64 maxSupply);

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
        string calldata uri_,
        address owner_,
        uint16 protocolShareBps_,
        address royaltyReceiver,
        uint96 royaltyBps
    ) external initializer {
        __ERC1155_init(uri_);
        __MintRevenue_init(owner_, protocolShareBps_, royaltyReceiver, royaltyBps);
        name = name_;
        symbol = symbol_;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Buys `quantity` of token `id` at that id's price, minted to the caller.
    function publicMint(uint256 id, uint256 quantity) external payable {
        Sale memory sale = sales[id];
        if (!sale.active) revert SaleNotActive();
        if (quantity == 0) revert ZeroQuantity();
        uint256 minted = publicMinted[id][msg.sender] + quantity;
        if (sale.maxPerWallet != 0 && minted > sale.maxPerWallet) revert ExceedsWalletLimit();
        publicMinted[id][msg.sender] = minted;
        _reserve(id, quantity);
        _collect(sale.price * quantity);
        _mint(msg.sender, id, quantity, "");
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyOwner {
        _reserve(id, amount);
        _mint(to, id, amount, data);
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data)
        external
        onlyOwner
    {
        for (uint256 i; i < ids.length; ++i) {
            _reserve(ids[i], amounts[i]);
        }
        _mintBatch(to, ids, amounts, data);
    }

    /// @dev Books supply before minting, so re-entering through onERC1155Received sees the updated supply.
    function _reserve(uint256 id, uint256 amount) internal {
        uint256 newTotal = totalMinted[id] + amount;
        uint64 cap = sales[id].maxSupply;
        if (cap != 0 && newTotal > cap) revert ExceedsMaxSupply();
        totalMinted[id] = newTotal;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Owner config
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets token `id`'s public sale price (0 = free), per-wallet limit (0 = unlimited) and open/closed state.
    function setSale(uint256 id, uint256 price, uint64 maxPerWallet, bool active) external onlyOwner {
        Sale storage sale = sales[id];
        sale.price = price;
        sale.maxPerWallet = maxPerWallet;
        sale.active = active;
        emit SaleUpdated(id, price, maxPerWallet, active);
    }

    /// @notice Caps token `id`'s supply. Once capped it can only be lowered, and never below what is already minted.
    function setMaxSupply(uint256 id, uint64 maxSupply) external onlyOwner {
        uint64 current = sales[id].maxSupply;
        if (maxSupply == 0 || maxSupply < totalMinted[id] || (current != 0 && maxSupply >= current)) {
            revert InvalidMaxSupply();
        }
        sales[id].maxSupply = maxSupply;
        emit MaxSupplyUpdated(id, maxSupply);
    }

    /// @notice Sets the base URI used by every id without its own URI.
    function setURI(string calldata uri_) external onlyOwner {
        _setURI(uri_);
    }

    /// @notice Sets token `id`'s own metadata URI. An empty string reverts it to the base URI.
    function setTokenURI(uint256 id, string calldata tokenURI) external onlyOwner {
        _tokenURIs[id] = tokenURI;
        emit URI(uri(id), id);
    }

    /// @notice Token `id`'s own URI if set, otherwise the collection's base URI.
    function uri(uint256 id) public view override returns (string memory) {
        string memory tokenURI = _tokenURIs[id];
        return bytes(tokenURI).length > 0 ? tokenURI : super.uri(id);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
