// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title FactoryERC721
/// @notice ERC721 collection deployed as a minimal proxy clone by the TokenFactory. Only the owner can mint.
///         Token ids start at 1 and increment; metadata lives at `baseURI + tokenId`.
contract FactoryERC721 is ERC721Upgradeable, OwnableUpgradeable {
    string private _baseTokenURI;
    uint256 public totalMinted;

    event BaseURIUpdated(string baseURI);

    constructor() {
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, string calldata baseURI_, address owner_)
        external
        initializer
    {
        __ERC721_init(name_, symbol_);
        __Ownable_init(owner_);
        _baseTokenURI = baseURI_;
    }

    /// @notice Mints the next token id to `to`.
    function mint(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = ++totalMinted;
        _safeMint(to, tokenId);
    }

    /// @notice Mints `quantity` consecutive token ids to `to`. Returns the first id.
    function mintBatch(address to, uint256 quantity) external onlyOwner returns (uint256 firstTokenId) {
        firstTokenId = totalMinted + 1;
        for (uint256 i; i < quantity; ++i) {
            _safeMint(to, firstTokenId + i);
        }
        totalMinted += quantity;
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
}
