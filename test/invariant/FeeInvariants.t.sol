// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {TokenFactory} from "../../src/TokenFactory.sol";
import {EthFeeHook} from "../../src/EthFeeHook.sol";

/// @dev Drives random sequences of launches, swaps (all four kinds), time jumps, claims, withdrawals, fee cuts and
///      ownership transfers. Per-call properties are asserted inline; global ones are in FeeInvariantsTest.
contract Handler is Test {
    using StateLibrary for IPoolManager;

    uint256 constant BPS = 10_000;

    PoolManager public manager;
    TokenFactory public factory;
    EthFeeHook public hook;
    PoolSwapTest public router;
    address public platform;

    address[] public actors;
    address[] public tokens;
    mapping(address => uint256) public supplyOf;
    mapping(address => uint16) public initialFee;
    mapping(address => uint128) public initialLiquidity;
    mapping(address => int24) public startTick;

    // Ghost accounting of every fee wei, from charge to payout.
    uint256 public ghostFeesCharged;
    uint256 public ghostOwnerClaimed;
    uint256 public ghostPlatformWithdrawn;
    uint256 public ghostSwaps;

    constructor(PoolManager _manager, TokenFactory _factory, EthFeeHook _hook, address _platform) {
        manager = _manager;
        factory = _factory;
        hook = _hook;
        platform = _platform;
        router = new PoolSwapTest(manager);
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            vm.deal(a, 1_000_000 ether);
        }
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    /// @dev Everything the fee system holds: owners' claims in the hook + the platform's claims in the factory.
    function feeClaims() public view returns (uint256) {
        return manager.balanceOf(address(hook), 0) + manager.balanceOf(address(factory), 0);
    }

    function _swap(address actor, PoolKey memory key, bool buy, int256 amountSpecified, uint256 value)
        internal
        returns (bool ok)
    {
        vm.prank(actor);
        try router.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
            ghostSwaps++;
        } catch {}
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------------------------------------------------

    function launch(uint256 actorSeed, uint16 feeBps, uint96 supplyWhole, uint64 capGwei, uint96 ownerBuy) public {
        address creator = _actor(actorSeed);
        TokenFactory.ERC20Params memory p = TokenFactory.ERC20Params({
            name: "T",
            symbol: "T",
            totalSupply: bound(supplyWhole, 1_000, 1e12) * 1e18,
            feeBps: uint16(bound(feeBps, 0, 500)),
            marketCapEth: bound(capGwei, 1e6, 1e12) * 1e9, // 0.001 - 1000 ETH
            contractURI: "",
            salt: bytes32(tokens.length)
        });
        uint256 value = bound(ownerBuy, 0, 50 ether);
        uint256 ethBefore = creator.balance;
        uint256 claimsBefore = feeClaims();

        vm.prank(creator);
        (address token,) = factory.createERC20{value: value}(p);

        // Owner buy: capped at 10%, fee-free, never keeps any ETH in the factory.
        assertLe(IERC20(token).balanceOf(creator), p.totalSupply / 10, "owner buy over cap");
        assertEq(feeClaims(), claimsBefore, "owner buy charged a fee");
        assertLe(ethBefore - creator.balance, value, "spent more than sent");

        tokens.push(token);
        supplyOf[token] = p.totalSupply;
        initialFee[token] = p.feeBps;
        startTick[token] = factory.startTickFor(p.totalSupply, p.marketCapEth);
        (initialLiquidity[token],,) = IPoolManager(address(manager))
            .getPositionInfo(
                factory.poolKeyOf(token).toId(), address(factory), TickMath.minUsableTick(60), startTick[token], 0
            );
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            IERC20(token).approve(address(router), type(uint256).max);
        }
    }

    function buyExactIn(uint256 actorSeed, uint256 tokenSeed, uint256 amount) public {
        if (tokens.length == 0) return;
        address actor = _actor(actorSeed);
        PoolKey memory key = factory.poolKeyOf(_token(tokenSeed));
        amount = bound(amount, 1e6, 20 ether);
        (uint256 bps,) = hook.currentFee(key.toId());
        uint256 before = feeClaims();
        if (!_swap(actor, key, true, -int256(amount), amount)) return;
        uint256 fee = feeClaims() - before;
        assertEq(fee, amount * bps / BPS, "exact-in buy fee");
        ghostFeesCharged += fee;
    }

    function buyExactOut(uint256 actorSeed, uint256 tokenSeed, uint256 fraction) public {
        if (tokens.length == 0) return;
        address actor = _actor(actorSeed);
        address token = _token(tokenSeed);
        PoolKey memory key = factory.poolKeyOf(token);
        uint256 out = IERC20(token).balanceOf(address(manager)) * bound(fraction, 1, 1_000) / 100_000; // <= 1%
        if (out == 0) return;
        (uint256 bps,) = hook.currentFee(key.toId());
        uint256 ethBefore = actor.balance;
        uint256 before = feeClaims();
        if (!_swap(actor, key, true, int256(out), 100_000 ether)) return;
        uint256 fee = feeClaims() - before;
        uint256 paid = ethBefore - actor.balance;
        assertEq(fee, (paid - fee) * bps / BPS, "exact-out buy fee");
        ghostFeesCharged += fee;
    }

    function sellExactIn(uint256 actorSeed, uint256 tokenSeed, uint256 fraction) public {
        if (tokens.length == 0) return;
        address actor = _actor(actorSeed);
        address token = _token(tokenSeed);
        uint256 amount = IERC20(token).balanceOf(actor) * bound(fraction, 1, 100) / 100;
        if (amount == 0) return;
        PoolKey memory key = factory.poolKeyOf(token);
        (uint256 bps,) = hook.currentFee(key.toId());
        uint256 ethBefore = actor.balance;
        uint256 before = feeClaims();
        if (!_swap(actor, key, false, -int256(amount), 0)) return;
        uint256 fee = feeClaims() - before;
        uint256 received = actor.balance - ethBefore;
        assertEq(fee, (received + fee) * bps / BPS, "exact-in sell fee");
        ghostFeesCharged += fee;
    }

    function sellExactOut(uint256 actorSeed, uint256 tokenSeed, uint256 amount) public {
        if (tokens.length == 0) return;
        address actor = _actor(actorSeed);
        PoolKey memory key = factory.poolKeyOf(_token(tokenSeed));
        amount = bound(amount, 1e6, 1 ether);
        (uint256 bps,) = hook.currentFee(key.toId());
        uint256 ethBefore = actor.balance;
        uint256 before = feeClaims();
        // Reverts if the actor lacks tokens, or if the pool holds less ETH than asked (the hook rejects partial
        // fills), so a successful exact-out sell always delivers exactly `amount`.
        if (!_swap(actor, key, false, int256(amount), 0)) return;
        uint256 fee = feeClaims() - before;
        assertEq(actor.balance - ethBefore, amount, "exact-out sell: exact ETH out");
        // The fee is on the specified amount (charged before the swap runs).
        assertEq(fee, amount * bps / BPS, "exact-out sell fee");
        ghostFeesCharged += fee;
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + bound(secs, 1, 30));
    }

    function claim(uint256 actorSeed) public {
        address actor = _actor(actorSeed);
        uint256 amount = hook.owed(actor);
        if (amount == 0) return;
        uint256 before = actor.balance;
        vm.prank(actor);
        hook.claim();
        assertEq(actor.balance - before, amount, "claim paid wrong amount");
        ghostOwnerClaimed += amount;
    }

    function withdrawPlatform() public {
        uint256 claims = manager.balanceOf(address(factory), 0);
        uint256 nftRevenue = address(factory).balance;
        if (claims + nftRevenue == 0) return;
        address payable vault = payable(makeAddr("vault"));
        uint256 before = vault.balance;
        vm.prank(platform);
        factory.withdraw(vault);
        assertEq(vault.balance - before, claims + nftRevenue, "withdraw paid wrong amount");
        ghostPlatformWithdrawn += claims;
    }

    function lowerFee(uint256 tokenSeed, uint16 newFee) public {
        if (tokens.length == 0) return;
        PoolId id = factory.poolKeyOf(_token(tokenSeed)).toId();
        (address owner, uint16 fee,,,,) = hook.poolConfig(id);
        if (fee == 0) return;
        vm.prank(owner);
        hook.lowerFee(id, uint16(bound(newFee, 0, fee - 1)));
    }

    function transferPoolOwnership(uint256 tokenSeed, uint256 actorSeed) public {
        if (tokens.length == 0) return;
        PoolId id = factory.poolKeyOf(_token(tokenSeed)).toId();
        (address owner,,,,,) = hook.poolConfig(id);
        vm.prank(owner);
        hook.transferPoolOwnership(id, _actor(actorSeed));
    }
}

