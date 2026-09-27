// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {TokenFactory} from "../src/TokenFactory.sol";
import {EthFeeHook} from "../src/EthFeeHook.sol";

/// @notice Deploys the TokenFactory and its EthFeeHook and wires them together.
///
/// Env:
///   POOL_MANAGER         Uniswap v4 PoolManager (default: Base Sepolia 0x05E7...3408)
///   PROTOCOL_SHARE_BPS   platform share of creator swap fees and NFT mint revenue, max 1000 (default: 0)
///   FACTORY_OWNER        final owner of the factory (default: deployer)
///
/// forge script script/Deploy.s.sol --rpc-url base_sepolia --account <keystore> --broadcast --verify
contract Deploy is Script {
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external returns (TokenFactory factory, EthFeeHook hook) {
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", BASE_SEPOLIA_POOL_MANAGER));
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this chain");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        uint16 protocolShareBps = uint16(vm.envOr("PROTOCOL_SHARE_BPS", uint256(0)));
        address finalOwner = vm.envOr("FACTORY_OWNER", deployer);

        factory = new TokenFactory(poolManager, deployer);

        // A v4 hook's permissions are encoded in the low 14 bits of its address: mine a CREATE2 salt that yields
        // an address with exactly our flags. Forge routes `new X{salt: ...}` through the CREATE2 deployer proxy.
        bytes memory args = abi.encode(poolManager, address(factory));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(EthFeeHook).creationCode, args);
        hook = new EthFeeHook{salt: salt}(poolManager, address(factory));
        require(address(hook) == expected, "hook address mismatch");

        factory.setHook(hook);
        factory.setProtocolShare(protocolShareBps);
        if (finalOwner != deployer) factory.transferOwnership(finalOwner);
        vm.stopBroadcast();

        console.log("TokenFactory:", address(factory));
        console.log("EthFeeHook:  ", address(hook));
    }
}
