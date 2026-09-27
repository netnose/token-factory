# token-factory

A factory for ERC20, ERC721 and ERC1155 tokens on Uniswap v4. It targets Base Sepolia first.

| Contract | What it does |
| --- | --- |
| `src/TokenFactory.sol` | Deploys all three token types as cheap EIP-1167 clones with deterministic addresses. Launches each ERC20 into its own v4 pool. |
| `src/EthFeeHook.sol` | Uniswap v4 hook that charges the ERC20 creator's fee (0–5%) in ETH on every swap. |
| `src/tokens/FactoryERC20.sol` | Fixed-supply ERC20 with EIP-2612 permit. No owner and no minting after launch. |
| `src/tokens/FactoryERC721.sol` | ERC721 collection. Only the owner can mint. Uses `baseURI + tokenId` for metadata. |
| `src/tokens/FactoryERC1155.sol` | ERC1155 collection. Only the owner can mint. |

## How an ERC20 launch works

`createERC20` does all of the following in one transaction:

1. It deploys the token clone and mints the **entire supply to the factory**. Nothing can be minted after that.
2. It registers the pool with the hook: the creator becomes the fee owner, with the chosen `feeBps` (at most 500).
3. It initializes a **native ETH / TOKEN** v4 pool at `startTick`. ETH is always `currency0`. The pool has an LP fee of 0, `tickSpacing` 200, and uses the `EthFeeHook`.
4. It adds the whole supply as **one-sided liquidity** across `[minUsableTick, startTick]`. Buyers pay ETH to move down the curve, and sellers can swap back.
5. The factory owns the position and has no function to remove it, so the **liquidity is locked forever**.

The starting price is `1.0001^startTick` tokens per ETH. For 1B tokens at a 10 ETH starting market cap:
`ln(1e9/10)/ln(1.0001) ≈ 184206`, which rounds to `184200`.

## Fees

The **swap fee** is always charged in ETH, because it is taken on the ETH side of the swap:

| Swap | Where the fee is taken | Effect |
| --- | --- | --- |
| Buy, exact ETH in | `beforeSwap` | You pay exactly X ETH, and X − fee is swapped. |
| Buy, exact tokens out | `afterSwap` | You pay the swap cost + fee. |
| Sell, exact tokens in | `afterSwap` | You receive the swap output − fee. |
| Sell, exact ETH out | `beforeSwap` | You receive exactly X ETH, and the swap sells enough tokens to cover X + fee. |

- **Creator's fee:** set at launch, capped at 5%. The pool owner can only lower it (`lowerFee`), never raise it. `transferPoolOwnership` sends future fees to a new address.
- **Platform share:** a percentage of each swap fee, up to 50%, that goes to the protocol recipient. The factory owner sets it with `hook.setProtocolFee`. Each pool keeps the share that applied when it was created, so a later change can't touch existing tokens.
- **Payout:** fees build up in the hook as ERC-6909 ETH claims on the PoolManager. They are paid out in ETH with `claim()`, or with `claimFor(addr)`, which anyone can call. Because nothing is sent during a swap, a recipient that rejects ETH can never block trading.
- **Creation fee:** a flat ETH fee on every `create*` call, set with `factory.setCreationFee`. The factory owner collects it with `withdrawFees`.

### Why there is one shared hook

A v4 hook's permissions live in the low 14 bits of its address, so every hook needs a mined CREATE2 salt. A separate hook per token would mean mining a salt for every launch. Instead, the protocol deploys one `EthFeeHook` and it keeps a separate fee config for each pool. Only the factory can create pools with it (`beforeInitialize`).

## Development

```bash
forge build
forge test
```

## Deploy (Base Sepolia)

The script uses Uniswap v4's PoolManager on Base Sepolia, `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`.

```bash
cp .env.example .env && source .env
# optional: PROTOCOL_SHARE_BPS, PROTOCOL_RECIPIENT, CREATION_FEE, FACTORY_OWNER
forge script script/Deploy.s.sol --rpc-url base_sepolia --account <keystore> --broadcast --verify

# launch a token
FACTORY=<factory> NAME="My Token" SYMBOL=MYT FEE_BPS=300 START_TICK=184200 \
  forge script script/CreateToken.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
```

The deploy script mines the hook salt against the standard CREATE2 deployer, deploys the factory and the hook, then wires them together with `setHook`.

## Known trade-offs

- On an exact-in buy with a `sqrtPriceLimit` that stops the swap early, the fee is still charged on the full amount specified. Normal routers don't set a limit like that.
- Launches have no anti-sniping protection. Anyone can buy in the block after launch.
- None of this has been audited. Get a review before deploying to mainnet.
