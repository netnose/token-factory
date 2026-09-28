// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title EIP-7572: Contract-level metadata via `contractURI()`
/// @notice `contractURI()` returns a URI (or `data:application/json` payload) with JSON metadata about the contract
///         itself, e.g. {"name", "symbol", "description", "image", "banner_image", "featured_image",
///         "external_link", "collaborators"}. Marketplaces and wallets use it for collection / token pages.
interface IERC7572 {
    /// @notice Emitted when the contract-level metadata changes, so indexers can refresh it.
    event ContractURIUpdated();

    function contractURI() external view returns (string memory);
}
