# token-factory

A factory for ERC20, ERC721 and ERC1155 tokens on Uniswap v4. It targets Base Sepolia first.

| Contract | What it does |
| --- | --- |
| `src/TokenFactory.sol` | Deploys all three token types as cheap EIP-1167 clones with deterministic addresses. Launches each ERC20 into its own v4 pool. Holds the platform config. |
| `src/EthFeeHook.sol` | Uniswap v4 hook that charges the creator fee (0–5%) plus a decaying sniper fee, always in ETH. |
| `src/tokens/FactoryERC20.sol` | Fixed-supply ERC20 with EIP-2612 permit. No owner and no minting after launch. |
| `src/tokens/FactoryERC721.sol` | ERC721 collection: free owner mint, a paid public mint, and ERC-2981 royalties. |
| `src/tokens/FactoryERC1155.sol` | ERC1155 collection: free owner mint, a paid public mint and a metadata URI per token id, and ERC-2981 royalties. |
| `src/tokens/MintRevenue.sol` | Shared NFT plumbing: sends the platform's cut of each mint to the factory, handles owner withdrawals and royalties. |

## How an ERC20 launch works

`createERC20(name, symbol, totalSupply, feeBps, marketCapEth, salt)` is payable, and does all of the following in one transaction:

1. It deploys the token clone and mints the **entire supply to the factory**. Nothing can be minted after that.
2. It registers the pool with the hook:
   - The creator becomes the fee owner, with `feeBps` (at most 500).
   - The current platform share and sniper settings are copied into the pool's config.
3. It initializes a **native ETH / TOKEN** v4 pool at the chosen **market cap in ETH**:
   - The price is `totalSupply / marketCapEth` tokens per ETH, rounded to the nearest tick. That rounding changes the market cap by at most 0.3%.
   - `factory.startTickFor(supply, marketCap)` shows the exact starting tick.
   - ETH is always `currency0`. The pool has an LP fee of 0, `tickSpacing` 60, and uses the `EthFeeHook`.
4. It adds the whole supply as **one-sided liquidity** below the starting price. Buyers pay ETH to move down the curve, and sellers can swap back.
5. **Owner buy:** any ETH sent with the call is swapped for the creator right away.
   - This buy pays **no fees at all**: no creator fee, no sniper fee, no platform share. The hook skips fees for swaps made by the factory, and the factory swaps only during creation.
   - The tokens go to the caller, and the buy emits an `OwnerBuy` event.
6. The factory owns the position and has no function to remove it, so the **liquidity is locked forever**.

## Swap fees (always in ETH)

The fee is always taken on the ETH side of the swap: ETH in on buys, ETH out on sells.

```
fee = creator fee (0–5%, can only be lowered)   -> creator, minus the platform share (max 10%)
    + sniper fee  (decays to 0 after launch)    -> platform

(2^-x is computed exactly at whole halvings and linearly in between.)
```

**Sniper protection.** At launch, the total fee is `startFeeBps`, which defaults to **80%**. It decays exponentially and reaches the creator fee after `duration` seconds (default **15 s**). The formula is:

```
sniper(t) = (start − base) · (2^(−k·t/T) − 2^(−k)) / (1 − 2^(−k))       k = halvings (default 5), T = duration
```

With a 5% creator fee, the total fee over time is:

| Seconds after launch | 0 | 2 | 4 | 6 | 8 | 10 | 12 | 15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Total fee | 80% | 54.2% | 34.8% | 21.9% | 15.5% | 10.6% | 7.4% | 5% |

- The sniper fee applies to buys and sells alike.
- Everything above the creator fee goes to the platform.
- The factory owner sets the curve with `setSniperConfig(startFeeBps ≤ 90%, duration ≤ 10 min, halvings ≤ 32)`. Setting `startFeeBps` to 0 turns it off.
- `hook.currentFee(poolId)` returns the fee right now.

**Where the fee is taken:**

