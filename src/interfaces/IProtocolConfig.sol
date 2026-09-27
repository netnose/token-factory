// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Implemented by the TokenFactory: where platform fees are paid.
interface IProtocolConfig {
    function protocolRecipient() external view returns (address);
}
