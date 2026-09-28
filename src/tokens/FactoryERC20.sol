// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC7572} from "../interfaces/IERC7572.sol";

/// @title FactoryERC20
/// @notice Fixed-supply ERC20 deployed as a minimal proxy clone by the TokenFactory. The whole supply is minted once,
///         at initialization, and there is no owner and no way to mint more.
///         EIP-7572 `contractURI()` (logo, description, links) is set once at creation and can never change: the
///         token has no owner by design. Point it at mutable storage (e.g. IPNS) if the metadata must evolve.
contract FactoryERC20 is ERC20Upgradeable, ERC20PermitUpgradeable, IERC7572 {
    string private _contractURI;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata contractURI_,
        uint256 totalSupply_,
        address recipient
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        _contractURI = contractURI_;
        emit ContractURIUpdated();
        _mint(recipient, totalSupply_);
    }

    /// @inheritdoc IERC7572
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }
}
