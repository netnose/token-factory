// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title MintRevenue
/// @notice Shared plumbing for factory NFT collections:
///         - Public-mint revenue: the platform's share (max 10%, fixed at creation) is sent to the factory on every
///           mint; the rest stays here for the owner to `withdraw`.
///         - ERC-2981 royalties (max 10%), managed by the owner.
abstract contract MintRevenue is OwnableUpgradeable, ERC2981Upgradeable {
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 1_000;
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    uint256 internal constant BPS = 10_000;

    /// @notice The factory that created this collection. Receives the platform's share of mint revenue.
    address public factory;
    /// @notice Platform share of mint revenue, in bps.
    uint16 public protocolShareBps;

    event Withdrawn(address indexed to, uint256 amount);

    error ProtocolShareTooHigh();
    error RoyaltyTooHigh();
    error WrongPayment();
    error NothingToWithdraw();

    function __MintRevenue_init(address owner_, uint16 protocolShareBps_, address royaltyReceiver, uint96 royaltyBps)
        internal
        onlyInitializing
    {
        if (protocolShareBps_ > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareTooHigh();
        __Ownable_init(owner_);
        __ERC2981_init();
        factory = msg.sender;
        protocolShareBps = protocolShareBps_;
        _checkRoyalty(royaltyBps);
        if (royaltyBps > 0) _setDefaultRoyalty(royaltyReceiver == address(0) ? owner_ : royaltyReceiver, royaltyBps);
    }

    /// @dev Checks the exact payment and forwards the platform's share of it to the factory.
    function _collect(uint256 price) internal {
        if (msg.value != price) revert WrongPayment();
        uint256 protocolAmount = price * protocolShareBps / BPS;
        if (protocolAmount > 0) Address.sendValue(payable(factory), protocolAmount);
    }

    /// @notice Sends the collected mint revenue to the owner.
    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        emit Withdrawn(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Royalties (ERC-2981)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets the collection-wide royalty. `bps` 0 removes it.
    function setDefaultRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (bps == 0) return _deleteDefaultRoyalty();
        _checkRoyalty(bps);
        _setDefaultRoyalty(receiver, bps);
    }

    /// @notice Overrides the royalty for one token id. `bps` 0 reverts to the collection-wide royalty.
    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 bps) external onlyOwner {
        if (bps == 0) return _resetTokenRoyalty(tokenId);
        _checkRoyalty(bps);
        _setTokenRoyalty(tokenId, receiver, bps);
    }

    function _checkRoyalty(uint96 bps) internal pure {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
    }
}
