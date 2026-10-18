# Known public contracts: source, meaning and use

The app bundles **1,720 contract addresses** that the projects behind them published themselves. When a signing request hands assets or authority to one of these addresses, the review names it. When it hands them to an address that is not in the list, the review says that too.

A listing identifies a deployment. It is **not** an endorsement, a safety check or a judgement about the request being reviewed. A request to a listed contract can still drain an account: the contract is known, the call is not. The notice exists so a person can tell "this is the Permit2 everyone uses" from "this is an address I have never seen", which is the difference an imitation contract depends on.

Everything is matched offline against the bundled file. Nothing is fetched, at review time or ever.

## What is in it

| Network | Contracts |
| --- | ---: |
| Ethereum (chain ID 1) | 329 |
| Base (8453) | 217 |
| BNB Smart Chain (56) | 194 |
| Polygon PoS (137) | 191 |
| Arbitrum One (42161) | 186 |
| OP Mainnet (10) | 169 |
| Solana | 262 |
| TRON | 139 |
| Every EVM network (deterministic CREATE2 deployments) | 27 |
| Avalanche C-Chain (43114) | 6 |

307 projects. By category: token 329, dex 316, bridge 308, lending 215, aggregator 186, staking 110, infra 83, nft 67, other 42, perp 35, wallet 29.

The 27 `evm:*` entries are CREATE2 deployments that live at the same address on every EVM network — Permit2, the Seaport versions, the ERC-4337 EntryPoints, Multicall3, the Safe singletons and handlers. They are looked up as a fallback after the chain-specific table, and the review says "same address on every EVM network" so the match is not mistaken for a per-chain listing.

HyperEVM (chain 999, 132 entries in the source) is dropped: the app does not review that network, so the entries would never be reachable.

## Source

Imported from the Ownbit security centre's known-contract library (`wallet-ios-core/scripts/security-center/known_contracts.json`), the list Ownbit uses for the same purpose in its own WalletConnect review. Imported revision: **1, dated 2026-10-09**.

Ownbit assembles it from the projects' own documentation and deployment registries, and treats a wrong inclusion as worse than an omission: an address that cannot be traced to the project that published it is left out rather than guessed at. This app inherits that standard unchanged — it adds no addresses of its own and relaxes nothing.

## Files

| File | Purpose |
| --- | --- |
| `engine/data/known-contracts.json` | The imported library with its source metadata (338 KiB, not shipped). The input to the build. |
| `scripts/build-known-contracts.py` | Validates and writes both shipped projections. Pure local transformation: no network, no API key. |
| `engine/data/known-contracts.engine.json` | Compact projection bundled into `signer.js` (139 KiB). Network and category strings are held once; the rows are a single tab/newline separated string. A fresh JavaScript VM — one per sensitive operation — allocates one string while evaluating the bundle, and only a request that touches a contract pays to build the index. |
| `BitToolSigner/Resources/known-contracts.json` | The same records for Settings › Networks, Tokens & Contracts (277 KiB), read on the main actor's behalf off the main thread when that screen opens. |
| `engine/src/known-contracts.js` | `lookupContract(chainFamily, chainId, address)` and `describeContract(...)`. EVM addresses compare lowercased; TRON and Solana keep their case. |

`scripts/build-known-contracts.py` refuses to write anything if a record is incomplete, an address has the wrong shape for its chain family, a category is not one of the eleven declared, or a (chain, address) pair appears twice. `BitToolSignerTests/KnownContractTests.swift` re-checks the shipped file on every test run, including that the declared per-chain counts are exactly what the file contains and that no chain is listed that the Settings browser has no row for.

## How a review uses it

`counterpartyNotice` in `engine/src/evm.js` (and the equivalent in `engine/src/tron.js`) looks up **the address the request authorizes**, which is not always the address it calls:

| Request | Looked up | Role |
| --- | --- | --- |
| `approve(spender, …)`, `increaseAllowance` | the spender | `spender` |
| `setApprovalForAll(operator, true)` | the operator | `operator` |
| EIP-712 message naming a `spender` or `operator` | that address | `spender` |
| Any other contract call | the contract being called | `contract` |
| EIP-712 message without one | `domain.verifyingContract` | `contract` |

A `SafeTx` verifying contract is skipped entirely: every Safe is deployed by its own users, so "this Safe is not in the list" is noise on every Safe transaction.

Solana is different: a transaction is a list of instructions with no single counterparty, so there is no `review.contract`. Instead each instruction addressed to a program `engine/src/solana.js` does **not** decode itself gains a `Program (known)` field when the library lists it — "Raydium AMM v4 — Raydium · dex" next to an instruction that is otherwise opaque bytes. The programs the file decodes (System, Token, Token-2022, ATA, Compute Budget, Memo, Stake, Squads, and the Metaplex and marketplace programs) keep their own names, which say more than a library label would. An unlisted Solana program adds no warning of its own: whether the instruction was decoded already carries that signal, and every undecoded instruction is already high risk.

On a **hit**, the review gains a field (`Spender (known contract)` / `Operator (known contract)` / `Contract (known)`) and `review.contract` carries `{address, role, known: true, name, protocol, category, everyChain}`.

On a **miss**, the engine first asks the token registry: an address that is a known token is named as that token rather than called unknown, since the registry already identified it. Otherwise it pushes a warning, and — only when the unlisted address is a **spender or operator** — raises the risk level to `warning`. An unlisted plain contract is left at its own risk level: most contracts are new or private deployments, and colouring every one of them as a risk would make the signal worthless.

## How the app shows it

`ReviewContract` in `BitToolSigner/Models/Models.swift` decodes `review.contract`. "Known" without a name is not treated as a hit: the point of the notice is a name a person can compare against the project's own documentation.

`ContractNotice` in `RequestReviewView.swift` renders it. When the summary card already shows that address as the counterparty — an approval, where spender and counterparty are the same — the notice is one line under the address. When they differ — a token transfer authorizes the token contract, not the recipient — it is a card of its own below the summary.

Four states, coloured to match what the engine actually did:

| State | Colour | Wording |
| --- | --- | --- |
| Listed | amber, `checkmark.seal.fill` | "Known public contract (spender)" + `Permit2 — Uniswap · infra` |
| Unlisted spender or operator | red, triangle | "Spender is not a known contract" |
| Unlisted plain contract | grey, question mark | "Contract is not in the known list" |
| Registry token | accent, info | "Recognized token contract" + `Tether USD (USDT)` |

A hit is amber, never green: a green check next to an address being granted an unlimited allowance would say something the list cannot support.

Settings › **Networks, Tokens & Contracts** browses the whole library. Each network page offers its tokens and its contracts behind one segmented control and one search field (name, project, category or address); a network with only one of the two shows no picker. The deterministic deployments get their own "All EVM networks" row.

## Updating

1. Copy the newer `known_contracts.json` from Ownbit over `engine/data/known-contracts.json`, keeping `sourceVersion` and `updated` current.
2. `python3 scripts/build-known-contracts.py` — it validates and rewrites both projections.
3. `cd engine && npm run build && npm test` — rebuilds `signer.js` with the new table.
4. Run `BitToolSignerTests/KnownContractTests.swift`; the count and reachability tests fail if a chain appeared that the browser cannot show.
