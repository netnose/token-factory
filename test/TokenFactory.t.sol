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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {TokenFactory} from "../src/TokenFactory.sol";
import {EthFeeHook} from "../src/EthFeeHook.sol";
import {FactoryERC721} from "../src/tokens/FactoryERC721.sol";
import {FactoryERC1155} from "../src/tokens/FactoryERC1155.sol";

contract RejectsEth {
    receive() external payable {
        revert("no eth");
    }
}

contract TokenFactoryTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint16 constant PROTOCOL_SHARE = 2_000; // 20% of the swap fee
    uint256 constant SUPPLY = 1_000_000_000 ether;
    int24 constant START_TICK = 184_200; // ~1e8 tokens per ETH -> ~10 ETH starting market cap

    PoolManager manager;
    TokenFactory factory;
    EthFeeHook hook;
    PoolSwapTest router;

    address platform = makeAddr("platform");
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new TokenFactory(manager, platform);
        address hookAddr = address(HOOK_FLAGS | (uint160(0x4444) << 144));
        deployCodeTo(
            "EthFeeHook.sol:EthFeeHook", abi.encode(manager, address(factory), treasury, PROTOCOL_SHARE), hookAddr
        );
        hook = EthFeeHook(payable(hookAddr));
        vm.prank(platform);
        factory.setHook(hook);

        router = new PoolSwapTest(manager);
        vm.deal(creator, 100 ether);
        vm.deal(trader, 1_000 ether);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _launch(uint16 feeBps) internal returns (address token, PoolKey memory key) {
        vm.prank(creator);
        (token,) = factory.createERC20(
            TokenFactory.ERC20Params({
                name: "Test",
                symbol: "TST",
                totalSupply: SUPPLY,
                feeBps: feeBps,
                startTick: START_TICK,
                salt: bytes32(0)
            })
        );
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

    function _totalOwed() internal view returns (uint256) {
        return hook.owed(creator) + hook.owed(treasury);
    }

    function _assertHookSolvent() internal view {
        assertEq(manager.balanceOf(address(hook), 0), _totalOwed(), "hook claims != owed");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC20 launch
    // ---------------------------------------------------------------------------------------------------------------

    function test_createERC20_placesSupplyInPool() public {
        (address token, PoolKey memory key) = _launch(300);

        assertEq(IERC20(token).totalSupply(), SUPPLY);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertApproxEqAbs(IERC20(token).balanceOf(address(manager)), SUPPLY, 1e6);
        assertEq(IERC20(token).balanceOf(address(manager)) + IERC20(token).balanceOf(address(0xdEaD)), SUPPLY);

        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(tick, START_TICK);
        // The position sits just below the start price: inactive until the first buy moves the tick into it.
        (uint128 posLiquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(factory), TickMath.minUsableTick(200), START_TICK, bytes32(0));
        assertGt(posLiquidity, 0);
        assertEq(address(key.hooks), address(hook));
        assertTrue(key.currency0.isAddressZero());

        (address owner, uint16 feeBps, uint16 share, bool registered) = hook.poolConfig(key.toId());
        assertEq(owner, creator);
        assertEq(feeBps, 300);
        assertEq(share, PROTOCOL_SHARE);
        assertTrue(registered);
    }

    function test_createERC20_revertsOnFeeAbove5Percent() public {
        vm.prank(creator);
        vm.expectRevert(EthFeeHook.FeeTooHigh.selector);
        factory.createERC20(TokenFactory.ERC20Params("T", "T", SUPPLY, 501, START_TICK, bytes32(0)));
    }

    function test_createERC20_revertsOnUnalignedTick() public {
        vm.prank(creator);
        vm.expectRevert(TokenFactory.InvalidStartTick.selector);
        factory.createERC20(TokenFactory.ERC20Params("T", "T", SUPPLY, 100, START_TICK + 1, bytes32(0)));
    }

    function test_createERC20_predictedAddress() public {
        address predicted = factory.predictAddress(TokenFactory.TokenType.ERC20, creator, bytes32(0));
        (address token,) = _launch(100);
        assertEq(token, predicted);
    }

    function test_createERC20_sameSaltDifferentCreators() public {
        _launch(100);
        vm.prank(trader);
        (address token,) = factory.createERC20(TokenFactory.ERC20Params("T", "T", SUPPLY, 100, START_TICK, bytes32(0)));
        assertEq(token, factory.predictAddress(TokenFactory.TokenType.ERC20, trader, bytes32(0)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swap fees
    // ---------------------------------------------------------------------------------------------------------------

    function test_buyExactIn_feeOnEthInput() public {
        (address token, PoolKey memory key) = _launch(500);
        uint256 ethBefore = trader.balance;

        _swap(key, true, -1 ether, 1 ether);

        assertEq(ethBefore - trader.balance, 1 ether, "paid exactly amountIn");
        assertGt(IERC20(token).balanceOf(trader), 0);
        uint256 fee = 1 ether * 500 / 10_000;
        assertEq(_totalOwed(), fee);
        assertEq(hook.owed(treasury), fee * PROTOCOL_SHARE / 10_000);
        assertEq(hook.owed(creator), fee - hook.owed(treasury));
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
        // fee = floor(gross * 5%), received = gross - fee
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

    function testFuzz_buyAndSell(uint96 buyAmount, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 500));
        uint256 amountIn = bound(buyAmount, 1e9, 500 ether);
        (address token, PoolKey memory key) = _launch(feeBps);

        _swap(key, true, -int256(amountIn), amountIn);
        assertEq(_totalOwed(), amountIn * feeBps / 10_000);

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
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------------------------------------------------

    function test_claim_paysEth() public {
        (, PoolKey memory key) = _launch(500);
        _swap(key, true, -2 ether, 2 ether);

        uint256 creatorOwed = hook.owed(creator);
        uint256 treasuryOwed = hook.owed(treasury);

        vm.prank(creator);
        hook.claim();
        assertEq(creator.balance, 100 ether + creatorOwed);

        // anyone can push fees to a recipient
        hook.claimFor(treasury);
        assertEq(treasury.balance, treasuryOwed);

        assertEq(_totalOwed(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);

        vm.expectRevert(EthFeeHook.NothingToClaim.selector);
        vm.prank(creator);
        hook.claim();
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
        // failed claim leaves the balance intact
        assertGt(hook.owed(address(bad)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fee management
    // ---------------------------------------------------------------------------------------------------------------

    function test_lowerFee() public {
        (, PoolKey memory key) = _launch(500);
        PoolId id = key.toId();

        vm.prank(creator);
        hook.lowerFee(id, 100);
        (, uint16 feeBps,,) = hook.poolConfig(id);
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
        hook.setProtocolFee(5_000, treasury);

        (,, uint16 oldShare,) = hook.poolConfig(oldKey.toId());
        assertEq(oldShare, PROTOCOL_SHARE);

        vm.prank(trader);
        (address t2,) = factory.createERC20(TokenFactory.ERC20Params("B", "B", SUPPLY, 500, START_TICK, bytes32(0)));
        (,, uint16 newShare,) = hook.poolConfig(factory.poolKeyOf(t2).toId());
        assertEq(newShare, 5_000);
    }

    function test_setProtocolFee_onlyFactoryOwnerAndCapped() public {
        vm.expectRevert(EthFeeHook.NotFactoryOwner.selector);
        hook.setProtocolFee(0, treasury);

        vm.prank(platform);
        vm.expectRevert(EthFeeHook.FeeTooHigh.selector);
        hook.setProtocolFee(5_001, treasury);
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
        hook.registerPool(key, creator, 100);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Factory admin / creation fee
    // ---------------------------------------------------------------------------------------------------------------

    function test_creationFee() public {
        vm.prank(platform);
        factory.setCreationFee(0.01 ether);

        vm.prank(creator);
        vm.expectRevert(TokenFactory.WrongCreationFee.selector);
        factory.createERC721("N", "N", "ipfs://x/", bytes32(0));

        vm.prank(creator);
        factory.createERC721{value: 0.01 ether}("N", "N", "ipfs://x/", bytes32(0));
        vm.prank(creator);
        factory.createERC20{value: 0.01 ether}(TokenFactory.ERC20Params("T", "T", SUPPLY, 100, START_TICK, bytes32(0)));

        address payable to = payable(makeAddr("to"));
        vm.prank(platform);
        factory.withdrawFees(to);
        assertEq(to.balance, 0.02 ether);
    }

    function test_adminFunctionsOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setCreationFee(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.withdrawFees(payable(address(this)));
    }

    function test_setHook_onlyOnce() public {
        vm.prank(platform);
        vm.expectRevert(TokenFactory.HookAlreadySet.selector);
        factory.setHook(hook);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // NFTs
    // ---------------------------------------------------------------------------------------------------------------

    function test_erc721() public {
        vm.prank(creator);
        address c = factory.createERC721("Col", "COL", "ipfs://base/", bytes32(uint256(1)));
        FactoryERC721 nft = FactoryERC721(c);
        assertEq(nft.owner(), creator);
        assertEq(nft.name(), "Col");
        assertEq(c, factory.predictAddress(TokenFactory.TokenType.ERC721, creator, bytes32(uint256(1))));

        vm.prank(creator);
        assertEq(nft.mint(trader), 1);
        vm.prank(creator);
        assertEq(nft.mintBatch(trader, 3), 2);
        assertEq(nft.balanceOf(trader), 4);
        assertEq(nft.totalMinted(), 4);
        assertEq(nft.tokenURI(4), "ipfs://base/4");

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        nft.mint(trader);

        vm.expectRevert();
        nft.initialize("x", "x", "x", trader);
    }

    function test_erc1155() public {
        vm.prank(creator);
        address c = factory.createERC1155("Items", "ITM", "ipfs://items/{id}.json", bytes32(0));
        FactoryERC1155 items = FactoryERC1155(c);
        assertEq(items.owner(), creator);
        assertEq(items.name(), "Items");
        assertEq(items.symbol(), "ITM");

        vm.prank(creator);
        items.mint(trader, 7, 100, "");
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (1, 2, 10, 20);
        vm.prank(creator);
        items.mintBatch(trader, ids, amounts, "");
        assertEq(items.balanceOf(trader, 7), 100);
        assertEq(items.balanceOf(trader, 2), 20);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        items.mint(trader, 1, 1, "");
    }

    function test_implementationsCannotBeInitialized() public {
        FactoryERC721 impl = FactoryERC721(factory.erc721Implementation());
        vm.expectRevert();
        impl.initialize("x", "x", "x", trader);
    }
}