contract FeeInvariantsTest is Test {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    TokenFactory factory;
    EthFeeHook hook;
    Handler handler;
    address platform = makeAddr("platform");

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new TokenFactory(manager, platform);
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x4444) << 144)
        );
        deployCodeTo("EthFeeHook.sol:EthFeeHook", abi.encode(manager, address(factory)), hookAddr);
        hook = EthFeeHook(hookAddr);
        vm.startPrank(platform);
        factory.setHook(hook);
        factory.setProtocolShare(1_000);
        vm.stopPrank();

        handler = new Handler(manager, factory, hook, platform);
        // Start with two live pools so swaps have something to hit from the first call.
        handler.launch(0, 500, 1e9, 1e10, 1 ether);
        handler.launch(1, 100, 1e6, 1e9, 0);

        targetContract(address(handler));
    }

    /// Every fee wei is accounted for: charged == still held (owners + platform) + paid out.
    function invariant_feeConservation() public view {
        assertEq(
            handler.ghostFeesCharged(),
            handler.feeClaims() + handler.ghostOwnerClaimed() + handler.ghostPlatformWithdrawn()
        );
    }

    /// The hook's ETH claims back exactly what it owes pool owners.
    function invariant_hookSolvent() public view {
        uint256 owedTotal;
        for (uint256 i; i < handler.actorCount(); ++i) {
            owedTotal += hook.owed(handler.actors(i));
        }
        assertEq(manager.balanceOf(address(hook), 0), owedTotal);
    }

    /// The PoolManager really holds the ETH behind every outstanding claim.
    function invariant_poolManagerHoldsClaimedEth() public view {
        assertGe(address(manager).balance, handler.feeClaims());
    }

    /// The factory never keeps ETH it should have refunded (no NFTs in this suite, so no mint revenue).
    function invariant_factoryHoldsNoEth() public view {
        assertEq(address(factory).balance, 0);
    }

    /// Per token: fixed supply, fully accounted for; fee never above its launch value; locked liquidity untouched.
    function invariant_perToken() public view {
        for (uint256 t; t < handler.tokenCount(); ++t) {
            address token = handler.tokens(t);
            IERC20 erc20 = IERC20(token);
            uint256 supply = handler.supplyOf(token);
            assertEq(erc20.totalSupply(), supply, "supply changed");

            uint256 held = erc20.balanceOf(address(manager)) + erc20.balanceOf(address(0xdEaD));
            for (uint256 i; i < handler.actorCount(); ++i) {
                held += erc20.balanceOf(handler.actors(i));
            }
            assertEq(held, supply, "tokens leaked");

            PoolId id = factory.poolKeyOf(token).toId();
            (, uint16 fee,,,,) = hook.poolConfig(id);
            assertLe(fee, handler.initialFee(token), "fee went up");

            (uint256 totalBps,) = hook.currentFee(id);
            assertLe(totalBps, 9_000, "fee above the 90% hard cap");

            (uint128 liquidity,,) = IPoolManager(address(manager))
                .getPositionInfo(id, address(factory), TickMath.minUsableTick(60), handler.startTick(token), 0);
            assertEq(liquidity, handler.initialLiquidity(token), "locked liquidity moved");
        }
    }

    function invariant_callSummary() public view {
        // Sanity check that the run actually exercised swaps (visible with -vv).
        handler.ghostSwaps();
    }
}
