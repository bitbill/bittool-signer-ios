# Offline token registry: sources, selection and verification

Registry `2026-09-22.1` contains **3,350** exact token identities with bundled icons. It has two layers:

- **596 curated identities** (revision 3, verified 2026-09-22 against a 2026-09-21 market snapshot), each picked and re-checked by hand against several independent sources.
- **2,754 identities from the CoinMarketCap top-2000 listing** (revision 4, 2026-09-23). CoinMarketCap decides only *which* tokens are worth bundling and supplies the name, symbol and artwork; every one of them has its decimals — and, where the contract answers, its symbol — read from the chain itself.

| Network | Included | Curated | From the CMC listing |
| --- | ---: | ---: | ---: |
| Ethereum (chain ID 1) | 1,008 | 196 | 812 |
| BNB Smart Chain (56) | 876 | 112 | 764 |
| Solana | 585 | 121 | 464 |
| Base (8453) | 333 | 86 | 247 |
| Arbitrum One (42161) | 225 | 67 | 158 |
| Polygon PoS (137) | 137 | 0 | 137 |
| Avalanche C-Chain (43114) | 75 | 0 | 75 |
| OP Mainnet (10) | 53 | 0 | 53 |
| Gnosis (100) | 32 | 0 | 32 |
| TRON | 26 | 14 | 12 |

The four EVM networks the app pairs wallets for keep their curated core; the other reviewed EVM networks (Polygon, Avalanche, OP Mainnet, Gnosis) are now recognised too, so an amount on them is shown in token units instead of raw units.

The two layers are held to different standards, and the app deliberately does not say which layer a token came from: a listed token is never an endorsement in either case, and the app's safety behaviour does not depend on the distinction. The provenance of every single entry is in `engine/data/token-registry.merged.json`.

It is a static display catalogue for an offline signer. It is **not** a live market ranking, safety allowlist, issuer certification or endorsement. A match only lets the app show a name, symbol, decimals and icon for an exact contract or mint; it says nothing about whether a transaction is safe.

## Files

| File | Purpose |
| --- | --- |
| `engine/data/token-source-selection.json` | Frozen curated selection: per network, in rank order, the exact address, curated name/symbol, expected decimals, CoinGecko id, icon source, the snapshot metrics that justified the choice, and an audit list of notable exclusions with reasons. |
| `scripts/build-token-registry.py` | Reproducible build of the curated layer (Python 3.9+, Pillow; build-time network only). Re-verifies every pinned token against the sources below, downloads and normalizes icons into `engine/data/curated-icons/`, and writes `engine/data/token-registry.json`. |
| `scripts/refresh-cmc-snapshot.py` | Refreshes the two CoinMarketCap inputs: the listing itself and the on-chain readings. Reads the API key from `CMC_API_KEY`; the key is never written into the repository. The on-chain stage is resumable and can be re-run until every contract has answered. |
| `engine/data/cmc-snapshot.json` | The listing as fetched (2026-09-23): 1,686 tokens with 3,250 contracts on supported chains, with rank, name, symbol and logo URL. No decimals. |
| `engine/data/cmc-onchain.json` | What the chains answered for those contracts (2026-09-23): 3,242 of 3,250 with decimals, plus the symbol where `symbol()` answered and, for Solana mints, the owning token program. |
| `scripts/build-expanded-registry.py` | Merges the two layers and writes everything the app ships. A curated record always wins; a listing record is only included when its decimals were read from the chain. |
| `engine/data/token-registry.merged.json` | The merged registry with full provenance per entry (2.4 MB, not shipped). |
| `BitToolSigner/Resources/token-registry.json` | The same records without build provenance, for Settings › Networks, Tokens & Contracts (869 KiB). A test requires it to be the exact projection of the merged file. |
| `engine/data/token-registry.engine.json` | Compact projection bundled into `signer.js` (313 KiB): the network and token-program strings are held once, and the rows are one tab/newline separated string that is split on first use. A fresh JavaScript VM — one per sensitive operation — therefore allocates a single string while evaluating the bundle, and only a request that involves a token pays to build the index. |
| `BitToolSigner/Resources/TokenIcons.pack`, `TokenIcons.index.json` | Every bundled icon, concatenated, and a map from icon id to `[offset, length]`. The id is the first 16 hex digits of the SHA-256 of the image bytes, so artwork shared by the same token on several chains is stored once. |
| `scripts/discover-token-candidates.py` | Build-time discovery for the curated layer: lists CoinGecko-mapped candidates per network with market data, on-chain supply, holders, listings and review flags, for human review. It never changes the selection. |

