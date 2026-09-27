// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title FactoryERC1155
/// @notice ERC1155 collection deployed as a minimal proxy clone by the TokenFactory. Only the owner can mint.
///         `name` and `symbol` are exposed for wallets and marketplaces.
contract FactoryERC1155 is ERC1155Upgradeable, OwnableUpgradeable {
    string public name;
    string public symbol;

    constructor() {
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, string calldata uri_, address owner_)
        external
        initializer
    {
        __ERC1155_init(uri_);
        __Ownable_init(owner_);
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyOwner {
        _mint(to, id, amount, data);
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data)
        external
        onlyOwner
    {
        _mintBatch(to, ids, amounts, data);
    }

    function setURI(string calldata uri_) external onlyOwner {
        _setURI(uri_);
    }
}
