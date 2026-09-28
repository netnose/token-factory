# token-factory

A token factory for Base. It launches fixed-supply ERC20s straight into a Uniswap v4 pool whose hook charges trading fees in ETH, and it creates ERC721 and ERC1155 collections with paid public mints. It targets Base Sepolia first.

| Contract | What it does |
| --- | --- |
| `src/TokenFactory.sol` | Deploys all three token types as cheap EIP-1167 clones at predictable addresses. Launches each ERC20 into its own v4 pool. Holds the platform settings and platform revenue. |
| `src/EthFeeHook.sol` | Uniswap v4 hook, shared by every launch pool. Charges the creator fee (0–5%) plus a decaying sniper fee, always in ETH. Only the factory can create pools with it or add liquidity to them. |
| `src/tokens/FactoryERC20.sol` | Fixed-supply ERC20 with EIP-2612 permit and EIP-7572 `contractURI`. No owner and no minting after launch. |
| `src/tokens/FactoryERC721.sol` | ERC721 collection: free owner mint, paid public mint, ERC-2981 royalties, EIP-4906 and EIP-7572. |
| `src/tokens/FactoryERC1155.sol` | ERC1155 collection: free owner mint, paid public mint and metadata URI per token id, ERC-2981 royalties, EIP-4906 events and EIP-7572. |
| `src/tokens/MintRevenue.sol` | Shared NFT logic: sends the platform's cut of each mint to the factory, handles owner withdrawals, royalties and `contractURI`. |
| `src/interfaces/IERC7572.sol` | The EIP-7572 `contractURI()` interface. |
| `script/Deploy.s.sol` | Deploys the factory and the hook, mining the hook's CREATE2 address, and wires them together. |
| `script/CreateToken.s.sol` | Launches an ERC20 through a deployed factory. |

## Launching an ERC20

`createERC20(ERC20Params)` is payable. Its parameters are:

| Field | Meaning |
| --- | --- |
| `name`, `symbol` | Token name and symbol. |
| `totalSupply` | Supply in wei (18 decimals), at most `type(int128).max`. All of it goes into the pool. |
| `feeBps` | Creator fee, at most 500 (5%). It can only be lowered later. |
| `marketCapEth` | Starting fully diluted market cap in wei of ETH, e.g. `10 ether`. |
| `contractURI` | EIP-7572 token metadata (description, logo, links). **Permanent**, because the token has no owner. |
| `salt` | Picks the token's address. It's combined with the caller's address, so nobody can take a predicted address first. `predictAddress` shows the result. |

It does all of the following in one transaction:

1. It deploys the token clone and mints the **entire supply to the factory**. Nothing can be minted after that.
2. It registers the pool with the hook:
   - The creator becomes the pool owner, with `feeBps` as the creator fee.
   - The current platform share and sniper settings are copied into the pool's config.
3. It creates a **native ETH / TOKEN** v4 pool at the chosen market cap:
   - The price is `totalSupply / marketCapEth` tokens per ETH, rounded to the nearest tick. That rounding changes the market cap by at most 0.3%.
   - `factory.startTickFor(supply, marketCap)` shows the exact starting tick.
   - ETH is always `currency0`. The pool has an LP fee of 0, `tickSpacing` 60, and uses the `EthFeeHook`.
4. It adds the whole supply as **one-sided liquidity** from the starting price upward. Buying moves the price up along that curve, and sellers can swap back down.
5. **Owner buy:** any ETH sent with the call is swapped for the creator right away.
   - It pays **no fees at all**: no creator fee, no sniper fee, no platform share. The hook skips fees for swaps made by the factory, and the factory only swaps during creation.
   - It's **capped at 10% of the supply**. The swap gets a price limit at exactly the point where 10% has been bought, so it stops there on its own. Any ETH it didn't need is refunded.
   - The tokens go to the caller, and the buy emits an `OwnerBuy` event. If the supply is so small that 10% of it rounds to nothing, the buy is skipped and the ETH refunded.
6. The factory owns the position and has no function to remove it, so the **liquidity is locked forever**.
7. **Nobody else can add liquidity.** Each pool holds exactly one position, the locked launch liquidity, so the price for any trade size follows exactly from the supply and starting market cap. It also protects users: the pool's LP fee is 0, so an outsider who added liquidity would earn nothing while arbitrage traded against them.

