// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {TokenFactory} from "../src/TokenFactory.sol";
import {EthFeeHook} from "../src/EthFeeHook.sol";

contract RejectsEth {
    receive() external payable {
        revert("no eth");
    }

    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }
}

/// @dev Re-enters createERC20 from the refund.
contract ReentrantCreator {
    TokenFactory factory;
    TokenFactory.ERC20Params params;

    constructor(TokenFactory _factory) {
        factory = _factory;
    }

    function launch(TokenFactory.ERC20Params calldata p) external payable {
        params = p;
        factory.createERC20{value: msg.value}(p);
    }

    receive() external payable {
        params.salt = bytes32(uint256(params.salt) + 1);
        factory.createERC20(params);
    }
}

abstract contract FactoryFixture is Test {
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint16 constant PROTOCOL_SHARE = 1_000; // 10% of the creator fee
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant MARKET_CAP = 10 ether;
    uint32 constant SNIPER_DURATION = 15;

    PoolManager manager;
    TokenFactory factory;
    EthFeeHook hook;
    PoolSwapTest router;

    address platform = makeAddr("platform");
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        factory = new TokenFactory(manager, platform);
        address hookAddr = address(HOOK_FLAGS | (uint160(0x4444) << 144));
        deployCodeTo("EthFeeHook.sol:EthFeeHook", abi.encode(manager, address(factory)), hookAddr);
        hook = EthFeeHook(hookAddr);
        vm.startPrank(platform);
        factory.setHook(hook);
        factory.setProtocolShare(PROTOCOL_SHARE);
        vm.stopPrank();

        router = new PoolSwapTest(manager);
        vm.deal(creator, 100 ether);
        vm.deal(trader, 1_000 ether);
    }

    function _params(uint16 feeBps) internal pure returns (TokenFactory.ERC20Params memory) {
        return TokenFactory.ERC20Params({
            name: "Test", symbol: "TST", totalSupply: SUPPLY, feeBps: feeBps, marketCapEth: MARKET_CAP, salt: bytes32(0)
        });
    }

    /// @dev Launches and skips past the sniper window.
    function _launch(uint16 feeBps) internal returns (address token, PoolKey memory key) {
        (token, key) = _launchNoWarp(feeBps);
        vm.warp(block.timestamp + SNIPER_DURATION);
    }

    function _launchNoWarp(uint16 feeBps) internal returns (address token, PoolKey memory key) {
        vm.prank(creator);
        (token,) = factory.createERC20(_params(feeBps));
        key = factory.poolKeyOf(token);
        vm.prank(trader);
        IERC20(token).approve(address(router), type(uint256).max);
    }

    function _swap(PoolKey memory key, bool buy, int256 amountSpecified, uint256 value) internal {
        vm.prank(trader);
        router.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Platform swap-fee revenue: ERC-6909 ETH claims credited straight to the factory.
    function _protocolClaims() internal view returns (uint256) {
        return manager.balanceOf(address(factory), 0);
    }

    function _totalOwed() internal view returns (uint256) {
        return hook.owed(creator) + _protocolClaims();
    }

    function _assertHookSolvent() internal view {
        assertEq(manager.balanceOf(address(hook), 0), hook.owed(creator), "hook claims != owed");
    }
}