The network entries in the registry reference the app's own vector artwork (`ChainEthereum`, `ChainBNB`, `ChainArbitrum`, `ChainBase`, `ChainTron`, `ChainSolana`); this build does not generate network icons.

## How the curated layer was selected (snapshot 2026-09-21)

Targets are ceilings, not quotas: the brief was "as many as possible, but only mainstream-recognised tokens", so networks stop where the next candidates would be thin, flagged or copycat tokens.


1. **Candidates**: every CoinGecko coin whose platform map (`/coins/list?include_platform=true`) has an exact contract/mint on the network, with CoinGecko market data (`/coins/markets`). Presence in an "ecosystem" category alone was never used as evidence of a deployment.
2. **Per-network value**: `min(CoinGecko market cap, on-chain total supply × price)`, with on-chain supply read over public RPC. This keeps bridged copies of large assets (for example LINK on Solana or ARB on Ethereum) from inheriting the global market cap. Bridged tokens without a CoinGecko market cap (for example BTCB) use their on-chain value; Wrapped SOL uses its CoinGecko market cap because the native mint reports zero supply.
3. **Activity filters** (thresholds per network are recorded in the selection file): 24-hour volume, holder counts (Blockscout for Ethereum/Arbitrum/Base, GeckoTerminal for BNB Smart Chain, Jupiter for Solana, TronScan for TRON) and, on Solana, DEX liquidity.
4. **Independent listing**: besides CoinGecko, each address had to appear in at least one independent source — Trust Wallet assets (active record), Uniswap default list, 1inch lists, CoinMarketCap list, MyEtherWallet lists, PancakeSwap extended list, Arbitrum token lists, Superchain token list, Jupiter verified list, TronScan, or (Revision 3) the issuer's own documentation pinned as `officialSource`, whose raw page must contain the exact address.
5. **Rank** = order by per-network value among the tokens that passed. `rank` in the registry is that order.
6. **Review**: remaining candidates were reviewed by hand; removals and the reasons are in `exclusions` of the selection file.

### Revision 3 expansion (2026-09-22)

1. **Discovery** (`scripts/discover-token-candidates.py`) with relaxed thresholds: Ethereum value ≥ $5M, 24h volume ≥ $100k, ≥ 3,000 holders; BNB Smart Chain ≥ $3M, ≥ $100k, ≥ 5,000 holders and a Trust Wallet record or two lists with ≥ 20,000 holders; Arbitrum ≥ $1M, ≥ $50k, ≥ 1,000 holders; Base ≥ $2M, ≥ $100k, ≥ 5,000 holders; TRON ≥ $1M, ≥ 5,000 holders; Solana Jupiter-verified, ≥ 5,000 holders, ≥ $3M. Lower-volume variants apply to large values (see the script).
2. **Curation**, one reviewer per network: additions had to be mainstream-recognised — a real global market (tier-1 exchange listings or a top-ranked CoinGecko coin), a major stablecoin, liquid-staking or restaking token, or a canonical bridged blue chip — and not in an excluded category. Near-misses were admitted only for mainstream assets whose exact address is published by the issuer (`officialSource`) or covered by an active Trust Wallet record.
3. **Adversarial verification**: an independent reviewer re-checked every addition against primary sources (issuer docs, official bridge/token lists, CoinGecko platform maps, explorers) and dropped anything doubtful. 28 proposals were dropped; each is recorded in `exclusions` with the reason. Tokens previously excluded only by the old holder floor (kBTC, FDUSD on Ethereum; AKE and Q on BNB Smart Chain; and others) were re-admitted, and their old exclusion entries removed.
4. **Automated build verification** of all 596 tokens, as below, plus a visual review of every new icon on contact sheets. A CoinGecko image that turned out to be a "broken image" glyph is now rejected by hash (`PLACEHOLDER_ICONS`).

