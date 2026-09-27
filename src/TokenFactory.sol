// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";

import {EthFeeHook} from "./EthFeeHook.sol";
import {FactoryERC20} from "./tokens/FactoryERC20.sol";
import {FactoryERC721} from "./tokens/FactoryERC721.sol";
import {FactoryERC1155} from "./tokens/FactoryERC1155.sol";

/// @title TokenFactory
/// @notice Deploys ERC20, ERC721 and ERC1155 contracts as cheap minimal-proxy clones.
///
///         ERC20 launches are fixed supply: the entire supply is placed as one-sided liquidity in a native ETH /
///         TOKEN Uniswap v4 pool that uses the EthFeeHook, starting at the market cap (in ETH) the creator chooses.
///         Buyers swap ETH for the token along the curve; the hook charges the creator's fee (0-5%, can only be
///         lowered) in ETH on every buy and sell, plus a sniper fee that decays to zero shortly after launch. The
///         liquidity position is owned by this contract and there is no function to remove it: it is locked forever.
///
///         The creator can buy at launch, in the same transaction, without paying any fee (`msg.value`).
///
///         ERC721 / ERC1155 collections support owner mints, paid public mints and ERC-2981 royalties.
///
///         The factory owner sets the platform's share (max 10%) of creator swap fees and NFT mint revenue, and the
///         sniper protection parameters. Both are snapshotted per token at creation, so changes never affect existing
///         tokens. All platform revenue lands in this contract as it is earned - swap fees as ERC-6909 ETH claims on
///         the PoolManager, mint revenue as ETH - and `withdraw` pays out both in one call.
contract TokenFactory is Ownable, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice LP fee of launch pools. Zero: the hook fee is the only swap fee and the locked position earns nothing.
    uint24 public constant POOL_LP_FEE = 0;
    int24 public constant TICK_SPACING = 60;
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 1_000;
    /// @notice The creator's fee-free launch buy can take at most 10% of the supply.
    uint16 public constant MAX_OWNER_BUY_BPS = 1_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable erc20Implementation;
    address public immutable erc721Implementation;
    address public immutable erc1155Implementation;

    EthFeeHook public hook;
    /// @notice Platform share of ERC20 creator fees and NFT mint revenue, for tokens created from now on.
    uint16 public protocolShareBps;
    /// @notice Sniper protection for ERC20s launched from now on.
    EthFeeHook.SniperConfig public sniperConfig;

    struct ERC20Params {
        string name;
        string symbol;
        /// Total supply in wei (18 decimals), at most type(int128).max. All of it goes into the pool.
        uint256 totalSupply;
        /// Creator's swap fee in basis points, max 500 (5%).
        uint16 feeBps;
        /// Starting fully-diluted market cap in wei of ETH (e.g. 10 ether). The starting price is
        /// marketCap / totalSupply ETH per token, rounded to the nearest usable tick (within 0.3%).
        uint256 marketCapEth;
        /// Salt for the token's deterministic address (combined with msg.sender).
        bytes32 salt;
    }

    struct ERC721Params {
        string name;
        string symbol;
        string baseURI;
        FactoryERC721.SaleConfig sale;
        FactoryERC721.RoyaltyConfig royalty;
        bytes32 salt;
    }

    struct ERC1155Params {
        string name;
        string symbol;
        /// Base URI for every id without its own URI (may contain the `{id}` placeholder).
        string uri;
        /// Collection-wide royalty; receiver defaults to the creator. bps max 1000, 0 = none.
        FactoryERC721.RoyaltyConfig royalty;
        bytes32 salt;
    }

    enum Action {
        Launch,
        Withdraw
    }

    /// @dev Everything the unlock callback needs to seed a pool and run the launch buy.
    struct LaunchData {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 totalSupply;
        uint256 buyAmount;
        address buyer;
    }

    enum TokenType {
        ERC20,
        ERC721,
        ERC1155
    }

    mapping(address => TokenType) public tokenType;
    mapping(address => bool) public isFactoryToken;
    mapping(address => PoolKey) internal _poolKeys;

    event ERC20Created(
        address indexed token,
        address indexed creator,
        PoolId indexed poolId,
        uint256 totalSupply,
        uint16 feeBps,
        uint256 marketCapEth,
        int24 startTick
    );
    /// @notice The creator's fee-free launch buy.
    event OwnerBuy(address indexed token, address indexed buyer, uint256 ethSpent, uint256 tokensBought);
    event ERC721Created(address indexed token, address indexed creator);
    event ERC1155Created(address indexed token, address indexed creator);
    event HookSet(address hook);
    event ProtocolShareUpdated(uint16 shareBps);
    event Withdrawn(address indexed to, uint256 amount);
    event SniperConfigUpdated(EthFeeHook.SniperConfig config);

    error HookAlreadySet();
    error HookNotSet();
    error InvalidHook();
    error InvalidRecipient();
    error ProtocolShareTooHigh();
    error InvalidSupply();
    error InvalidMarketCap();
    error NotPoolManager();
    error NotERC20();
    error OwnerBuyTooLarge();
    error SupplyTooLargeForPrice();

    constructor(IPoolManager _poolManager, address _owner) Ownable(_owner) {
        poolManager = _poolManager;
        erc20Implementation = address(new FactoryERC20());
        erc721Implementation = address(new FactoryERC721());
        erc1155Implementation = address(new FactoryERC1155());
        // Default sniper protection: 80% at launch, exponential decay to the creator fee over 15 seconds.
        sniperConfig = EthFeeHook.SniperConfig({startFeeBps: 8_000, duration: 15, halvings: 5});
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice One-time wiring of the fee hook. The hook must be deployed at an address with its permission flags
    ///         (see script/Deploy.s.sol) and point back to this factory.
    function setHook(EthFeeHook _hook) external onlyOwner {
        if (address(hook) != address(0)) revert HookAlreadySet();
        if (_hook.factory() != address(this) || _hook.poolManager() != poolManager) revert InvalidHook();
        hook = _hook;
        emit HookSet(address(_hook));
    }

    /// @notice Sets the platform share (max 10%) of creator swap fees and NFT mint revenue for tokens created from
    ///         now on.
    function setProtocolShare(uint16 shareBps) external onlyOwner {
        if (shareBps > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareTooHigh();
        protocolShareBps = shareBps;
        emit ProtocolShareUpdated(shareBps);
    }

    /// @notice Withdraws all platform revenue: swap fees (ERC-6909 ETH claims on the PoolManager) and NFT mint
    ///         revenue (ETH held here).
    function withdraw(address payable to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidRecipient();
        uint256 claims = poolManager.balanceOf(address(this), CurrencyLibrary.ADDRESS_ZERO.toId());
        if (claims > 0) poolManager.unlock(abi.encode(Action.Withdraw, abi.encode(to, claims)));
        uint256 balance = address(this).balance;
        if (balance > 0) Address.sendValue(to, balance);
        amount = claims + balance;
        emit Withdrawn(to, amount);
    }

    /// @notice Receives the platform's share of NFT mint revenue.
    receive() external payable {}

    /// @notice Sets sniper protection for ERC20s launched from now on. `startFeeBps` 0 disables it.
    function setSniperConfig(EthFeeHook.SniperConfig calldata config) external onlyOwner {
        // Validated by the hook (the same check `registerPool` applies), so an invalid config can never be stored
        // and brick launches.
        if (address(hook) == address(0)) revert HookNotSet();
        hook.validateSniperConfig(config);
        sniperConfig = config;
        emit SniperConfigUpdated(config);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Creation
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Creates a fixed-supply ERC20 and launches it in a one-sided ETH/TOKEN v4 pool with the fee hook.
    ///         Any ETH sent is the creator's launch buy: it is swapped into the pool right after it is created, with
    ///         no fee (not even the sniper fee), and the tokens go to the caller. The buy stops once it has taken
    ///         MAX_OWNER_BUY_BPS (10%) of the supply; ETH it did not need is refunded.
    /// @return token The new token.
    /// @return poolId The id of its v4 pool.
    function createERC20(ERC20Params calldata p) external payable nonReentrant returns (address token, PoolId poolId) {
        EthFeeHook _hook = hook;
        if (address(_hook) == address(0)) revert HookNotSet();
        // v4 balance deltas are int128, so the whole supply must fit in one (~1.7e38 wei = 1.7e20 tokens).
        if (p.totalSupply == 0 || p.totalSupply > uint128(type(int128).max)) revert InvalidSupply();
        int24 startTick = startTickFor(p.totalSupply, p.marketCapEth);

        token = Clones.cloneDeterministic(erc20Implementation, _salt(msg.sender, p.salt));
        FactoryERC20(token).initialize(p.name, p.symbol, p.totalSupply, address(this));

        // Native ETH (address 0) always sorts first, so ETH is currency0 and the token is currency1.
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: POOL_LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(_hook))
        });
        poolId = key.toId();

        _hook.registerPool(key, msg.sender, p.feeBps, protocolShareBps, sniperConfig);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(startTick));
        uint256 ethSpent = _seedPoolAndBuy(key, startTick, p.totalSupply);

        isFactoryToken[token] = true;
        tokenType[token] = TokenType.ERC20;
        _poolKeys[token] = key;
        emit ERC20Created(token, msg.sender, poolId, p.totalSupply, p.feeBps, p.marketCapEth, startTick);

        // Interaction last: the launch buy stops at the 10% cap, so ETH beyond what that costs is returned.
        if (msg.value > ethSpent) Address.sendValue(payable(msg.sender), msg.value - ethSpent);
    }

    /// @dev Adds the whole supply as one-sided liquidity and runs the creator's launch buy with `msg.value`.
    /// @return ethSpent ETH the launch buy used; the caller refunds the rest of `msg.value`.
    function _seedPoolAndBuy(PoolKey memory key, int24 startTick, uint256 totalSupply)
        internal
        returns (uint256 ethSpent)
    {
        // One-sided position holding only the token: [minTick, startTick] lies entirely at/below the current tick.
        // Buying (ETH -> token) moves the price down through the range.
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        uint128 liquidity = liquidityFor(totalSupply, startTick);
        LaunchData memory data = LaunchData({
            key: key,
            tickLower: minTick,
            tickUpper: startTick,
            liquidity: liquidity,
            totalSupply: totalSupply,
            buyAmount: msg.value,
            buyer: msg.sender
        });
        uint256 tokensBought;
        (ethSpent, tokensBought) =
            abi.decode(poolManager.unlock(abi.encode(Action.Launch, abi.encode(data))), (uint256, uint256));
        if (tokensBought > 0) emit OwnerBuy(Currency.unwrap(key.currency1), msg.sender, ethSpent, tokensBought);

        // Rounding leaves a few wei of the token unplaced; burn them so the whole supply is in the pool.
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 dust = token.balanceOf(address(this));
        if (dust > 0) token.safeTransfer(DEAD, dust);
    }

    /// @notice Creates an ERC721 collection owned by the caller, with its public sale configured.
    function createERC721(ERC721Params calldata p) external returns (address token) {
        token = Clones.cloneDeterministic(erc721Implementation, _salt(msg.sender, p.salt));
        FactoryERC721(token).initialize(p.name, p.symbol, p.baseURI, msg.sender, protocolShareBps, p.sale, p.royalty);
        isFactoryToken[token] = true;
        tokenType[token] = TokenType.ERC721;
        emit ERC721Created(token, msg.sender);
    }

    /// @notice Creates an ERC1155 collection owned by the caller. Per-id sales and URIs are configured afterwards.
    function createERC1155(ERC1155Params calldata p) external returns (address token) {
        token = Clones.cloneDeterministic(erc1155Implementation, _salt(msg.sender, p.salt));
        FactoryERC1155(token)
            .initialize(p.name, p.symbol, p.uri, msg.sender, protocolShareBps, p.royalty.receiver, p.royalty.bps);
        isFactoryToken[token] = true;
        tokenType[token] = TokenType.ERC1155;
        emit ERC1155Created(token, msg.sender);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory params) = abi.decode(data, (Action, bytes));
        if (action == Action.Withdraw) {
            (address to, uint256 amount) = abi.decode(params, (address, uint256));
            poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, to, amount);
            return "";
        }
        return _launch(params);
    }

    /// @dev Adds the one-sided token liquidity, paid from the factory's token balance, then executes the creator's
    ///      launch buy. The hook charges no fee on swaps made by the factory.
    ///
    ///      Owner-buy cap: all liquidity sits in one range that holds only the token, so while buying inside it the
    ///      token amount between two prices is linear in sqrtPrice: tokens(a -> b) = L * (sqrtA - sqrtB) / 2^96.
    ///      The price at which exactly `cap` tokens have been bought is therefore sqrtStart - cap * 2^96 / L. Using it
    ///      as the swap's price limit makes the exact-in swap stop there by itself (rounding the step down keeps the
    ///      output <= cap); the ETH it did not use stays unspent and is refunded by the caller.
    function _launch(bytes memory params) internal returns (bytes memory) {
        LaunchData memory d = abi.decode(params, (LaunchData));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: d.tickLower,
                tickUpper: d.tickUpper,
                liquidityDelta: int256(uint256(d.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // The position is below the current price, so it only needs the token (amount0 == 0).
        uint256 owed = uint256(uint128(-delta.amount1()));
        poolManager.sync(d.key.currency1);
        IERC20(Currency.unwrap(d.key.currency1)).safeTransfer(address(poolManager), owed);
        poolManager.settle();

        if (d.buyAmount == 0) return abi.encode(uint256(0), uint256(0));

        uint256 cap = d.totalSupply * MAX_OWNER_BUY_BPS / 10_000;
        // step = cap * 2^96 / L ~= 10% of (sqrtStart - sqrtMin). It rounds to 0 only for dust supplies (cap of 0
        // tokens when the supply is under 10 wei, or a cap below one sqrtPrice unit). Then no buy fits under the cap:
        // skip it (the caller refunds everything) rather than hand v4 a price limit equal to the current price.
        uint256 step = FullMath.mulDiv(cap, FixedPoint96.Q96, d.liquidity);
        if (step == 0) return abi.encode(uint256(0), uint256(0));
        uint160 sqrtLimit = uint160(TickMath.getSqrtPriceAtTick(d.tickUpper) - step);
        BalanceDelta swapDelta = poolManager.swap(
            d.key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(d.buyAmount), sqrtPriceLimitX96: sqrtLimit}),
            ""
        );
        uint256 ethSpent = uint256(uint128(-swapDelta.amount0()));
        uint256 tokensBought = uint256(uint128(swapDelta.amount1()));
        if (tokensBought > cap) revert OwnerBuyTooLarge(); // unreachable by construction; kept as a hard guarantee

        poolManager.settle{value: ethSpent}();
        poolManager.take(d.key.currency1, d.buyer, tokensBought);
        return abi.encode(ethSpent, tokensBought);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Pool starting tick for a launch: price = totalSupply / marketCapEth tokens per ETH, i.e.
    ///         sqrtPriceX96 = sqrt(totalSupply / marketCapEth) * 2^96, rounded to the nearest multiple of TICK_SPACING.
    function startTickFor(uint256 totalSupply, uint256 marketCapEth) public pure returns (int24 tick) {
        if (marketCapEth == 0) revert InvalidMarketCap();
        // sqrtPriceX96 = sqrt(ratio * 2^192), ratio = totalSupply / marketCapEth.
        // - ratio < 2^64: ratio * 2^192 fits in 256 bits, so take its square root directly (full precision, also
        //   for tiny ratios where a lower-precision intermediate would round to nothing).
        // - otherwise: sqrt(ratio * 2^128) * 2^32. The intermediate is >= 2^192, so precision is not an issue.
        //   Fits: totalSupply < 2^128.
        uint256 sqrtPriceX96 = totalSupply / marketCapEth < (1 << 64)
            ? Math.sqrt(FullMath.mulDiv(totalSupply, 1 << 192, marketCapEth))
            : Math.sqrt(FullMath.mulDiv(totalSupply, 1 << 128, marketCapEth)) << 32;
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidMarketCap();
        }
        int24 raw = TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96));
        int24 compressed = raw / TICK_SPACING;
        if (raw % TICK_SPACING != 0 && raw < 0) compressed--; // floor
        if (raw - compressed * TICK_SPACING >= TICK_SPACING / 2) compressed++; // round to nearest
        tick = compressed * TICK_SPACING;
        if (tick <= TickMath.minUsableTick(TICK_SPACING) || tick > TickMath.maxUsableTick(TICK_SPACING)) {
            revert InvalidMarketCap();
        }
    }

    /// @notice Liquidity of the launch position that holds `totalSupply` tokens over [minUsableTick, startTick].
    ///         L = totalSupply * 2^96 / (sqrtStart - sqrtMin), i.e. roughly sqrt(totalSupply * marketCap).
    /// @dev    Reverts with SupplyTooLargeForPrice above the v4 per-tick liquidity limit (~1.1e34 for tick spacing
    ///         60), which v4 would otherwise reject deep inside modifyLiquidity. Only reachable with absurd inputs
    ///         (supply x market cap above ~1e68 in wei units).
    function liquidityFor(uint256 totalSupply, int24 startTick) public pure returns (uint128) {
        uint256 liquidity = FullMath.mulDiv(
            totalSupply,
            FixedPoint96.Q96,
            TickMath.getSqrtPriceAtTick(startTick) - TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING))
        );
        if (liquidity == 0) revert InvalidSupply(); // dust supply: nothing to place
        if (liquidity > Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING)) revert SupplyTooLargeForPrice();
        return uint128(liquidity);
    }

    /// @notice The v4 pool key of an ERC20 launched by this factory.
    function poolKeyOf(address token) external view returns (PoolKey memory key) {
        if (!isFactoryToken[token] || tokenType[token] != TokenType.ERC20) revert NotERC20();
        return _poolKeys[token];
    }

    /// @notice Address a token will be deployed at for a given creator, type and salt.
    function predictAddress(TokenType kind, address creator, bytes32 salt) external view returns (address) {
        address impl = kind == TokenType.ERC20
            ? erc20Implementation
            : kind == TokenType.ERC721 ? erc721Implementation : erc1155Implementation;
        return Clones.predictDeterministicAddress(impl, _salt(creator, salt));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Binding the salt to the creator stops others from front-running a predicted address.
    function _salt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