A launch that can't work reverts with one of these errors from the factory or the hook, never an overflow deep inside Uniswap. A fuzz test covers every supply, market cap and owner-buy combination.

| Error | Cause |
| --- | --- |
| `InvalidSupply` | The supply is 0, above `int128.max`, or so small it rounds to no liquidity. |
| `InvalidMarketCap` | The market cap is 0, or the resulting price is outside Uniswap's range. |
| `SupplyTooLargeForPrice` | The liquidity would exceed Uniswap's per-tick limit. This needs supply × market cap above about 10⁶⁸ in wei units. |
| `FeeTooHigh` (from the hook) | `feeBps` is above 500. |

## Swap fees (always in ETH)

The fee is always taken on the ETH side of the swap: ETH in on buys, ETH out on sells.

```
fee = creator fee (0–5%, can only be lowered)   -> creator, minus the platform share (max 10%)
    + sniper fee  (decays to 0 after launch)    -> platform
```

### Sniper protection

At launch the total fee is `startFeeBps`, which defaults to **80%**. It decays exponentially and reaches the creator fee after `duration` seconds (default **15 s**):

```
sniper(t) = (start − base) · (2^(−k·t/T) − 2^(−k)) / (1 − 2^(−k))       k = halvings (default 5), T = duration
```

2^−x is computed exactly at whole halvings and in straight lines between them. With a 5% creator fee, the total fee over time is:

| Seconds after launch | 0 | 2 | 4 | 6 | 8 | 10 | 12 | 15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Total fee | 80% | 54.2% | 34.8% | 21.9% | 15.5% | 10.6% | 7.4% | 5% |

- The sniper fee applies to buys and sells alike, and all of it goes to the platform.
- The factory owner sets the curve with `setSniperConfig`: `startFeeBps` up to 90%, `duration` up to 10 minutes, `halvings` up to 32. Setting `startFeeBps` to 0 turns it off. Changes apply only to launches from then on.
- `hook.currentFee(poolId)` returns the fee right now.

### Where the fee is taken

| Swap | Taken in | Effect |
| --- | --- | --- |
| Buy, exact ETH in | `beforeSwap` | You pay exactly X ETH, and X − fee is swapped. |
| Buy, exact tokens out | `afterSwap` | You pay the swap cost + fee. |
| Sell, exact tokens in | `afterSwap` | You receive the swap output − fee. |
| Sell, exact ETH out | `beforeSwap` | You receive exactly X ETH, and the swap sells enough tokens to cover X + fee. |

When ETH is the fixed amount (the first and last rows), the swap must fill completely, or it reverts with `PartialFill`. Otherwise the fee, which is set before the swap runs, would include ETH that never got swapped.

### Pool owner and payouts

