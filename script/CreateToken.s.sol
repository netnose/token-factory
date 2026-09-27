// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TokenFactory} from "../src/TokenFactory.sol";

/// @notice Launches an ERC20 through a deployed factory.
///
/// Env: FACTORY (required), NAME, SYMBOL, SUPPLY (whole tokens), FEE_BPS, MARKET_CAP (wei of ETH), SALT
///
/// forge script script/CreateToken.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
contract CreateToken is Script {
    function run() external returns (address token, PoolId poolId) {
        TokenFactory factory = TokenFactory(vm.envAddress("FACTORY"));
        TokenFactory.ERC20Params memory p = TokenFactory.ERC20Params({
            name: vm.envOr("NAME", string("Test Token")),
            symbol: vm.envOr("SYMBOL", string("TEST")),
            totalSupply: vm.envOr("SUPPLY", uint256(1_000_000_000)) * 1e18,
            feeBps: uint16(vm.envOr("FEE_BPS", uint256(500))),
            marketCapEth: vm.envOr("MARKET_CAP", uint256(10 ether)),
            salt: vm.envOr("SALT", bytes32(0))
        });

        vm.startBroadcast();
        (token, poolId) = factory.createERC20(p);
        vm.stopBroadcast();

        console.log("Token:", token);
        console.logBytes32(PoolId.unwrap(poolId));
    }
}