| Swap | Taken in | Effect |
| --- | --- | --- |
| Buy, exact ETH in | `beforeSwap` | You pay exactly X ETH, and X − fee is swapped. |
| Buy, exact tokens out | `afterSwap` | You pay the swap cost + fee. |
| Sell, exact tokens in | `afterSwap` | You receive the swap output − fee. |
| Sell, exact ETH out | `beforeSwap` | You receive exactly X ETH, and the swap sells enough tokens to cover X + fee. |

**Owner controls:** `lowerFee` lowers the fee and can never raise it. `transferPoolOwnership` sends future fees to a new address.

**Payout:** each fee is split between the creator and the platform at swap time, as ERC-6909 ETH claims on the PoolManager.
- **Creator's part:** held by the hook. It's paid out with `claim()`, or anyone can call `claimFor(addr)` on the creator's behalf.
- **Platform's part:** credited **straight to the factory** during the swap.
- No ETH moves during a swap, so a recipient that rejects ETH can never block trading.
- ETH can't be sent directly mid-swap, because the PoolManager may not hold it yet.

## NFT public mint

Both collections keep a free owner mint (`mint`, `mintBatch`). On top of that, **anyone** can call `publicMint` and pay the owner-set price.

| | ERC721 | ERC1155 |
| --- | --- | --- |
| Call | `publicMint(quantity)` | `publicMint(id, quantity)` |
| Price (0 = free) | One price for the collection. Set it at creation or with `setSale`. | A price per token id, set with `setSale(id, …)`. |
| Sale on/off | `setSale(…, active)` | Per id. Every id starts closed. |
| Max supply (0 = unlimited) | Covers owner and public mints. Once set, it can only be lowered, and never below what's already minted. | The same rules, per id: `setMaxSupply(id, …)`. |
| Per-wallet limit (0 = unlimited) | Counts public mints only. | Per id. |

Payment must be exact. The platform's share of mint revenue is fixed when the collection is created, and is at most 10%.
- The platform's share is **sent to the factory as part of each mint**.
- The owner collects the rest with `withdraw()`.

**ERC1155 metadata:** `setTokenURI(id, uri)` gives a token id its own URI. Ids without one use the collection's base URI (`setURI`, which may include `{id}`). Setting an empty string reverts the id to the base URI.

**Royalties (ERC-2981):** both collection types support royalties, capped at 10%.
- The royalty is set at creation. If no receiver is given, it defaults to the creator.
- The owner can change it with `setDefaultRoyalty(receiver, bps)`, or override it for a single token id with `setTokenRoyalty(id, receiver, bps)`.
- Setting `bps` to 0 removes or resets the royalty.

## Platform admin (factory owner)

- `setProtocolShare(shareBps)`: at most **10%**. It applies to creator swap fees and NFT mint revenue. The share is copied into each token when it's created, so changing it never affects existing tokens.
- `withdraw(to)`: sends **all platform revenue in one call**. That covers swap-fee claims (the platform share plus all sniper fees) and ETH from NFT mints.
- `setSniperConfig(...)`: applies only to launches from then on.

There is no creation fee.

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
# optional: PROTOCOL_SHARE_BPS (max 1000), FACTORY_OWNER
forge script script/Deploy.s.sol --rpc-url base_sepolia --account <keystore> --broadcast --verify

# launch a token
FACTORY=<factory> NAME="My Token" SYMBOL=MYT FEE_BPS=300 MARKET_CAP=10000000000000000000 OWNER_BUY=100000000000000000 \
  forge script script/CreateToken.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
```

The deploy script mines the hook salt against the standard CREATE2 deployer, deploys the factory and the hook, then wires them together with `setHook`.

## Known trade-offs

- On an exact-in buy with a `sqrtPriceLimit` that stops the swap early, the fee is still charged on the full amount specified. Normal routers don't set a limit like that.
- The sniper fee is based on timestamps. On Base (2 s blocks), the window is about 7–8 blocks.
- The creator's launch buy has no size limit and pays no fees. Buyers can see how much the creator bought through the `OwnerBuy` event.
- None of this has been audited. Get a review before deploying to mainnet.
