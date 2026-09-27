// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IProtocolConfig} from "../interfaces/IProtocolConfig.sol";

/// @title MintRevenue
/// @notice Splits public-mint revenue between the collection owner and the platform. The platform's share (max 10%)
///         is fixed when the collection is created. Both sides are pulled: the owner with `withdraw`, the platform
///         with `withdrawProtocol` (paid to the factory's current protocol recipient; callable by anyone).
abstract contract MintRevenue is OwnableUpgradeable {
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 1_000;
    uint256 internal constant BPS = 10_000;

    /// @notice The factory that created this collection.
    address public factory;
    /// @notice Platform share of mint revenue, in bps.
    uint16 public protocolShareBps;
    /// @notice Mint revenue owed to the platform and not yet withdrawn.
    uint256 public protocolOwed;

    event Withdrawn(address indexed to, uint256 amount);
    event ProtocolWithdrawn(address indexed to, uint256 amount);

    error ProtocolShareTooHigh();
    error WrongPayment();
    error NothingToWithdraw();

    function __MintRevenue_init(address owner_, uint16 protocolShareBps_) internal onlyInitializing {
        if (protocolShareBps_ > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareTooHigh();
        __Ownable_init(owner_);
        factory = msg.sender;
        protocolShareBps = protocolShareBps_;
    }

    /// @dev Checks the exact payment and books the platform's share of it.
    function _collect(uint256 price) internal {
        if (msg.value != price) revert WrongPayment();
        protocolOwed += price * protocolShareBps / BPS;
    }

    /// @notice Sends the owner's mint revenue to the owner.
    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance - protocolOwed;
        if (amount == 0) revert NothingToWithdraw();
        emit Withdrawn(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Sends the platform's mint revenue to the factory's protocol recipient.
    function withdrawProtocol() external {
        uint256 amount = protocolOwed;
        if (amount == 0) revert NothingToWithdraw();
        protocolOwed = 0;
        address to = IProtocolConfig(factory).protocolRecipient();
        emit ProtocolWithdrawn(to, amount);
        Address.sendValue(payable(to), amount);
    }
}
