// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {EthFeeHook} from "./EthFeeHook.sol";
import {FactoryERC20} from "./tokens/FactoryERC20.sol";
import {FactoryERC721} from "./tokens/FactoryERC721.sol";
import {FactoryERC1155} from "./tokens/FactoryERC1155.sol";

/// @title TokenFactory
/// @notice Deploys ERC20, ERC721 and ERC1155 contracts as cheap minimal-proxy clones.
///
///         ERC20 launches are fixed supply: the entire supply is placed as one-sided liquidity in a native ETH /
///         TOKEN Uniswap v4 pool that uses the EthFeeHook. Buyers swap ETH for the token along the curve; the hook
///         charges the creator's fee (0-5%, can only be lowered) in ETH on every buy and sell. The liquidity
///         position is owned by this contract and there is no function to remove it, so it is locked forever.
///
///         The factory owner can charge a flat ETH creation fee and a share of swap fees (set on the hook).
contract TokenFactory is Ownable, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice LP fee of launch pools. Zero: the hook fee is the only swap fee and the locked position earns nothing.
    uint24 public constant POOL_LP_FEE = 0;
    int24 public constant TICK_SPACING = 200;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable erc20Implementation;
    address public immutable erc721Implementation;
    address public immutable erc1155Implementation;

    EthFeeHook public hook;
    uint256 public creationFee;

    struct ERC20Params {
        string name;
        string symbol;
        /// Total supply in wei (18 decimals). All of it goes into the pool.
        uint256 totalSupply;
        /// Creator's swap fee in basis points, max 500 (5%).
        uint16 feeBps;
        /// Starting price as a v4 tick: price = 1.0001^tick tokens per ETH. Must be a multiple of TICK_SPACING.
        /// e.g. 1B supply at a 10 ETH starting market cap -> 1e8 tokens/ETH -> tick ~184200.
        int24 startTick;
        /// Salt for the token's deterministic address (combined with msg.sender).
        bytes32 salt;
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
        int24 startTick
    );
    event ERC721Created(address indexed token, address indexed creator);
    event ERC1155Created(address indexed token, address indexed creator);
    event HookSet(address hook);
    event CreationFeeUpdated(uint256 fee);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error HookAlreadySet();
    error HookNotSet();
    error InvalidHook();
    error WrongCreationFee();
    error InvalidSupply();
    error InvalidStartTick();
    error NotPoolManager();
    error NotERC20();

    constructor(IPoolManager _poolManager, address _owner) Ownable(_owner) {
        poolManager = _poolManager;
        erc20Implementation = address(new FactoryERC20());
        erc721Implementation = address(new FactoryERC721());
        erc1155Implementation = address(new FactoryERC1155());
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

    function setCreationFee(uint256 fee) external onlyOwner {
        creationFee = fee;
        emit CreationFeeUpdated(fee);
    }

    function withdrawFees(address payable to) external onlyOwner {
        uint256 amount = address(this).balance;
        emit FeesWithdrawn(to, amount);
        Address.sendValue(to, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Creation
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Creates a fixed-supply ERC20 and launches it in a one-sided ETH/TOKEN v4 pool with the fee hook.
    /// @return token The new token.
    /// @return poolId The id of its v4 pool.
    function createERC20(ERC20Params calldata p) external payable returns (address token, PoolId poolId) {
        _collectCreationFee();
        EthFeeHook _hook = hook;
        if (address(_hook) == address(0)) revert HookNotSet();
        if (p.totalSupply == 0 || p.totalSupply > type(uint128).max) revert InvalidSupply();
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        if (
            p.startTick % TICK_SPACING != 0 || p.startTick <= minTick
                || p.startTick > TickMath.maxUsableTick(TICK_SPACING)
        ) {
            revert InvalidStartTick();
        }

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

        _hook.registerPool(key, msg.sender, p.feeBps);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(p.startTick));

        // One-sided position holding only the token: [minTick, startTick] lies entirely at/below the current tick.
        // Buying (ETH -> token) moves the price down through the range.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(minTick), TickMath.getSqrtPriceAtTick(p.startTick), p.totalSupply
        );
        poolManager.unlock(abi.encode(key, minTick, p.startTick, liquidity));

        // Rounding leaves a few wei of the token unplaced; burn them so the whole supply is in the pool.
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(DEAD, dust);

        isFactoryToken[token] = true;
        tokenType[token] = TokenType.ERC20;
        _poolKeys[token] = key;
        emit ERC20Created(token, msg.sender, poolId, p.totalSupply, p.feeBps, p.startTick);
    }

    /// @notice Creates an ERC721 collection owned (and mintable only) by the caller.
    function createERC721(string calldata name, string calldata symbol, string calldata baseURI, bytes32 salt)
        external
        payable
        returns (address token)
    {
        _collectCreationFee();
        token = Clones.cloneDeterministic(erc721Implementation, _salt(msg.sender, salt));
        FactoryERC721(token).initialize(name, symbol, baseURI, msg.sender);
        isFactoryToken[token] = true;
        tokenType[token] = TokenType.ERC721;
        emit ERC721Created(token, msg.sender);
    }

    /// @notice Creates an ERC1155 collection owned (and mintable only) by the caller.
    function createERC1155(string calldata name, string calldata symbol, string calldata uri, bytes32 salt)
        external
        payable
        returns (address token)
    {
        _collectCreationFee();
        token = Clones.cloneDeterministic(erc1155Implementation, _salt(msg.sender, salt));
        FactoryERC1155(token).initialize(name, symbol, uri, msg.sender);
        isFactoryToken[token] = true;
        tokenType[token] = TokenType.ERC1155;
        emit ERC1155Created(token, msg.sender);
    }

    /// @dev Adds the one-sided token liquidity and pays for it from the factory's token balance.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );

        // The position is below the current price, so it only needs the token (amount0 == 0).
        uint256 owed = uint256(uint128(-delta.amount1()));
        poolManager.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        return "";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

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

    function _collectCreationFee() internal view {
        if (msg.value != creationFee) revert WrongCreationFee();
    }

    /// @dev Binding the salt to the creator stops others from front-running a predicted address.
    function _salt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