New entries carry `addedIn: "2026-09-22"` in the selection file.

### Revision 4 expansion (2026-09-23): the CoinMarketCap top 2000

The curated layer answers "which tokens did we verify by hand"; it left most of what people actually hold unrecognised, so amounts appeared as raw units. Revision 4 adds every token in the CoinMarketCap top-2000 listing that is deployed on a supported chain and whose decimals could be read from that chain.

1. **Listing** (`scripts/refresh-cmc-snapshot.py --stage snapshot`): `/v1/cryptocurrency/map` (rank order, limit 2000) for membership and rank, then `/v2/cryptocurrency/info` in batches of 100 for the name, symbol, logo and contract addresses. Only contracts on the ten supported networks are kept — 1,686 tokens with 3,250 contracts, since one token is often deployed on several chains. The API key is read from `CMC_API_KEY` and never stored.
2. **On-chain reading** (`--stage onchain`), the only source of decimals: EVM `decimals()` and `symbol()` batched over public JSON-RPC endpoints (bytes32 symbols handled), Solana `getMultipleAccounts` (`jsonParsed`) for mint decimals and the owning token program, TRON `decimals()` via TronGrid. 3,242 of 3,250 contracts answered; the 8 that did not are simply not in the registry. The stage is resumable and endpoints are listed per chain, because public endpoints rate-limit and occasionally refuse batches.
3. **Merge** (`scripts/build-expanded-registry.py`): a curated record always wins, so 486 listing contracts that were already curated changed nothing. A listing record without on-chain decimals is dropped (8), as is one whose name or symbol is unusable (2 — control characters; any script, including CJK, is fine).
4. **Symbols**: where the contract answered `symbol()`, the contract's answer is what the app shows (2,276 of 2,754). It differs from the listing for 235 records, of which 161 differ only in case or punctuation (`frxUSD`, `$MBG`, `tGBP`). The remaining 74 are mostly bridged or wrapped deployments where the listing's ticker would claim the asset is the original token: `LINK.e`, `UNI.e` and `DAI.e` on Avalanche, `wROSE`, `pONT`, `axlSAGA`, `WFLOW`, and pre-rename contracts such as `LUNA` for Terra Classic and `UST` for TerraClassicUSD. Names always come from the listing.
5. **Cross-check**: the 486 overlapping contracts are an independent test of the method — the decimals read for revision 4 agree with the curated values in every single case.

What this layer does **not** do: it is not hand-reviewed, and CoinMarketCap rank is not a safety signal. Tokenized stocks, vault receipts and similar categories that the curated layer deliberately excludes do appear here if they are in the top 2000. Recognition still only means the app can show a name, symbol, decimals and icon for an exact address; risk warnings, approval warnings and the rest of the review behave exactly as they do for any other token.

Symbols are not identities, and the registry does not pretend otherwise: 18 same-network symbol collisions exist (for example `ID` for both SPACE ID and Everest on Ethereum). Every lookup is by exact address, chain and — on Solana — token program.

### Excluded on purpose (curated layer)

- Tokenized stocks and ETFs (xStocks, bStocks, Ondo tokenized equities, rStocks), even when they rank highly (for example on Solana).
- Tokenized funds and permissioned securities: BUIDL, USYC, USDY, OUSG, USTB, JTRSY/JAAA, Spiko funds, Hastra, OnRe, stUSDT and similar.
- Receipt/vault/staking-position tokens: Aave aTokens and static wrappers, Maple syrup vaults, Morpho vaults, Lido Earn, ether.fi Liquid, sENA, stkAAVE, Venus vTokens, Jupiter Lend receipts. Liquid-staking tokens (stETH, wstETH, rETH, weETH, mSOL, JitoSOL, …) and the main savings stablecoins (sUSDS, sUSDe) are kept.
- Superseded or deprecated contracts: MKR (being upgraded to SKY; SKY is included), legacy FRAX (superseded by frxUSD), BUSD, Sollet-bridged Solana assets (for example soETH), CoinGecko "[OLD]" mints, discontinued TRON contracts (USDC on TRON, USDDOLD, SUNOLD, BUSDOLD).
  The legacy ERC-20 RNDR is kept (labelled "Render Token (ERC-20)") because about $0.9B of supply and ~94k holders remain on Ethereum.
