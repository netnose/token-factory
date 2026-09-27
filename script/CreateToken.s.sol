// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TokenFactory} from "../src/TokenFactory.sol";

/// @notice Launches an ERC20 through a deployed factory.
///
/// Env: FACTORY (required), NAME, SYMBOL, SUPPLY (whole tokens), FEE_BPS, START_TICK, SALT
///
/// START_TICK sets the starting price: 1.0001^tick tokens per ETH, a multiple of 200.
///   tick ~= ln(supply / startingMarketCapEth) / ln(1.0001)
///   e.g. 1B supply, 10 ETH market cap -> ln(1e8)/ln(1.0001) ~= 184206 -> 184200
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
            startTick: int24(vm.envOr("START_TICK", int256(184_200))),
            salt: vm.envOr("SALT", bytes32(0))
        });

        vm.startBroadcast();
        (token, poolId) = factory.createERC20{value: factory.creationFee()}(p);
        vm.stopBroadcast();

        console.log("Token:", token);
        console.logBytes32(PoolId.unwrap(poolId));
    }
}
