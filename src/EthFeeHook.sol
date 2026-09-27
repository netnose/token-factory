// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title EthFeeHook
/// @notice Uniswap v4 hook that charges a fee, always in ETH, on every swap in the ETH/TOKEN pools launched by the
///         TokenFactory.
///
/// ====================================================================================================================
///  WHAT IT CHARGES
/// ====================================================================================================================
///
///   fee = amount of ETH in or out of the swap  x  (creator fee + sniper fee)
///
///   - creator fee: 0-5%, chosen by the creator at launch. The pool owner can lower it, never raise it.
///                  The platform takes `protocolShareBps` (max 10%) of it; the rest goes to the pool owner.
///   - sniper fee:  only right after launch. The total fee starts at e.g. 80% and decays to the creator fee over
///                  e.g. 15 seconds, so bots buying in the first blocks pay heavily. All of it goes to the platform.
///                  See `currentFee` for the curve.
///
///   Example: creator fee 5%, platform share 10%, 15s after launch, someone buys with 1 ETH:
///     fee = 0.05 ETH -> 0.045 ETH to the pool owner, 0.005 ETH to the platform; 0.95 ETH is swapped into tokens.
///
///   Swaps made by the factory itself pay nothing: that is how the creator's capped launch buy is fee-free.
///
/// ====================================================================================================================
///  UNISWAP V4 BACKGROUND (what the code relies on)
/// ====================================================================================================================
///
///   Hooks & permissions  A pool names a hook contract in its PoolKey. The PoolManager calls the hook around pool
///                        actions, but only the ones enabled by flag bits in the low 14 bits of the hook's ADDRESS.
///                        This contract must be deployed (via a mined CREATE2 salt) at an address whose bits enable
///                        exactly: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta and
///                        afterSwapReturnDelta. The constructor checks it.
///
///   Currencies           ETH is represented as address(0). Pools sort their two currencies, so ETH is always
///                        currency0 and the token is always currency1.
///
///   Swap direction       zeroForOne = true  means currency0 -> currency1, i.e. ETH -> token: a BUY.
///                        zeroForOne = false means token -> ETH: a SELL.
///
///   Exact in / out       amountSpecified < 0: exact input  ("I pay exactly X").
///                        amountSpecified > 0: exact output ("I receive exactly X").
///                        The "specified" currency is the one the user fixed; the other is "unspecified" (computed).
///
///   Deltas               The PoolManager keeps a running balance ("delta") per address and currency during a
///                        transaction; everything must net to zero before it ends. A hook can take a cut of a swap
///                        by returning a delta:
///                          - beforeSwap returns one on the SPECIFIED currency (it can shrink or grow the swap),
///                          - afterSwap returns one on the UNSPECIFIED currency (after the swap result is known).
///                        A positive hook delta means "the hook is owed this": the PoolManager charges the swapper
///                        that much more (or pays them that much less) and credits the hook.
///
///   ERC-6909 claims      Instead of receiving ETH, the hook balances its credit by minting itself (or the factory)
///                        ERC-6909 claim tokens on the PoolManager, redeemable 1:1 for ETH later. No ETH moves during
///                        the swap, which (a) works even if the PoolManager does not hold the swapper's ETH yet at that
///                        point, and (b) means a fee recipient that rejects ETH can never make a swap fail.
///
/// ====================================================================================================================
///  WHERE THE FEE IS TAKEN
/// ====================================================================================================================
///
///   The fee is always computed on the ETH leg. Which callback takes it depends on whether ETH is the specified leg:
///
///   | swap                  | ETH leg     | taken in    | effect for the user                                     |
///   |-----------------------|-------------|-------------|---------------------------------------------------------|
///   | buy,  exact ETH in    | specified   | beforeSwap  | pays exactly X ETH; X - fee is swapped                  |
///   | buy,  exact tokens out| unspecified | afterSwap   | gets exactly N tokens; pays their cost + fee            |
///   | sell, exact tokens in | unspecified | afterSwap   | receives the ETH the swap produced - fee                |
///   | sell, exact ETH out   | specified   | beforeSwap  | receives exactly X ETH; pool pays out X + fee (more     |
///   |                       |             |             | tokens are sold)                                        |
///
///   All-or-nothing when ETH is specified: in those two rows the fee is fixed before the swap runs (a delta on the
///   specified leg can only be returned from beforeSwap), so if the swap then filled only partly - a price limit
///   stopped it early, or a sell asked for more ETH than the pool holds - the user would pay the fee on ETH that was
///   never swapped. afterSwap therefore reverts such swaps with `PartialFill`. Uniswap's own router applies the same
///   rule to exact-output swaps and never sets a price limit, so normal trades are unaffected. (The factory's
///   launch buy is exempt: it is fee-free and stops at the 10% owner cap on purpose.)
///
/// ====================================================================================================================
///  WHERE THE MONEY GOES
/// ====================================================================================================================
///
///   - Pool owner's part: ERC-6909 ETH claims minted to THIS contract and recorded in `owed[owner]`.
///                        Paid out in ETH by `claim()`, `claimTo(to)` or `claimFor(owner)`.
///   - Platform's part:   ERC-6909 ETH claims minted straight to the FACTORY during the swap. The factory owner
///                        withdraws them (with all other platform revenue) in one call.
///   Invariant: this contract's ERC-6909 ETH balance == sum of `owed`.
///
/// ====================================================================================================================
///  TRUST MODEL
/// ====================================================================================================================
///
///   - Only the factory can create pools with this hook (`beforeInitialize`), and it registers each pool's config
///     first. The config is fixed at launch: the platform cannot change an existing pool's fee, protocol share or
///     sniper settings. Only the pool owner can change anything, and only by lowering the creator fee or handing
///     ownership to another address.
///   - There is no admin, no upgradeability and no way to move owners' funds except to the owner.
///   - One hook instance serves every pool: a hook's permissions live in its address, so a hook per token would need
///     a new mined address per launch (and a new Uniswap routing allowlist entry each time).
contract EthFeeHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;

    /// @notice Maximum creator fee: 5%.
    uint16 public constant MAX_FEE_BPS = 500;
    /// @notice Maximum share of the creator fee paid to the platform: 10%.
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 1_000;
    /// @notice Maximum total fee at the moment of launch while sniper protection is active: 90%.
    uint16 public constant MAX_SNIPER_FEE_BPS = 9_000;
    /// @notice Longest allowed sniper-protection window.
    uint32 public constant MAX_SNIPER_DURATION = 10 minutes;
    /// @notice Steepest allowed sniper curve (see `SniperConfig.halvings`).
    uint8 public constant MAX_SNIPER_HALVINGS = 32;
    /// @dev Basis-point denominator: 10_000 bps = 100%.
    uint256 internal constant BPS = 10_000;
    /// @dev 1.0 in 18-decimal fixed point, used by the decay curve.
    uint256 internal constant ONE = 1e18;

    IPoolManager public immutable poolManager;
    /// @notice The factory: the only address allowed to create pools with this hook, the recipient of the platform's
    ///         share of every fee, and the only swapper that pays no fee (its capped launch buy).
    address public immutable factory;

    /// @notice Sniper protection settings, chosen by the platform and copied into each pool at launch.
    struct SniperConfig {
        /// Total fee (creator fee + sniper fee) at the launch timestamp, in bps. 0 (or anything <= the creator fee)
        /// disables sniper protection for the pool.
        uint16 startFeeBps;
        /// Seconds after launch at which the sniper fee reaches exactly 0.
        uint32 duration;
        /// Curve steepness: the sniper fee halves `halvings` times over `duration` (then the curve is rescaled so it
        /// lands exactly on 0). Higher = drops faster early on. E.g. 5 halvings over 15s = one halving every 3s.
        uint8 halvings;
    }

    /// @notice Per-pool settings, written once by the factory at launch.
    struct PoolConfig {
        /// Receives the pool owner's part of the fee; the only address that can lower the fee or transfer ownership.
        address owner;
        /// Creator fee in bps of the ETH leg of every swap. Can only go down.
        uint16 feeBps;
        /// Platform share of the creator fee, in bps. Fixed at launch.
        uint16 protocolShareBps;
        /// True once the factory has registered the pool.
        bool registered;
        /// Timestamp of the launch: the start of the sniper-protection window.
        uint40 launchTime;
        /// Sniper protection for this pool. Fixed at launch.
        SniperConfig sniper;
    }

    mapping(PoolId => PoolConfig) public poolConfig;
    /// @notice ETH owed to each pool owner, claimable with `claim`. Backed 1:1 by this contract's ERC-6909 ETH claims.
    mapping(address => uint256) public owed;

    event PoolRegistered(
        PoolId indexed poolId, address indexed owner, uint16 feeBps, uint16 protocolShareBps, SniperConfig sniper
    );
    event FeeLowered(PoolId indexed poolId, uint16 oldFeeBps, uint16 newFeeBps);
    event PoolOwnershipTransferred(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);
    /// @notice Emitted on every charged swap. `ownerAmount + protocolAmount` is the total fee in wei of ETH.
    event FeeAccrued(PoolId indexed poolId, address indexed owner, uint256 ownerAmount, uint256 protocolAmount);
    event Claimed(address indexed owner, address indexed to, uint256 amount);

    error NotPoolManager();
    error NotFactory();
    error NotPoolOwner();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error NotNativePool();
    error FeeTooHigh();
    error InvalidSniperConfig();
    error FeeNotLowered();
    error InvalidRecipient();
    error NothingToClaim();
    error HookNotImplemented();
    /// @notice A swap with a fixed ETH amount did not fill completely (see `_requireFullFill`).
    error PartialFill(uint256 expectedEth, uint256 actualEth);

    /// @dev Hook callbacks and the unlock callback must only be triggered by the PoolManager itself.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Reverts unless this contract was deployed at an address whose flag bits match `getHookPermissions`.
    constructor(IPoolManager _poolManager, address _factory) {
        poolManager = _poolManager;
        factory = _factory;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice The callbacks this hook uses. Must match the flag bits of the deployment address.
    ///         - beforeInitialize:       only the factory may create pools with this hook.
    ///         - beforeSwap / afterSwap: charge the fee (on the specified / unspecified ETH leg respectively).
    ///         - *ReturnDelta:           allow those two callbacks to take a cut of the swap by returning a delta.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =================================================================================================================
    // Factory
    // =================================================================================================================

    /// @notice Records a new pool's fee config. Called by the factory right before it initializes the pool (the
    ///         `beforeInitialize` callback rejects pools that were not registered). Starts the sniper window now.
    /// @param key              The pool; must be native ETH (currency0 = address(0)) paired with the token.
    /// @param owner            Pool owner: receives the owner's part of the fee and may lower the fee.
    /// @param feeBps           Creator fee, max MAX_FEE_BPS.
    /// @param protocolShareBps Platform share of the creator fee, max MAX_PROTOCOL_SHARE_BPS.
    /// @param sniper           Sniper protection settings (see `validateSniperConfig`).
    function registerPool(
        PoolKey calldata key,
        address owner,
        uint16 feeBps,
        uint16 protocolShareBps,
        SniperConfig calldata sniper
    ) external {
        if (msg.sender != factory) revert NotFactory();
        // The fee logic assumes ETH is currency0 (it always is when one side is native ETH).
        if (!key.currency0.isAddressZero()) revert NotNativePool();
        if (feeBps > MAX_FEE_BPS || protocolShareBps > MAX_PROTOCOL_SHARE_BPS) revert FeeTooHigh();
        validateSniperConfig(sniper);
        if (owner == address(0)) revert InvalidRecipient();
        PoolId id = key.toId();
        if (poolConfig[id].registered) revert PoolAlreadyRegistered();
        poolConfig[id] = PoolConfig({
            owner: owner,
            feeBps: feeBps,
            protocolShareBps: protocolShareBps,
            registered: true,
            launchTime: uint40(block.timestamp),
            sniper: sniper
        });
        emit PoolRegistered(id, owner, feeBps, protocolShareBps, sniper);
    }

    /// @notice Reverts if a sniper config is out of bounds: start fee above 90%, window above 10 minutes, more than 32
    ///         halvings, or an enabled config (start fee > 0) with a zero window or zero halvings.
    function validateSniperConfig(SniperConfig calldata s) public pure {
        if (s.startFeeBps > MAX_SNIPER_FEE_BPS || s.duration > MAX_SNIPER_DURATION || s.halvings > MAX_SNIPER_HALVINGS)
        {
            revert InvalidSniperConfig();
        }
        if (s.startFeeBps > 0 && (s.duration == 0 || s.halvings == 0)) revert InvalidSniperConfig();
    }

    // =================================================================================================================
    // Pool owner
    // =================================================================================================================

    /// @notice Lowers the pool's creator fee. Takes effect on the next swap. The fee can never be raised.
    function lowerFee(PoolId id, uint16 newFeeBps) external {
        PoolConfig storage cfg = poolConfig[id];
        if (msg.sender != cfg.owner) revert NotPoolOwner();
        uint16 old = cfg.feeBps;
        if (newFeeBps >= old) revert FeeNotLowered();
        cfg.feeBps = newFeeBps;
        emit FeeLowered(id, old, newFeeBps);
    }

    /// @notice Hands the pool's ownership (future fees + the right to lower the fee) to `newOwner`. Fees already
    ///         accrued stay claimable by the previous owner.
    function transferPoolOwnership(PoolId id, address newOwner) external {
        PoolConfig storage cfg = poolConfig[id];
        if (msg.sender != cfg.owner) revert NotPoolOwner();
        if (newOwner == address(0)) revert InvalidRecipient();
        cfg.owner = newOwner;
        emit PoolOwnershipTransferred(id, msg.sender, newOwner);
    }

    // =================================================================================================================
    // Fee views
    // =================================================================================================================

    /// @notice Fee a pool charges right now, in bps of the ETH leg of a swap.
    ///
    ///         While the sniper window is open (t = seconds since launch < T = duration):
    ///           sniperBps = (startFeeBps - creatorFee) * decay(t)
    ///           decay(t)  = (2^(-k*t/T) - 2^(-k)) / (1 - 2^(-k))        k = halvings
    ///         decay(0) = 1, so the total fee at launch is exactly `startFeeBps`; decay(T) = 0, so the total lands
    ///         exactly on the creator fee at the end of the window. In between it falls fast first, then flattens.
    ///
    ///         With the defaults (80% start, 15s, 5 halvings) and a 5% creator fee the total fee is:
    ///           t:     0s    2s     4s     6s     8s     10s    12s   15s
    ///           fee:   80%   54.2%  34.8%  21.9%  15.5%  10.6%  7.4%  5%
    ///
    /// @return totalBps  Creator fee + sniper fee.
    /// @return sniperBps The sniper part of `totalBps` (all of it goes to the platform).
    function currentFee(PoolId id) public view returns (uint256 totalBps, uint256 sniperBps) {
        PoolConfig storage cfg = poolConfig[id];
        uint256 base = cfg.feeBps;
        SniperConfig memory s = cfg.sniper;
        uint256 elapsed = block.timestamp - cfg.launchTime;
        if (s.startFeeBps > base && elapsed < s.duration) {
            sniperBps = (s.startFeeBps - base) * _decay(elapsed, s.duration, s.halvings) / ONE;
        }
        totalBps = base + sniperBps;
    }

    /// @dev decay(t) = (2^(-k*t/T) - 2^(-k)) / (1 - 2^(-k)) in 1e18 fixed point. Subtracting 2^(-k) and dividing by
    ///      (1 - 2^(-k)) rescales the plain exponential so it starts at exactly 1 and ends at exactly 0 instead of
    ///      stopping at 2^(-k) and then jumping to 0. Requires t < T and k >= 1 (guaranteed by the caller / config).
    function _decay(uint256 t, uint256 T, uint256 k) internal pure returns (uint256) {
        uint256 floor = _exp2neg(k * ONE);
        return (_exp2neg(k * t * ONE / T) - floor) * ONE / (ONE - floor);
    }

    /// @dev 2^(-x) for x in 1e18 fixed point. Exact at whole numbers (1, 1/2, 1/4, ...) and a straight line between
    ///      them, which keeps it cheap, strictly decreasing, and within ~6% of the true curve.
    function _exp2neg(uint256 x) internal pure returns (uint256) {
        uint256 n = x / ONE; // whole halvings
        if (n >= 64) return 0;
        uint256 whole = ONE >> n; // 2^(-n)
        // Between 2^(-n) and 2^(-n-1) = whole/2, move linearly by the fractional part of x.
        return whole - whole * (x % ONE) / (2 * ONE);
    }

    // =================================================================================================================
    // Claiming (pool owners)
    // =================================================================================================================

    /// @notice Pays out the caller's accrued creator fees in ETH.
    function claim() external returns (uint256) {
        return _claim(msg.sender, msg.sender);
    }

    /// @notice Pays out the caller's accrued creator fees in ETH to `to`. Lets an owner that cannot receive ETH
    ///         itself (e.g. a contract without a receive function) still get its fees out.
    function claimTo(address to) external returns (uint256) {
        if (to == address(0)) revert InvalidRecipient();
        return _claim(msg.sender, to);
    }

    /// @notice Pays out `owner`'s accrued creator fees, in ETH, to `owner` (never anywhere else), so anyone can
    ///         trigger it, e.g. a keeper.
    function claimFor(address owner) external returns (uint256) {
        return _claim(owner, owner);
    }

    /// @dev Zeroes the balance before calling out (checks-effects-interactions): a recipient re-entering finds
    ///      nothing left to claim. If the recipient rejects ETH the whole call reverts and the balance stays intact.
    function _claim(address owner, address to) internal returns (uint256 amount) {
        amount = owed[owner];
        if (amount == 0) revert NothingToClaim();
        owed[owner] = 0;
        poolManager.unlock(abi.encode(to, amount));
        emit Claimed(owner, to, amount);
    }

    /// @dev Runs inside `poolManager.unlock` during a claim: redeems `amount` of this contract's ERC-6909 ETH claims
    ///      (burn credits us) and sends that ETH to the recipient (take debits us), netting to zero.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, recipient, amount);
        return "";
    }

    // =================================================================================================================
    // Hook callbacks
    // =================================================================================================================

    /// @dev Pool creation gate: only the factory may create pools that use this hook, and only after registering
    ///      them. `sender` is whoever called `poolManager.initialize`.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        if (!poolConfig[key.toId()].registered) revert PoolNotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Charges the fee when ETH is the SPECIFIED leg (exact-in buy, exact-out sell), before the swap runs.
    ///      Returning (+fee) as the specified delta makes the PoolManager adjust the swap by `fee`:
    ///        exact-in buy  (amountSpecified = -X): the pool swaps only X - fee; the user still pays X.
    ///        exact-out sell (amountSpecified = +X): the pool pays out X + fee; the user still receives X.
    ///      The fee is on the amount the user specified. A delta on the specified leg can only be returned here,
    ///      before the fill is known, so afterSwap reverts the swap if it then fills only partly (`PartialFill`).
    ///      `sender` is the contract that called `poolManager.swap`; the factory's own launch buy pays no fee.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != factory && _ethIsSpecified(params)) {
            uint256 amount =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = _accrue(key, amount);
            // toBeforeSwapDelta(specified, unspecified); the third return value (LP fee override) is unused.
            if (fee > 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Runs after the swap, when the ETH amount is known. `delta` is the pool's swap result before the hook's
    ///      cut, from the swapper's view: `delta.amount0()` is the ETH leg (negative = paid in, positive = received).
    ///      - ETH was the UNSPECIFIED leg (exact-in sell, exact-out buy): charge the fee now, on that ETH amount.
    ///        Returning (+fee) makes the PoolManager charge the swapper `fee` more ETH on an exact-out buy, or pay
    ///        them `fee` less ETH on an exact-in sell.
    ///      - ETH was the SPECIFIED leg: the fee was charged in beforeSwap; only check the swap filled completely.
    ///      - The factory's launch buy: nothing to do (fee-free, and it stops at the owner cap on purpose).
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (sender == factory) return (IHooks.afterSwap.selector, 0);
        int128 ethDelta = delta.amount0();
        uint256 ethAmount = uint256(int256(ethDelta < 0 ? -ethDelta : ethDelta));
        if (_ethIsSpecified(params)) {
            _requireFullFill(key, params, ethAmount);
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 fee = _accrue(key, ethAmount);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    /// @dev For a swap where ETH was specified, checks the pool moved exactly the ETH beforeSwap told it to:
    ///        exact-in buy  (specified X): the pool must take in  X - fee
    ///        exact-out sell (specified X): the pool must pay out X + fee
    ///      Otherwise the swap filled only partly and the fee (charged on all of X) would include ETH that was never
    ///      swapped, so it reverts. `fee` is recomputed exactly as beforeSwap computed it: same pool, same block, and
    ///      nothing can change the pool's fee config in between.
    function _requireFullFill(PoolKey calldata key, SwapParams calldata params, uint256 ethAmount) internal view {
        uint256 specified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        (uint256 totalBps,) = currentFee(key.toId());
        uint256 fee = specified * totalBps / BPS;
        uint256 expected = params.amountSpecified < 0 ? specified - fee : specified + fee;
        if (ethAmount != expected) revert PartialFill(expected, ethAmount);
    }

    /// @dev Whether ETH (currency0) is the leg the user fixed. The specified leg is the input on exact-in swaps and
    ///      the output on exact-out swaps, so ETH is specified on buys that are exact-in (zeroForOne && amount < 0)
    ///      and on sells that are exact-out (!zeroForOne && amount > 0).
    function _ethIsSpecified(SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    /// @dev Computes and books the fee on `amount` wei of ETH.
    ///
    ///        fee            = amount * (creator + sniper bps)        total the swapper pays
    ///        sniperAmount   = amount * sniper bps                    -> platform
    ///        creatorFee     = fee - sniperAmount
    ///        protocolAmount = sniperAmount + creatorFee * share      -> platform (minted to the factory)
    ///        ownerAmount    = fee - protocolAmount                   -> pool owner (minted to this hook, `owed`)
    ///
    ///      The hook returns `fee` as its delta, which the PoolManager credits to the hook; minting ERC-6909 claims
    ///      debits the hook by the same total, so the hook's balance with the PoolManager nets to zero.
    function _accrue(PoolKey calldata key, uint256 amount) internal returns (uint256 fee) {
        PoolId id = key.toId();
        (uint256 totalBps, uint256 sniperBps) = currentFee(id);
        fee = amount * totalBps / BPS;
        if (fee == 0) return 0;
        PoolConfig storage cfg = poolConfig[id];
        uint256 sniperAmount = amount * sniperBps / BPS;
        uint256 creatorFee = fee - sniperAmount;
        uint256 protocolAmount = sniperAmount + creatorFee * cfg.protocolShareBps / BPS;
        uint256 ownerAmount = fee - protocolAmount;
        address owner = cfg.owner;
        uint256 ethId = CurrencyLibrary.ADDRESS_ZERO.toId();
        if (ownerAmount > 0) {
            poolManager.mint(address(this), ethId, ownerAmount);
            owed[owner] += ownerAmount;
        }
        if (protocolAmount > 0) poolManager.mint(factory, ethId, protocolAmount);
        emit FeeAccrued(id, owner, ownerAmount, protocolAmount);
    }

    // =================================================================================================================
    // Unused hook callbacks
    // =================================================================================================================
    // Required by the IHooks interface. The PoolManager never calls them because their permission bits are not set
    // in this contract's address; they revert in case anything else does.

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
