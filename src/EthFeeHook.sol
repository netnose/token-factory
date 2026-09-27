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
/// @notice Uniswap v4 hook that charges a fee on every swap in native-ETH pools created by the TokenFactory. The fee is
///         always taken on the ETH side of the swap (ETH in on buys, ETH out on sells), so it is always paid in ETH.
///
///         fee = creator fee (0-5%, can only be lowered)          -> creator, minus the protocol share (max 10%)
///             + sniper fee (decays to 0 shortly after launch)    -> protocol
///
///         The protocol's part is credited to the factory immediately, as ERC-6909 ETH claims on the PoolManager, so
///         the factory owner can withdraw all platform revenue in one call. Swaps made by the factory itself (the
///         creator's launch buy) pay no fee.
///
///         The sniper fee makes the total fee start at `sniperStartFeeBps` (e.g. 80%) at launch and decay
///         exponentially to the creator fee over `sniperDuration` seconds (e.g. 15s).
/// @dev    Fees are accrued as ERC-6909 ETH claims on the PoolManager (no ETH moves during the swap, so a swap can
///         never fail because a fee recipient rejects ETH) and creators are paid out in ETH through `claim`.
///         One hook instance serves every pool the factory creates: a v4 hook's permissions are encoded in its
///         address, so a per-token hook would need a fresh CREATE2 salt mined for every launch.
contract EthFeeHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;

    /// @notice Maximum creator fee: 5%.
    uint16 public constant MAX_FEE_BPS = 500;
    /// @notice Maximum share of the creator fee paid to the platform: 10%.
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 1_000;
    /// @notice Maximum total fee at launch while sniper protection is active: 90%.
    uint16 public constant MAX_SNIPER_FEE_BPS = 9_000;
    uint32 public constant MAX_SNIPER_DURATION = 10 minutes;
    uint8 public constant MAX_SNIPER_HALVINGS = 32;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;

    IPoolManager public immutable poolManager;
    /// @notice The factory allowed to create pools with this hook. Receives the protocol's share of every fee.
    address public immutable factory;

    struct SniperConfig {
        /// Total fee at the launch timestamp, in bps. No sniper fee if it is <= the creator fee.
        uint16 startFeeBps;
        /// Seconds after launch at which the sniper fee reaches 0.
        uint32 duration;
        /// Steepness: how many times the sniper fee halves over `duration` before being scaled to hit 0 exactly.
        uint8 halvings;
    }

    struct PoolConfig {
        address owner; // receives the creator fee, may lower it
        uint16 feeBps; // creator fee on the ETH side of every swap
        uint16 protocolShareBps; // share of the creator fee paid to the platform, fixed at pool creation
        bool registered;
        uint40 launchTime;
        SniperConfig sniper;
    }

    mapping(PoolId => PoolConfig) public poolConfig;
    /// @notice ETH owed to each pool owner, claimable with `claim`.
    mapping(address => uint256) public owed;

    event PoolRegistered(
        PoolId indexed poolId, address indexed owner, uint16 feeBps, uint16 protocolShareBps, SniperConfig sniper
    );
    event FeeLowered(PoolId indexed poolId, uint16 oldFeeBps, uint16 newFeeBps);
    event PoolOwnershipTransferred(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);
    event FeeAccrued(PoolId indexed poolId, address indexed owner, uint256 ownerAmount, uint256 protocolAmount);
    event Claimed(address indexed recipient, uint256 amount);

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

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _factory) {
        poolManager = _poolManager;
        factory = _factory;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

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

    // ---------------------------------------------------------------------------------------------------------------
    // Factory
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Registers the fee config for a pool. Must be called by the factory before it initializes the pool.
    ///         The launch time (start of sniper protection) is the current block timestamp.
    function registerPool(
        PoolKey calldata key,
        address owner,
        uint16 feeBps,
        uint16 protocolShareBps,
        SniperConfig calldata sniper
    ) external {
        if (msg.sender != factory) revert NotFactory();
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

    function validateSniperConfig(SniperConfig calldata s) public pure {
        if (s.startFeeBps > MAX_SNIPER_FEE_BPS || s.duration > MAX_SNIPER_DURATION || s.halvings > MAX_SNIPER_HALVINGS)
        {
            revert InvalidSniperConfig();
        }
        if (s.startFeeBps > 0 && (s.duration == 0 || s.halvings == 0)) revert InvalidSniperConfig();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pool owner
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Lowers the pool's creator fee. The fee can never be raised.
    function lowerFee(PoolId id, uint16 newFeeBps) external {
        PoolConfig storage cfg = poolConfig[id];
        if (msg.sender != cfg.owner) revert NotPoolOwner();
        uint16 old = cfg.feeBps;
        if (newFeeBps >= old) revert FeeNotLowered();
        cfg.feeBps = newFeeBps;
        emit FeeLowered(id, old, newFeeBps);
    }

    /// @notice Transfers the right to receive (and lower) the pool's creator fee.
    function transferPoolOwnership(PoolId id, address newOwner) external {
        PoolConfig storage cfg = poolConfig[id];
        if (msg.sender != cfg.owner) revert NotPoolOwner();
        if (newOwner == address(0)) revert InvalidRecipient();
        cfg.owner = newOwner;
        emit PoolOwnershipTransferred(id, msg.sender, newOwner);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fee views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Fee currently charged by a pool, in bps of the ETH side of a swap.
    /// @return totalBps Creator fee + sniper fee.
    /// @return sniperBps The part of `totalBps` that is the sniper fee.
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

    /// @dev Normalized exponential decay from 1 (t = 0) to exactly 0 (t = T), 1e18 fixed point:
    ///      (2^(-k*t/T) - 2^(-k)) / (1 - 2^(-k)).
    function _decay(uint256 t, uint256 T, uint256 k) internal pure returns (uint256) {
        uint256 floor = _exp2neg(k * ONE);
        return (_exp2neg(k * t * ONE / T) - floor) * ONE / (ONE - floor);
    }

    /// @dev 2^(-x) for x in 1e18 fixed point. Exact at integer x, linear in between (monotonically decreasing).
    function _exp2neg(uint256 x) internal pure returns (uint256) {
        uint256 n = x / ONE;
        if (n >= 64) return 0;
        uint256 whole = ONE >> n;
        return whole - whole * (x % ONE) / (2 * ONE);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Pays out the caller's accrued creator fees in ETH.
    function claim() external returns (uint256) {
        return _claimOwner(msg.sender);
    }

    /// @notice Pays out `recipient`'s accrued creator fees in ETH to `recipient`. Callable by anyone.
    function claimFor(address recipient) external returns (uint256) {
        return _claimOwner(recipient);
    }

    function _claimOwner(address recipient) internal returns (uint256 amount) {
        amount = owed[recipient];
        if (amount == 0) revert NothingToClaim();
        owed[recipient] = 0;
        poolManager.unlock(abi.encode(recipient, amount));
        emit Claimed(recipient, amount);
    }

    /// @dev Converts the hook's ERC-6909 ETH claims back into ETH and sends it to the recipient.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, recipient, amount);
        return "";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------------------------

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

    /// @dev When ETH is the specified currency (exact-in buy / exact-out sell) the fee is taken here, on the amount the
    ///      user specified: the caller pays `amount` ETH of which `amount - fee` is swapped on an exact-in buy, or
    ///      receives exactly `amount` ETH while the pool pays out `amount + fee` on an exact-out sell.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != factory && _ethIsSpecified(params)) {
            uint256 amount =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = _accrue(key, amount);
            if (fee > 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev When ETH is the unspecified currency (exact-in sell / exact-out buy) the fee is taken here, on the ETH
    ///      amount the swap actually produced: the seller receives `out - fee`, the buyer pays `in + fee`.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (sender == factory || _ethIsSpecified(params)) return (IHooks.afterSwap.selector, 0);
        int128 ethDelta = delta.amount0();
        uint256 amount = uint256(int256(ethDelta < 0 ? -ethDelta : ethDelta));
        uint256 fee = _accrue(key, amount);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    /// @dev ETH is always currency0. It is the specified currency when zeroForOne and exact-in, or oneForZero and
    ///      exact-out.
    function _ethIsSpecified(SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    /// @dev Computes the fee and mints ERC-6909 ETH claims for it (balancing the delta the hook returns to the
    ///      PoolManager): the owner's part to this hook, credited to `owed`; the protocol's part straight to the factory.
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

    // ---------------------------------------------------------------------------------------------------------------
    // Unused hook callbacks
    // ---------------------------------------------------------------------------------------------------------------

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
