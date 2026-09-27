// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title FactoryERC20
/// @notice Fixed-supply ERC20 deployed as a minimal proxy clone by the TokenFactory. The whole supply is minted once,
///         at initialization, and there is no owner and no way to mint more.
contract FactoryERC20 is ERC20Upgradeable, ERC20PermitUpgradeable {
    constructor() {
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, uint256 totalSupply_, address recipient)
        external
        initializer
    {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        _mint(recipient, totalSupply_);
    }
}