- `lowerFee(poolId, bps)` lowers the creator fee; it can never be raised. `transferPoolOwnership(poolId, to)` sends future fees to a new owner.
- Each fee is split at swap time, as ERC-6909 ETH claims on the PoolManager:
  - **Creator's part:** held by the hook. It's paid out with `claim()`, or with `claimTo(to)` to send it to another address (useful for an owner contract that can't receive ETH). Anyone can call `claimFor(owner)` to push the owner's balance to the owner.
  - **Platform's part:** credited straight to the factory during the swap.
- No ETH moves during a swap, so a recipient that rejects ETH can never block trading. (ETH can't be sent mid-swap anyway: the PoolManager may not hold it yet.)

## NFT collections

### Creating a collection

| | `createERC721(ERC721Params)` | `createERC1155(ERC1155Params)` |
| --- | --- | --- |
| Names | `name`, `symbol` | `name`, `symbol` (for wallets and marketplaces) |
| Token metadata | `baseURI`: each token's metadata is at `baseURI + tokenId`, with ids starting at 1 | `uri`: the base URI, which may contain `{id}`; ids can get their own URI later |
| Collection metadata | `contractURI` (EIP-7572) | `contractURI` (EIP-7572) |
| Public sale | `sale`: `price`, `maxSupply`, `maxPerWallet`, `active` | Configured per id after creation |
| Royalty | `royalty`: `receiver` (defaults to the creator), `bps` (max 10%) | Same |
| Address | `salt`, combined with the caller's address | Same |

The caller becomes the collection's owner. The platform's share of mint revenue (at most 10%) is copied in at creation.

### Minting

Both collections keep a free owner mint (`mint`, `mintBatch`). On top of that, **anyone** can call `publicMint` and pay the owner-set price.

| | ERC721 | ERC1155 |
| --- | --- | --- |
| Call | `publicMint(quantity)` | `publicMint(id, quantity)` |
| Price (0 = free) | One price for the collection, set at creation or with `setSale`. | A price per token id, set with `setSale(id, …)`. |
| Sale on/off | `setSale(…, active)` | Per id. Every id starts closed. |
| Max supply (0 = unlimited) | Covers owner and public mints. Once set, it can only be lowered, and never below what's already minted. | The same rules, per id: `setMaxSupply(id, …)`. |
| Per-wallet limit (0 = unlimited) | Counts public mints only. | Per id. |

- Payment must be exact.
- The platform's share is **sent to the factory as part of each mint**. The owner collects the rest with `withdraw()`.

**ERC1155 metadata:** `setTokenURI(id, uri)` gives a token id its own URI. Ids without one use the base URI (`setURI`). Setting an empty string reverts the id to the base URI.

### Metadata standards

**EIP-7572, contract-level metadata:** all three token types have `contractURI()`. It returns a JSON document with the name, description, image, banner and links that marketplaces and wallets show on collection and token pages, and `ContractURIUpdated()` is emitted whenever it's set.
- **NFT collections:** set at creation. The owner can change it with `setContractURI`.
- **ERC20s:** set at creation and permanent. If the metadata needs to change later, point it at mutable storage such as IPNS.

**EIP-4906, metadata refresh events:** these tell marketplaces to re-fetch token metadata.
- **ERC721:** fully supported. `supportsInterface(0x49064906)` returns true, and `setBaseURI` emits `BatchMetadataUpdate(0, type(uint256).max)`, which refreshes every token.
- **ERC1155:** emits the same events alongside the standard `URI` event: `BatchMetadataUpdate` from `setURI`, and `MetadataUpdate(id)` from `setTokenURI`. EIP-4906 is defined for ERC721, so the ERC1155 doesn't claim its interface ID, but marketplaces watch these events on ERC1155 contracts too.

**Royalties (ERC-2981):** capped at 10% on both collection types.
- The owner can change the royalty with `setDefaultRoyalty(receiver, bps)`, or override it for a single token id with `setTokenRoyalty(id, receiver, bps)`.
- Setting `bps` to 0 removes the royalty, or resets that token to the default.

## Platform admin (factory owner)

| Function | What it does |
| --- | --- |
| `setHook(hook)` | One-time wiring of the fee hook. The deploy script calls it. |
| `setProtocolShare(bps)` | The platform's share, at most **10%**, of creator swap fees and NFT mint revenue. Copied into each token at creation, so changes never affect existing tokens. |
| `setSniperConfig(config)` | Sniper protection for launches from then on. |
| `withdraw(to)` | Sends **all platform revenue in one call**: swap-fee claims (the platform share plus all sniper fees) and ETH from NFT mints. |

There is no creation fee.

### Why there is one shared hook

A v4 hook's permissions live in the low 14 bits of its address, so every hook needs a mined CREATE2 salt. A separate hook per token would mean mining an address for every launch, and a new entry on Uniswap's routing allowlist each time. Instead, one `EthFeeHook` keeps a separate fee config for each pool.

The hook uses six permissions: `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`. So its address always ends in the flag bits `0x28CC`.

The source of `src/EthFeeHook.sol` explains the hook in detail: the Uniswap v4 concepts it relies on, where each fee is taken and why, the sniper curve, and how the ETH is accounted for.

## Setup

You need [Foundry](https://getfoundry.sh). The dependencies (Uniswap v4, OpenZeppelin, forge-std) are git submodules:

```bash
git clone --recurse-submodules https://github.com/netnose/token-factory
# or, in an existing clone:
git submodule update --init --recursive

forge build
forge test
```

## Deploy (Base Sepolia)

```bash
cp .env.example .env    # fill in ETHERSCAN_API_KEY
source .env
forge script script/Deploy.s.sol --rpc-url base_sepolia --account <keystore> --broadcast --verify
```

| Deploy variable | Default | Meaning |
| --- | --- | --- |
| `POOL_MANAGER` | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | Uniswap v4 PoolManager. The default is the Base Sepolia deployment. |
| `PROTOCOL_SHARE_BPS` | `0` | Platform share, at most 1000. |
| `FACTORY_OWNER` | the deployer | Final factory owner. Use a multisig for mainnet. |
| `ETHERSCAN_API_KEY` | — | For `--verify`. A single Etherscan API V2 key covers Base and Base Sepolia. |

The script mines the hook's salt against the standard CREATE2 deployer, deploys the factory and the hook, and wires them together with `setHook`.

Launch a token:

```bash
FACTORY=<factory> NAME="My Token" SYMBOL=MYT FEE_BPS=300 MARKET_CAP=10000000000000000000 \
  OWNER_BUY=100000000000000000 CONTRACT_URI=ipfs://... \
  forge script script/CreateToken.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
```

| Launch variable | Default | Meaning |
| --- | --- | --- |
| `FACTORY` | required | Factory address. |
| `NAME`, `SYMBOL` | `Test Token`, `TEST` | |
| `SUPPLY` | `1000000000` | Supply in whole tokens (× 1e18). |
| `FEE_BPS` | `500` | Creator fee. |
| `MARKET_CAP` | `10 ether` | Starting market cap, in wei. |
| `OWNER_BUY` | `0` | ETH, in wei, for the fee-free launch buy (capped at 10% of the supply). |
| `CONTRACT_URI` | empty | Permanent token metadata URI. |
| `SALT` | `0x0` | Address salt. |

## Testing

```bash
forge test                      # unit + fuzz + invariant tests
FOUNDRY_PROFILE=ci forge test   # what CI runs: 10k fuzz runs, 256 x 128 invariant runs
```

GitHub Actions runs a format check, the build and the CI profile on every push and pull request (`.github/workflows/test.yml`).

**Invariant tests** (`test/invariant/`) run random sequences of launches (with random owner buys), all four swap kinds, time jumps across the sniper window, claims, platform withdrawals, fee cuts and ownership transfers. After each call, the handler checks that the charged fee matches the formula exactly. After each sequence, the suite checks that:

- **Fees:**
  - every fee wei is accounted for: charged = held by owners + held by the platform + paid out;
  - the hook's ETH claims exactly equal what it owes pool owners;
  - the PoolManager holds the ETH behind every claim;
  - a pool's fee never rises above its launch value, and the total fee never exceeds 90%.
- **Tokens:**
  - supply is fixed and every token is accounted for;
  - the locked liquidity never moves;
  - the owner buy never exceeds 10% of the supply and never pays a fee.
- **NFTs:**
  - every wei paid for a mint is either in the collection, withdrawn by the owner, or the platform's exact share;
  - supply caps hold, and balances match minted counts.

`createERC20` and `withdraw` use a reentrancy lock (transient storage). NFT mints record the new supply before any ETH moves.

## Known trade-offs

- **All-or-nothing when ETH is fixed:** buying with exactly X ETH, or selling for exactly X ETH, must fill completely, or the swap reverts with `PartialFill`.
  - Uniswap's own router already treats exact-output swaps this way and never sets a price limit, so normal trades never hit it.
  - Anyone who wants a partial fill can fix the token amount instead of the ETH amount.
- **Empty price region:** the pool has no liquidity below the token's launch price. A sell that pushes the price there moves it for free and fills nothing, which is standard Uniswap v4 behavior. The next buy moves back through the empty region at no cost, so buyers aren't harmed.
- **Fee avoidance:** anyone can create a separate pool for the same token without our hook and trade there fee-free. Every fee-by-hook design has this weakness, Clanker's included; only a transfer tax built into the token is enforced everywhere. In practice, the locked supply keeps nearly all liquidity in the launch pool.
- **Uniswap routing:** Uniswap's app routes trades only through allowlisted hooks, and its routing has no allowlisted hooks at all on Base Sepolia. Until our hook is allowlisted after the mainnet deploy, trading needs our own frontend or an aggregator that supports it.
- **Sniper timing:** the sniper fee is based on timestamps. On Base (2 s blocks), the window is about 7–8 blocks.
- **Owner buy:** it pays no fees and can take up to 10% of the supply. Buyers can see how much the creator bought through the `OwnerBuy` event.
- **ERC20 metadata:** `contractURI` is permanent, because the token has no owner.
- **NFT limits:** per-wallet mint limits can be dodged by using several wallets. The default royalty receiver is set at creation and doesn't follow ownership transfers.
- **Not audited:** get an independent audit before deploying to mainnet.