- Sanctioned assets (A7A5).
- On BNB Smart Chain, recent launches without an active Trust Wallet record were admitted only with two independent lists and at least 20,000 holders (this excluded, for example, BTW, M, AKE, 币安人生, UB, B, PIEVERSE, DGAI and Q).
- Tokens whose supply sits almost entirely with an issuer or exchange and that have negligible holder bases on that network (for example WBT and United Stables on TRON, BTW and WBT on Ethereum), and institutional products with no trading activity (LsETH, USD0 at snapshot time).
- Tokens whose metadata sources disagree (see below).

### Sources that disagreed (curated layer)

- **Base `0x8bfac1b3…6789`**: Trust Wallet's record names it "GAME by Virtuals" while the contract and CoinGecko say Mey Network (MEY). Excluded.
- **BNB Smart Chain `0x6bf62ca9…7a510`**: CoinGecko lists "ONEchain (ONE)" while the contract reports symbol CROSS. Excluded.
- **United Stables on TRON**: CoinGecko's token list reports 17 decimals; on-chain and Trust Wallet report 18. It was already excluded for its tiny holder base.
- **CoinMarketCap token list decimals**: it lists 18 decimals for USDT, USDC, WBTC, CRO, PYUSD, LBTC, SPX and USDG on Ethereum, contradicting on-chain values, Trust Wallet and every other list. That list is therefore used only to confirm addresses; on-chain decimals are authoritative and the disagreement is kept in each entry's `verification.decimalsDisagreement`.
- Accepted symbol differences, each recorded as `verification.note` and required by the build script: Arbitrum USDT0 (on-chain `USD₮0`, Trust Wallet still `USDT`), Arbitrum USDC.e (on-chain `USDC`), BNB Smart Chain BANANAS31 (on-chain `$BANANA`), TRON TUSD (Trust Wallet symbol field `TrueUSD`), Solana RENDER (Trust Wallet `RNDR`), Solana Wormhole WETH (Trust Wallet `ETH`), Solana WSOL (Metaplex symbol `SOL`).

Apart from the CoinMarketCap list values above, no source disagreed on decimals for any included token.

## What the build verifies

### For every curated token

`scripts/build-token-registry.py` aborts on any failure:

- **CoinGecko**: the pinned coin id maps to exactly this address on the network; decimals agree with the CoinGecko token list for the platform.
- **Trust Wallet** (commit `94fd9ac04a4dd53b8fd5a27267564f5694269669`): when an `info.json` exists it must be `active` with the same decimals. Records without one use the CoinGecko coin record (`/coins/<id>`) as `metadataSource`, whose per-platform address and decimals must agree.
- **Independent lists**: any list that carries decimals must agree (the CoinMarketCap list is presence-only, see above); at least one source other than CoinGecko must list the address.
- **On-chain** (source of truth for decimals): EVM `decimals()` and `symbol()` (bytes32 symbols handled) over public JSON-RPC; TRON `decimals()`/`symbol()` via TronGrid `triggerconstantcontract`; Solana `getMultipleAccounts` (`jsonParsed`) for mint decimals and the owning token program, plus the Metaplex metadata account or Token-2022 metadata extension for the symbol.
- **Symbols**: a displayed symbol that differs from the on-chain symbol, or a Trust Wallet symbol that differs from the on-chain one, fails unless the selection records an explanation.
- **Icons**: decoded with Pillow; rejected if smaller than 64 px, fully transparent, a flat single-colour rectangle, or a known placeholder URL.

### For every token, curated or listed