contract TokenFactoryTest is FactoryFixture {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------------------------------
    // ERC20 launch
    // ---------------------------------------------------------------------------------------------------------------

    function test_createERC20_placesSupplyInPool() public {
        (address token, PoolKey memory key) = _launch(300);

        assertEq(IERC20(token).totalSupply(), SUPPLY);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertApproxEqAbs(IERC20(token).balanceOf(address(manager)), SUPPLY, 1e6);
        assertEq(IERC20(token).balanceOf(address(manager)) + IERC20(token).balanceOf(address(0xdEaD)), SUPPLY);

        int24 startTick = factory.startTickFor(SUPPLY, MARKET_CAP);
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(tick, startTick);
        // The position sits just below the start price: inactive until the first buy moves the tick into it.
        (uint128 posLiquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(factory), TickMath.minUsableTick(60), startTick, bytes32(0));
        assertGt(posLiquidity, 0);
        assertEq(address(key.hooks), address(hook));
        assertTrue(key.currency0.isAddressZero());

        (address owner, uint16 feeBps, uint16 share, bool registered,,) = hook.poolConfig(key.toId());
        assertEq(owner, creator);
        assertEq(feeBps, 300);
        assertEq(share, PROTOCOL_SHARE);
        assertTrue(registered);
    }

    function test_startTickFor_matchesMarketCap() public view {
        // 1B tokens at 10 ETH -> 1e8 tokens per ETH -> tick ln(1e8)/ln(1.0001) = 184206.8 -> nearest multiple of 60
        assertEq(factory.startTickFor(SUPPLY, MARKET_CAP), 184_200);
        // price below 1 token per ETH gives a negative tick: 1M tokens at 10M ETH -> ln(0.1)/ln(1.0001) = -23027
        assertEq(factory.startTickFor(1_000_000 ether, 10_000_000 ether), -23_040);
    }

    function testFuzz_startTickFor_within03Percent(uint128 supply, uint128 marketCap) public view {
        // Covers the whole input range, including prices near both ends of the v4 range. Below 1e6 wei a 0.3%
        // tolerance is meaningless (integer granularity), so tiny amounts are excluded.
        supply = uint128(bound(supply, 1e6, type(uint128).max));
        marketCap = uint128(bound(marketCap, 1e6, type(uint128).max));
        int24 tick;
        try factory.startTickFor(supply, marketCap) returns (int24 t) {
            tick = t;
        } catch {
            return; // out of the usable price range
        }
        // price = (sqrtP / 2^96)^2 tokens per ETH, and marketCap * price should equal supply (within the 0.3% tick
        // rounding). Compare on whichever side keeps full integer precision.
        uint256 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtP >= 1 << 96) {
            // price >= 1: implied supply = marketCap * price
            uint256 priceX96 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 96);
            assertApproxEqRel(FullMath.mulDiv(marketCap, priceX96, 1 << 96), supply, 0.0031e18);
        } else {
            // price < 1: implied market cap = supply / price
            uint256 implied = FullMath.mulDiv(FullMath.mulDiv(supply, 1 << 96, sqrtP), 1 << 96, sqrtP);
            assertApproxEqRel(implied, marketCap, 0.0031e18);
        }
    }

    function test_startTickFor_reverts() public {
        vm.expectRevert(TokenFactory.InvalidMarketCap.selector);
        factory.startTickFor(SUPPLY, 0);
        vm.expectRevert(TokenFactory.InvalidMarketCap.selector);
        factory.startTickFor(1, type(uint128).max);
    }

    function test_createERC20_revertsOnFeeAbove5Percent() public {
        vm.prank(creator);
        vm.expectRevert(EthFeeHook.FeeTooHigh.selector);
        factory.createERC20(_params(501));
    }

    function test_createERC20_predictedAddress() public {
        address predicted = factory.predictAddress(TokenFactory.TokenType.ERC20, creator, bytes32(0));
        (address token,) = _launch(100);
        assertEq(token, predicted);
    }

    function test_createERC20_sameSaltDifferentCreators() public {
        _launch(100);
        vm.prank(trader);
        (address token,) = factory.createERC20(_params(100));
        assertEq(token, factory.predictAddress(TokenFactory.TokenType.ERC20, trader, bytes32(0)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swap fees (after the sniper window)
    // ---------------------------------------------------------------------------------------------------------------

    function test_buyExactIn_feeOnEthInput() public {
        (address token, PoolKey memory key) = _launch(500);
        uint256 ethBefore = trader.balance;

        _swap(key, true, -1 ether, 1 ether);

        assertEq(ethBefore - trader.balance, 1 ether, "paid exactly amountIn");
        assertGt(IERC20(token).balanceOf(trader), 0);
        uint256 fee = 1 ether * 500 / 10_000;
        assertEq(_totalOwed(), fee);
        assertEq(_protocolClaims(), fee * PROTOCOL_SHARE / 10_000);
        assertEq(hook.owed(creator), fee - _protocolClaims());
        _assertHookSolvent();
    }

    function test_sellExactIn_feeOnEthOutput() public {
        (address token, PoolKey memory key) = _launch(500);
        _swap(key, true, -10 ether, 10 ether);
        uint256 owedAfterBuy = _totalOwed();

        uint256 tokens = IERC20(token).balanceOf(trader) / 2;
        uint256 ethBefore = trader.balance;
        _swap(key, false, -int256(tokens), 0);
        uint256 received = trader.balance - ethBefore;

        uint256 sellFee = _totalOwed() - owedAfterBuy;
        assertEq(sellFee, (received + sellFee) * 500 / 10_000);
        assertGt(sellFee, 0);
        _assertHookSolvent();
    }

    function test_buyExactOut_feeOnEthInput() public {
        (address token, PoolKey memory key) = _launch(200);
        uint256 ethBefore = trader.balance;
        _swap(key, true, 1_000_000 ether, 10 ether);

        assertEq(IERC20(token).balanceOf(trader), 1_000_000 ether);
        uint256 paid = ethBefore - trader.balance;
        uint256 fee = _totalOwed();
        assertEq(fee, (paid - fee) * 200 / 10_000);
        _assertHookSolvent();
    }

    function test_sellExactOut_feeOnEthOutput() public {
        (, PoolKey memory key) = _launch(200);
        _swap(key, true, -10 ether, 10 ether);
        uint256 owedAfterBuy = _totalOwed();

        uint256 ethBefore = trader.balance;
        _swap(key, false, 1 ether, 0);

        assertEq(trader.balance - ethBefore, 1 ether, "received exactly amountOut");
        assertEq(_totalOwed() - owedAfterBuy, 1 ether * 200 / 10_000);
        _assertHookSolvent();
    }

    function test_zeroFeePoolTakesNothing() public {
        (, PoolKey memory key) = _launch(0);
        _swap(key, true, -1 ether, 1 ether);
        assertEq(_totalOwed(), 0);
    }

    function testFuzz_buyAndSell(uint96 buyAmount, uint16 feeBps, uint8 secondsAfterLaunch) public {
        feeBps = uint16(bound(feeBps, 0, 500));
        uint256 amountIn = bound(buyAmount, 1e9, 500 ether);
        (address token, PoolKey memory key) = _launchNoWarp(feeBps);
        vm.warp(block.timestamp + bound(secondsAfterLaunch, 0, 30));

        (uint256 totalBps,) = hook.currentFee(key.toId());
        _swap(key, true, -int256(amountIn), amountIn);
        assertEq(_totalOwed(), amountIn * totalBps / 10_000);

        _swap(key, false, -int256(IERC20(token).balanceOf(trader)), 0);
        _assertHookSolvent();

        // Everything accrued can actually be paid out in ETH.
        uint256 creatorOwed = hook.owed(creator);
        if (creatorOwed > 0) {
            uint256 before = creator.balance;
            vm.prank(creator);
            hook.claim();
            assertEq(creator.balance - before, creatorOwed);
        }
        vm.prank(platform);
        factory.withdraw(payable(treasury));
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(_protocolClaims(), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Sniper protection
    // ---------------------------------------------------------------------------------------------------------------

    function test_sniper_fullFeeAtLaunch() public {
        (, PoolKey memory key) = _launchNoWarp(500);
        (uint256 totalBps, uint256 sniperBps) = hook.currentFee(key.toId());
        assertEq(totalBps, 8_000);
        assertEq(sniperBps, 7_500);

        _swap(key, true, -1 ether, 1 ether);
        assertEq(_totalOwed(), 0.8 ether);
        // sniper part (75%) -> protocol; creator fee (5%) split 90/10
        uint256 creatorFee = 0.05 ether;
        assertEq(_protocolClaims(), 0.75 ether + creatorFee * PROTOCOL_SHARE / 10_000);
        assertEq(hook.owed(creator), creatorFee - creatorFee * PROTOCOL_SHARE / 10_000);
        _assertHookSolvent();
    }

    function test_sniper_exponentialDecay() public {
        (, PoolKey memory key) = _launchNoWarp(500);
        uint256 launch = block.timestamp;

        // 5 halvings over 15s: at t = 3s the raw curve is 2^-1 -> (0.5 - 1/32) / (1 - 1/32) = 15/31
        vm.warp(launch + 3);
        (, uint256 sniperBps) = hook.currentFee(key.toId());
        assertEq(sniperBps, uint256(7_500) * 15 / 31);

        uint256 prev = type(uint256).max;
        for (uint256 t; t < SNIPER_DURATION; ++t) {
            vm.warp(launch + t);
            (uint256 totalBps,) = hook.currentFee(key.toId());
            assertLt(totalBps, prev, "strictly decreasing");
            assertGt(totalBps, 500, "above base before the end");
            prev = totalBps;
        }
        vm.warp(launch + SNIPER_DURATION);
        (uint256 endBps, uint256 endSniper) = hook.currentFee(key.toId());
        assertEq(endBps, 500);
        assertEq(endSniper, 0);
    }

    function test_sniper_appliesToSellsToo() public {
        (address token, PoolKey memory key) = _launchNoWarp(0);
        _swap(key, true, -1 ether, 1 ether);
        uint256 afterBuy = _protocolClaims();
        _swap(key, false, -int256(IERC20(token).balanceOf(trader)), 0);
        assertGt(_protocolClaims(), afterBuy);
        assertEq(hook.owed(creator), 0);
    }

    function test_sniper_configChangeOnlyAffectsNewPools() public {
        (, PoolKey memory oldKey) = _launchNoWarp(500);

        vm.prank(platform);
        factory.setSniperConfig(EthFeeHook.SniperConfig({startFeeBps: 0, duration: 0, halvings: 0}));

        (uint256 oldBps,) = hook.currentFee(oldKey.toId());
        assertEq(oldBps, 8_000);

        vm.prank(trader);
        (address t2,) = factory.createERC20(_params(300));
        (uint256 newBps, uint256 newSniper) = hook.currentFee(factory.poolKeyOf(t2).toId());
        assertEq(newBps, 300);
        assertEq(newSniper, 0);
    }

    function test_setSniperConfig_validatesAndOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setSniperConfig(EthFeeHook.SniperConfig(8_000, 15, 5));

        vm.startPrank(platform);
        vm.expectRevert(EthFeeHook.InvalidSniperConfig.selector);
        factory.setSniperConfig(EthFeeHook.SniperConfig(9_001, 15, 5));
        vm.expectRevert(EthFeeHook.InvalidSniperConfig.selector);
        factory.setSniperConfig(EthFeeHook.SniperConfig(8_000, 0, 5));
        vm.expectRevert(EthFeeHook.InvalidSniperConfig.selector);
        factory.setSniperConfig(EthFeeHook.SniperConfig(8_000, 601, 5));
        factory.setSniperConfig(EthFeeHook.SniperConfig(5_000, 60, 3));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------------------------------------------------

    function test_claim_paysEth() public {
        (, PoolKey memory key) = _launch(500);
        _swap(key, true, -2 ether, 2 ether);

        uint256 creatorOwed = hook.owed(creator);
        uint256 protocolOwed = _protocolClaims();

        vm.prank(creator);
        hook.claim();
        assertEq(creator.balance, 100 ether + creatorOwed);

        vm.prank(platform);
        factory.withdraw(payable(treasury));
        assertEq(treasury.balance, protocolOwed);

        assertEq(_totalOwed(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);

        vm.expectRevert(EthFeeHook.NothingToClaim.selector);
        vm.prank(creator);
        hook.claim();
    }

    function test_protocolShareCreditedToFactoryImmediately() public {
        (, PoolKey memory key) = _launch(500);
        _swap(key, true, -1 ether, 1 ether);
        // No claim step: the factory holds the platform's share as soon as the swap settles.
        assertEq(_protocolClaims(), 0.05 ether * uint256(PROTOCOL_SHARE) / 10_000);
    }

    function test_withdraw_onlyOwnerAndRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.withdraw(payable(treasury));
        vm.prank(platform);
        vm.expectRevert(TokenFactory.InvalidRecipient.selector);
        factory.withdraw(payable(address(0)));
    }

    function test_recipientRejectingEthDoesNotBlockSwaps() public {
        RejectsEth bad = new RejectsEth();
        (, PoolKey memory key) = _launch(500);
        vm.prank(creator);
        hook.transferPoolOwnership(key.toId(), address(bad));

        _swap(key, true, -1 ether, 1 ether);
        _swap(key, true, -1 ether, 1 ether);
        assertGt(hook.owed(address(bad)), 0);

        vm.expectRevert();
        hook.claimFor(address(bad));
        assertGt(hook.owed(address(bad)), 0);
    }

    function test_claimTo_rescuesOwnerThatRejectsEth() public {
        RejectsEth bad = new RejectsEth();
        (, PoolKey memory key) = _launch(500);
        vm.prank(creator);
        hook.transferPoolOwnership(key.toId(), address(bad));
        _swap(key, true, -1 ether, 1 ether);

        uint256 amount = hook.owed(address(bad));
        address rescue = makeAddr("rescue");
        bad.call(address(hook), abi.encodeCall(EthFeeHook.claimTo, (rescue)));
        assertEq(rescue.balance, amount);
        assertEq(hook.owed(address(bad)), 0);

        vm.expectRevert(EthFeeHook.InvalidRecipient.selector);
        hook.claimTo(address(0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fee management
    // ---------------------------------------------------------------------------------------------------------------

    function test_lowerFee() public {
        (, PoolKey memory key) = _launch(500);
        PoolId id = key.toId();

        vm.prank(creator);
        hook.lowerFee(id, 100);
        (, uint16 feeBps,,,,) = hook.poolConfig(id);
        assertEq(feeBps, 100);

        _swap(key, true, -1 ether, 1 ether);
        assertEq(_totalOwed(), 1 ether * 100 / 10_000);
    }

    function test_lowerFee_cannotRaiseOrKeep() public {
        (, PoolKey memory key) = _launch(300);
        vm.startPrank(creator);
        vm.expectRevert(EthFeeHook.FeeNotLowered.selector);
        hook.lowerFee(key.toId(), 300);
        vm.expectRevert(EthFeeHook.FeeNotLowered.selector);
        hook.lowerFee(key.toId(), 400);
        vm.stopPrank();
    }

    function test_lowerFee_onlyOwner() public {
        (, PoolKey memory key) = _launch(300);
        vm.prank(trader);
        vm.expectRevert(EthFeeHook.NotPoolOwner.selector);
        hook.lowerFee(key.toId(), 0);
    }

    function test_transferPoolOwnership_redirectsFees() public {
        (, PoolKey memory key) = _launch(500);
        address newOwner = makeAddr("newOwner");
        vm.prank(creator);
        hook.transferPoolOwnership(key.toId(), newOwner);

        _swap(key, true, -1 ether, 1 ether);
        assertEq(hook.owed(creator), 0);
        assertGt(hook.owed(newOwner), 0);

        vm.prank(creator);
        vm.expectRevert(EthFeeHook.NotPoolOwner.selector);
        hook.lowerFee(key.toId(), 0);
    }

    function test_protocolShareChangeOnlyAffectsNewPools() public {
        (, PoolKey memory oldKey) = _launch(500);

        vm.prank(platform);
        factory.setProtocolShare(500);

        (,, uint16 oldShare,,,) = hook.poolConfig(oldKey.toId());
        assertEq(oldShare, PROTOCOL_SHARE);

        vm.prank(trader);
        (address t2,) = factory.createERC20(_params(500));
        (,, uint16 newShare,,,) = hook.poolConfig(factory.poolKeyOf(t2).toId());
        assertEq(newShare, 500);
    }

    function test_setProtocolShare_onlyOwnerAndCappedAt10Percent() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setProtocolShare(0);

        vm.startPrank(platform);
        vm.expectRevert(TokenFactory.ProtocolShareTooHigh.selector);
        factory.setProtocolShare(1_001);
        factory.setProtocolShare(1_000);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Owner launch buy
    // ---------------------------------------------------------------------------------------------------------------

    function test_ownerBuy_noFeesDuringSniperWindow() public {
        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        (address token, PoolId id) = factory.createERC20{value: 1 ether}(_params(500));

        assertEq(ethBefore - creator.balance, 1 ether);
        uint256 bought = IERC20(token).balanceOf(creator);
        assertGt(bought, 0);
        // no creator fee, no sniper fee, no protocol fee
        assertEq(hook.owed(creator), 0);
        assertEq(_protocolClaims(), 0);
        (uint256 totalBps,) = hook.currentFee(id);
        assertEq(totalBps, 8_000, "sniper window still active for everyone else");

        // Same ETH through the same curve without a fee would buy exactly as much: compare against a fee-free pool.
        vm.prank(trader);
        (address t2,) = factory.createERC20(_params(0));
        vm.warp(block.timestamp + SNIPER_DURATION);
        PoolKey memory k2 = factory.poolKeyOf(t2);
        _swap(k2, true, -1 ether, 1 ether);
        assertEq(IERC20(t2).balanceOf(trader), bought);
    }

    function test_ownerBuy_thenSniperAppliesToOthers() public {
        vm.prank(creator);
        (address token,) = factory.createERC20{value: 1 ether}(_params(500));
        PoolKey memory key = factory.poolKeyOf(token);
        _swap(key, true, -1 ether, 1 ether);
        assertEq(_totalOwed(), 0.8 ether);
    }

    function test_ownerBuy_cappedAt10PercentAndRefunded() public {
        // 1,000 tokens at a 1 ETH market cap. Constant-product with virtual reserves (1,000 tokens, 1 ETH): taking
        // 100 tokens (10%) costs 1 * 100 / 900 = 0.111 ETH. Sending 99 ETH must stop there and refund the rest.
        TokenFactory.ERC20Params memory p = _params(500);
        p.totalSupply = 1_000 ether;
        p.marketCapEth = 1 ether;
        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        (address token,) = factory.createERC20{value: 99 ether}(p);

        uint256 bought = IERC20(token).balanceOf(creator);
        uint256 spent = ethBefore - creator.balance;
        assertLe(bought, 100 ether, "never above the cap");
        assertApproxEqRel(bought, 100 ether, 1e12, "fills up to the cap");
        assertApproxEqRel(spent, uint256(1 ether) * 100 / 900, 0.004e18, "pays only what the cap costs");
        assertEq(address(factory).balance, 0, "rest refunded");
    }

    function test_ownerBuy_belowCapFillsInFull() public {
        // 1 ETH into 1B tokens at a 10 ETH market cap buys ~1e9 / 11 = 9.1% of the supply: under the cap.
        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        (address token,) = factory.createERC20{value: 1 ether}(_params(500));
        assertEq(ethBefore - creator.balance, 1 ether);
        assertApproxEqRel(IERC20(token).balanceOf(creator), SUPPLY / 11, 0.004e18);
    }

    function testFuzz_ownerBuy_neverExceedsCap(uint96 value, uint128 supply, uint96 marketCap) public {
        uint256 v = bound(value, 1, 100 ether);
        TokenFactory.ERC20Params memory p = _params(500);
        p.totalSupply = bound(supply, 1e18, 1e33);
        p.marketCapEth = bound(marketCap, 1e15, 1e24);
        try factory.startTickFor(p.totalSupply, p.marketCapEth) {}
        catch {
            return;
        }
        vm.deal(creator, v);
        vm.prank(creator);
        (address token,) = factory.createERC20{value: v}(p);

        uint256 bought = IERC20(token).balanceOf(creator);
        assertLe(bought, p.totalSupply / 10);
        // ETH is conserved: what the creator lost is exactly what the pool manager received
        assertEq(v - creator.balance, address(manager).balance);
        assertEq(address(factory).balance, 0);
        assertEq(_totalOwed(), 0, "fee-free");
    }

    function test_ownerBuy_atLowestAllowedPrice() public {
        // Market cap so large the start tick is the lowest one the factory accepts (one spacing above the
        // minimum usable tick). The capped launch buy must still work.
        // Supply small enough that the liquidity stays under the v4 per-tick limit at this price.
        TokenFactory.ERC20Params memory p = _params(500);
        p.totalSupply = 1e11;
        p.marketCapEth = 33647e45; // 1e11 / 1.0001^-887160
        int24 tick = factory.startTickFor(p.totalSupply, p.marketCapEth);
        assertEq(tick, TickMath.minUsableTick(60) + 60, "lowest tick the factory accepts");
        vm.prank(creator);
        (address token,) = factory.createERC20{value: 1 ether}(p);
        assertLe(IERC20(token).balanceOf(creator), p.totalSupply / 10);
    }

    function test_createERC20_supplyTooLargeForPrice() public {
        // Liquidity ~ sqrt(supply * marketCap): 1e38 * 1e38 wei is far beyond the v4 per-tick limit.
        TokenFactory.ERC20Params memory p = _params(500);
        p.totalSupply = 1e38;
        p.marketCapEth = 1e38;
        vm.prank(creator);
        vm.expectRevert(TokenFactory.SupplyTooLargeForPrice.selector);
        factory.createERC20(p);
    }

    /// @dev Any supply / market cap / owner buy either launches correctly or fails with one of the factory's own
    ///      validation errors - never with an arithmetic panic or a revert from deep inside Uniswap.
    function testFuzz_createERC20_onlyExpectedReverts(uint128 supply, uint128 marketCap, uint96 value) public {
        TokenFactory.ERC20Params memory p = _params(500);
        p.totalSupply = bound(supply, 1, type(uint128).max);
        p.marketCapEth = bound(marketCap, 1, type(uint128).max);
        uint256 v = bound(value, 0, 100 ether);
        vm.deal(creator, v);
        vm.prank(creator);
        try factory.createERC20{value: v}(p) returns (address token, PoolId) {
            assertLe(IERC20(token).balanceOf(creator), p.totalSupply / 10);
            assertEq(address(factory).balance, 0);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == TokenFactory.InvalidMarketCap.selector || sel == TokenFactory.SupplyTooLargeForPrice.selector
                    || sel == TokenFactory.InvalidSupply.selector,
                "unexpected revert"
            );
        }
    }

    function test_createERC20_nonReentrant() public {
        ReentrantCreator attacker = new ReentrantCreator(factory);
        TokenFactory.ERC20Params memory p = _params(500);
        p.totalSupply = 1_000 ether;
        p.marketCapEth = 1 ether; // 50 ETH overshoots the 10% cap -> refund -> re-entry
        vm.deal(address(attacker), 0);
        vm.expectRevert();
        attacker.launch{value: 50 ether}(p);
    }

    function test_setSniperConfig_requiresHook() public {
        TokenFactory fresh = new TokenFactory(manager, platform);
        vm.prank(platform);
        vm.expectRevert(TokenFactory.HookNotSet.selector);
        fresh.setSniperConfig(EthFeeHook.SniperConfig(8_000, 15, 5));
    }

    function test_noOwnerBuyWithoutValue() public {
        (address token,) = _launch(500);
        assertEq(IERC20(token).balanceOf(creator), 0);
    }

    function test_factoryIsOnlyFeeFreeSwapper() public {
        (, PoolKey memory key) = _launch(500);
        vm.expectRevert(EthFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(factory), key, SwapParams(true, -1 ether, 0), "");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hook access control
    // ---------------------------------------------------------------------------------------------------------------

    function test_onlyFactoryCanInitializePoolsWithHook() public {
        (address token,) = _launch(100);
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_hookCallbacksOnlyFromPoolManager() public {
        (, PoolKey memory key) = _launch(100);
        vm.expectRevert(EthFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, 0), "");
        vm.expectRevert(EthFeeHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(address(this), 1 ether));
    }

    function test_registerPool_onlyFactory() public {
        PoolKey memory key;
        vm.expectRevert(EthFeeHook.NotFactory.selector);
        hook.registerPool(key, creator, 100, 0, EthFeeHook.SniperConfig(0, 0, 0));
    }

    function test_setHook_onlyOnce() public {
        vm.prank(platform);
        vm.expectRevert(TokenFactory.HookAlreadySet.selector);
        factory.setHook(hook);
    }
}