`scripts/build-expanded-registry.py` aborts unless: decimals are an integer between 0 and 30 and came from the chain; no two records share a chain, address (lowercased for EVM) and token program; every record points at artwork that exists; and every name and symbol is free of control characters and within length.

Each merged entry records `metadataSource`, `iconSource`, `iconSha256`, `verifiedAt`, `rank` and `verification` — for the curated layer `{"coingeckoId", "coingecko", "trustwallet", "tokenLists", "onchainDecimals", "onchainSymbol"}`, for the listing layer `{"coinmarketcapRank", "onchainDecimals", "symbolSource", "onchainSymbol", "coinmarketcapSymbol"}`. Solana entries also carry `tokenProgram` (`Tokenkeg…` or `Tokenz…`), which the engine checks against the program in the instruction.

`engine/test/chain-expansion.test.mjs` re-checks the shipped files on every run: both copies are exact projections of the merged registry, every address has the right shape for its chain, every identity is unique, the icon pack has no gaps or overlaps and every icon's bytes hash to the id the registry uses, and every Solana mint is bound to its token program.

## Icons

For the curated layer, Trust Wallet `logo.png` at the pinned commit is preferred. CoinGecko's large image is used when no Trust Wallet record exists, and for five tokens whose Trust Wallet logo was outdated or duplicated a sibling token's logo after visual review (weETH and USDtb on Ethereum, NPC, rsETH on Arbitrum, mSOL) — 182 icons in total, against 413 from Trust Wallet. TRC-20 ETH uses TronScan's token logo because CoinGecko maps it to the WETH artwork. Every icon is decoded, converted to RGBA, fitted without distortion into a transparent 128 × 128 canvas and saved as an optimized PNG; fully transparent pixels are zeroed so output is small and deterministic. The 596 curated icons were reviewed on contact sheets and are kept in `engine/data/curated-icons/`, outside the app.

Listing icons are CoinMarketCap's 64 × 64 logos, downscaled if larger than 128 px.

Both sets are shipped as one file. Each image is stored under the first 16 hex digits of the SHA-256 of its bytes, so the same artwork used by a token on several chains — USDT on Ethereum and on TRON, for example — is stored once: 3,350 records resolve to **1,985 images, 10.7 MiB**. They are concatenated into `TokenIcons.pack` with an index of `[offset, length]`; the app memory-maps the file and decodes only the images it draws. Two thousand loose PNGs would each round up to a filesystem block on the device and cost about 4 MB more.

Logos remain the trademarks of their owners and are used only to identify assets. The app shows a lettered placeholder for unknown tokens and never downloads icons.

## Limitations

- Popularity reflects one snapshot (curated layer 2026-09-21, listing 2026-09-23). Market data, holder counts, liquidity and rankings change; rebuild and review before each release.
- The listing layer is only as good as the listing: CoinMarketCap decides membership, and a token that is delisted, renamed or re-deployed keeps its bundled entry until the next refresh. Its names and symbols are not hand-reviewed, and its decimals — the values that actually move a decimal point in the amounts people approve — are the only part read from the chain.
- Holder counts come from third-party indexers and include dust and airdrop addresses. GeckoTerminal rate limits left some BNB Smart Chain candidates without a count during screening; such candidates could qualify only through an active Trust Wallet record (counts were fetched afterwards for all 50 selected tokens and are stored in the selection snapshot). Blockscout returned no count for rsETH (Ethereum, Arbitrum) and weETH (Arbitrum).
- On Solana no Metaplex metadata account exists for bSOL, NOS and GMT, so their symbols are not confirmed on-chain (decimals and token program are).
- Bridged representations (Binance-Peg assets, Wormhole assets, canonical-bridge tokens on Arbitrum/Base, TRC-20 BTC/ETH) depend on their bridges or custodians; the registry identifies them but says nothing about their backing.
- Upgradeable contracts can change behaviour or metadata after this snapshot. The engine binds display data to the exact address and the bundled decimals and flags decimal conflicts in Solana checked instructions; it cannot detect later on-chain changes offline.
- Inclusion is not an endorsement, investment signal or safety assessment.
