# BitTool Signer offline engine · 1.0.0

This directory builds the JavaScriptCore resource used by Swift. It derives public indexes, validates public QR protocols, resolves fixed signing tasks, reviews original transaction/message bytes, and signs only the task authorized by the host. Runtime operations have no RPC, HTTP, balance lookup, remote ABI/token lookup, telemetry or broadcasting. Token display metadata is bundled locally.

Protocol tests and independent cryptographic checks do not certify any named wallet application's camera workflow. See [Compatibility.md](../docs/Compatibility.md) and the root implementation status for remaining release qualification.

## Build and test

```sh
cd engine
npm ci --ignore-scripts
npm run build
npm test
```

Use Node 20.19+. Dependencies are exact-pinned. Package downloads happen on the development machine; iOS ships `BitToolSigner/Resources/signer.js`. `bundle-manifest.json` records its SHA-256 and source modules. Keystone registry packages are development-only interoperability references, not runtime signing implementations.

### How the iOS host runs the engine

- **Allowlist.** Release builds accept only `mnemonic`, `capabilities`, `derivePublicIndex`, `derivePublicAddresses`, `createPublicPairing`, `createWalletPairing`, `decodeQR`, `decodePayload`, `review`, `resolveSigningPlan`, `signPlanTask` and `encodeResponse`, plus `scanBegin`/`scanAdd` through a scan session. `encodeQR`, `deriveAccounts`, `deriveBitcoinCosigner`, `sign`, `createPairing`, `validateMnemonic` and `wordlist` are available to DEBUG test builds only. The host never calls `validateBitcoinPolicy`.
- **Recovery phrases.** The host validates phrases natively in all ten official BIP39 languages (the engine's `validateMnemonic`/`wordlist` are English-only test utilities) and derives the seed natively, so the engine never needs a phrase in production. New phrases are still generated here, in English.
- **Contexts.** Every operation that receives a secret or untrusted input runs in a fresh JavaScriptCore context. Only `derivePublicAddresses`, `createPublicPairing` and `createWalletPairing`, which read the device's own authenticated public index, reuse one warm context; it never sees secrets and is dropped in the background. An animated QR scan gets its own context for incremental collection, discarded when the scan ends.
- **Seed.** The host derives the BIP39 seed natively (CommonCrypto PBKDF2-HMAC-SHA512, 2,048 rounds, NFKD) and passes `seed` (128 hex characters) instead of the phrase. Interpreted JavaScript PBKDF2 takes about 0.6 s on iOS, where JavaScriptCore runs without a JIT. Every signing path still re-derives the keys and checks them against the fixed plan.

## JSON dispatch

```js
const response = JSON.parse(BitToolSignerEngine.dispatch(JSON.stringify({
  operation: 'resolveSigningPlan', request, wallets
})));
// {ok:true,result} or {ok:false,error:{code,message}}
```

Calls are synchronous. Inputs/results are JSON, with a 1 MiB dispatch limit. Large integer amounts use strings; duplicate JSON keys, unsafe numeric integers and excessive nesting are rejected. Only controlled `EngineError`/`ProtocolError` messages cross the native boundary. Unexpected library exceptions become a generic error without input text or a stack.

| Operation | Inputs | Result |
|---|---|---|
| `mnemonic` | `entropy`: 16/20/24/28/32-byte hex supplied by native CSPRNG | `{mnemonic,wordCount}` |
| `validateMnemonic` / `wordlist` | mnemonic / none | Existing English BIP39 validation and word list |
| `derivePublicIndex` | `seed` (64-byte hex) or `mnemonic,passphrase?` | Version 1 public index described below; alias `deriveWalletPublic` |
| `derivePublicAddresses` | `publicIndex,chain,profile?,start=0,count=20` | `{addresses,hasMore,nextIndex?}` |
| `createPublicPairing` | `publicIndex,chain,profile?,outputMode?,index=0,fragmentLength?` | `{type,frames,text,address,path,profile,outputMode,note?,payloadFormat,payload,payloadBytes}` — the payload view is decoded back from the frames (`describeQR`) |
| `createWalletPairing` | `publicIndex,mode='full'` (one form: BTC/EVM/TRON account xpubs and one Solana address) | `{type:'bytes',frames,text,mode,payload,payloadBytes,verify[]}` — one static single-part `ur:bytes` QR for all chains ([docs/Wallet-Pairing-v1.md](../docs/Wallet-Pairing-v1.md)) |
| `decodeQR` | `frames:[string]` | `{complete,progress,request?}` |
| `scanBegin` / `scanAdd` | none / `frame` | Incremental collection for one camera session; the same result as `decodeQR` over all frames. A frame from another request is rejected. |
| `decodePayload` | `payload:string` | Public UR text/frames (including `ur:psbt`) or a bounded PSBT file as hex or Base64, also when wrapped over several lines |
| `review` | `request` | Summary, full fields, warnings, decode/risk classification, request hash |
| `resolveSigningPlan` | `request,wallets:[{localWalletId,publicIndex?}]` | Fixed tasks or an explicit non-signable matching status |
| `signPlanTask` | `request,plan,taskId,seed` (or `mnemonic,passphrase?`)`,previousResult?,riskAcknowledged?` | Signature/PSBT plus original `requestHash`, `planHash`, `taskId`, completed task IDs |
| `encodeResponse` | `request,result,fragmentLength?` | The request's public response protocol, `{type,frames,payloadFormat,payload,payloadBytes}`; the payload view is decoded back from the frames (PSBTs: `{psbt_base64,decoded}`) |
| `encodeQR` | Type and bytes | Bounded public UR/PSBT transport encoder |
| `capabilities` | none | Implemented scopes and explicit limitations |
| `validateBitcoinPolicy` | Public descriptor with BIP380 checksum | Complete policy validation and sample addresses; does not register trusted policy |

`deriveAccounts`, `deriveBitcoinCosigner` and direct `sign` remain internal compatibility/test utilities. Product address browsing and authorization use the public-index and signing-plan operations. `createPairing` is an alias of `createPublicPairing` with the same new inputs; it no longer selects a wire format by wallet brand. Internal JSON dispatch is not an external signing-QR protocol. TokenPocket action/JSON, TP fragments, private `bittool-signer-json` requests/responses and old Keystone envelopes are not accepted.

## Public index and paths

`derivePublicIndex` returns:

```text
version: 1
walletKeyId, masterFingerprint
bitcoinPublicNodes[6]
evmAccountNode, evmDefaultAddress
tronAccountNode, tronAddressIndex[100]
solanaPublicKeys[3]
```

Each HD node contains its full `originPath/accountPath`, public `xpub`, compressed `publicKey`, `chainCode`, parent fingerprint, depth, script profile and children rules. Address entries contain chain, profile, full path, index, public key and address. There are no secrets, root XPUBs or encryption passwords in this index.

The stable identity is SHA-256 of `UTF8("BitTool-Signer/WalletKeyId/v1") || masterCompressedPublicKey || masterChainCode`. The master material is used transiently and is not exported with the index. Changing a BIP39 passphrase changes this identity. A 4-byte fingerprint is only a candidate filter.

| Chain/profile | Registered origin or exact key |
|---|---|
| BTC `native` | `m/84'/0'/0'` |
| BTC `taproot` | `m/86'/0'/0'` |
| BTC `nested` | `m/49'/0'/0'` |
| BTC `legacy` | `m/44'/0'/0'` |
| BTC `multisig-native` | `m/48'/0'/0'/2'` |
| BTC `multisig-nested` | `m/48'/0'/0'/1'` |
| EVM | `m/44'/60'/0'` |
| TRON | `m/44'/195'/0'` |
| SOL `standard` | `m/44'/501'/0'/0'` |
| SOL `trust` | `m/44'/501'/0'` |
| SOL `legacy` | `m/44'/501'` |

Public BTC derivation is restricted to `/0/i` or `/1/i` below registered origins. Browsing displays receive addresses; a cosigner node alone cannot produce a multisig receive address. EVM and TRON support `/0/i` for any non-hardened `i`; the 100 cached TRON addresses (`/0/0`–`/0/99`) serve only address-only matching. Page sizes are bounded to 100 and indices to non-hardened values. SOL uses the three cached preset Ed25519 keys only, with no invented public derivation capability. An empty SOL browsing profile returns the three presets.

## Exact pairing modes

- BTC single-sig defaults to `accountXpub`: the account public node (chain code, origin, parent fingerprint) with its script expression in `crypto-account`, which is what Sparrow, BlueWallet, Nunchuk, Specter, Keeper and similar wallets import. `address` exports the exact address text. The former leaf-key `publicKey` mode is refused: BCR-2020-015 restricts `crypto-account` to account-level keys and no surveyed wallet can import it. Taproot uses the standard script tag 409 (`tr`), internal untweaked public material, and the correct BIP86 address tweak.
- BTC multisig always exports `accountXpub` in `crypto-account`, with native/nested script context. It is one cosigner, without a threshold, other cosigners or final wallet address. It must not be used as a complete script policy.
- EVM `wallet` exports the account `crypto-hdkey` with children `0/*`. `address` exports index 0 only. Address browsing remains able to show nonzero indices.
- SOL `wallet` exports `crypto-multi-accounts` containing exactly the selected preset's one 32-byte key. `address` exports that key's Base58 address.
- TRON exports only the selected raw address, any non-hardened index (`0` to `2^31-1`). No unverified public pairing payload or private JSON is invented.

Address payloads have no URI prefix, metadata, amount or UR wrapper. `text` is exactly the displayed frame, or all displayed animation frames joined by newlines.

## Deterministic matching and authorization

The resolver receives all local public records; there is no selected wallet, seed search or password trial. Incomplete records are passed without `publicIndex` and may result in `setupRequired`. Statuses are `ready`, `noMatch`, `missingSigner`, `ambiguous`, `setupRequired` or `invalid`; only `ready` contains signing tasks.

- EVM uses an explicit registered path and available address/public-key/fingerprint evidence. A path plus unique local fingerprint can resolve an optional-address request; path alone cannot. Without a path, only each wallet's index 0 is compared.
- SOL matches only its three presets. Transactions also require the matched key to occupy an actual required signer slot, including non-fee-payer/read-only signers. A recipient or ordinary account is not a signer.
- TRON uses explicit signer evidence. A request with a derivation path (every `tron-sign-request` has one) matches any non-hardened index derived from the account node; a request with only an address is compared with the 100 cached addresses. An operated account, permission-update member list or owner field alone never chooses a signing wallet. Current on-chain permissions remain unverified.
- BTC validates derivation metadata against registered public nodes and the actual committed input scripts. Without derivations, it tries only `/0/0` for the four single-sig origins. Cosigner fallback additionally requires explicit matching script public keys. Receive index 1, change addresses and other accounts are never searched without path evidence.

Duplicate effective seeds or indistinguishable metadata matches are refused. One PSBT can resolve to several fixed local wallet tasks, each listing its exact paths, keys and inputs. Multiple inputs belonging to one wallet form one task; separate local wallets require separate password authorization.

A plan commits to the canonical request hash, original payload bytes/digest, protocol, exact signing bytes and fixed targets. Signing checks the plan hash, rederives the effective wallet ID, rebuilds its public index, reruns resolution and compares the complete target task before using any private key. Raw CBOR is retained and re-decoded to reject a normalized request that differs from its original QR.

For accumulated PSBT signatures, the original transaction and every global/input/output field except added signatures must remain unchanged. Existing signatures are independently checked and retained. Results retain the **original** request hash throughout all tasks. Each task consumes its own short-lived secret scope. Partial/opaque decoding requires `riskAcknowledged:true` for that request; it cannot override invalid structure, unsupported algorithms or missing key evidence.

## Chain signing boundaries

BTC parses PSBT v0/v2, P2PKH, P2WPKH, P2SH-P2WPKH, conventional P2SH/P2WSH/P2SH-P2WSH multisig, Taproot key-path and supported c0 CHECKSIGVERIFY/CHECKSIGADD threshold leaf policies. MuSig2 and arbitrary scripts remain unsupported. ALL/DEFAULT sighashes only; legacy/SegWit v0 need full previous transactions, while all-Taproot inputs can use witness UTXOs. Outputs are all shown. An output counts as change only when its script is re-derived from the signing wallet's own public keys; PSBT labels and derivation metadata alone never establish change. Taproot signatures use fresh 32-byte BIP340 auxiliary randomness. `ur:psbt` requests are answered as `ur:psbt`, `crypto-psbt` as `crypto-psbt`. The signer adds partial signatures without finalizing or broadcasting.

EVM handles legacy/2930/1559 transactions, EIP-191 personal messages (arbitrary bytes) and EIP-712. EIP-712 values must match their declared types exactly (no truthy strings as `bool`, no ambiguous integer or address spellings), the declared `EIP712Domain` order defines the separator, and unused types are ignored as wallets do. `eth-signature` uses EIP-155 `v` for legacy transactions and y-parity for typed ones. Safe gas refunds, native value on calls, fees and transfers of tokens missing from the registry are surfaced in the review. Review covers Safe CALL/DELEGATECALL, MultiSend, eight owner/module/guard/handler permission methods, canonical EIP-2612/DAI Permit and Permit2 Single/Batch/TransferFrom/BatchTransferFrom schemas. Structurally valid deployments and unknown calldata can be high-risk opaque requests, requiring explicit per-request consent. Known Safe delegatecall/batch/permission operations receive expanded risk review. Transaction chain IDs come from signing bytes and must agree with the envelope; absent EIP-712 chain context is not fabricated. The reviewed mainnet table contains chain IDs 1, 56, 42161, 8453, 10, 137, 100 and 43114. The four-network token table does not restrict generic signing to four chains. Unsupported explicit network hints and conflicting request/transport chain IDs are rejected. Blob/7702 transaction types and raw-hash `eth_sign` remain unsupported.

TRON transaction signing uses exact `raw_data` protobuf bytes and SHA-256; supplied JSON/txID must match. Existing signatures are verified and retained internally. Public `tron-sign-request` carries the raw bytes and returns a detached 65-byte `tron-signature`; the coordinator assembles signatures. Message signing uses TIP-191's TRON prefix and byte length with Keccak-256, not the transaction hash rule. Messages that are not text are shown as exact bytes and classified opaque. Call value and high fee limits are surfaced. Permission ID, operated account and actual signer remain distinct. Review covers TRX, common TRC20/TRC721/TRC1155 ABI calls, AccountPermissionUpdate and Stake 2.0/resource contract types 54–59; unknown protobuf fields/contracts and TRC10 remain unsupported. Network identity and current permission membership cannot be established offline.

SOL signs exact legacy/v0 message bytes, verifies prior signatures and fills only the planned required slot. Public UR returns the detached signature; the coordinator retains other slots. Unresolved address lookup tables are rejected. Durable-nonce transactions are flagged, and one transfer's amount is never paired with another transfer's destination in the summary. Review covers System transfer/create/nonce/assign/allocate, SPL transfers/approvals/mint/burn/close/setAuthority/syncNative, ATA, compute budget, memo and stake delegate/split/withdraw/deactivate. Unknown programs are opaque; Token-2022 extensions and Squads approve/reject/cancel proposal references are partially decoded. These require explicit risk consent; proposal references are not presented as a verified proposal body. Message signing is restricted to recognizable valid UTF-8 text, 1–1024 bytes, including Unicode, and rejects transaction header prefixes. It has a separate branch and never serves as a fallback for malformed transactions.

NFT review (Revision 3): ERC-721/ERC-1155/TRC-721 transfers and approvals (with the ERC-20/ERC-721 selector ambiguity shown explicitly), Seaport 1.5/1.6 orders and bulk orders, LooksRare v2 makers and batch orders, blind Blur roots, and Solana SPL 0-decimal transfers, Metaplex Token Metadata TransferV1, Bubblegum (V1/V2), Core TransferV1, Token-2022 transfer hooks and Metaplex delegate/lock/burn instructions. The review exposes `display.assetKind`, `assetContract`, `assetContractLabel`, `tokenId` and, for orders, `give`/`receive`/`others`. Undeclared EIP-712 message keys are stripped (with a warning) only for recognised marketplace orders; every other typed-data request still rejects them. See `nft-orders.js`, `test/nft-evm.test.mjs` and `test/nft-solana.test.mjs`.

For detailed chain/parser coverage, consult `capabilities` and `test/chain-expansion.test.mjs`. Token registry recognition provides local display metadata, not proof of contract behavior, balances or execution outcomes.

## Validation

2026-09-22 (Revision 3): **all 173 engine tests pass**, with no failures, skips or cancellations. Besides the earlier protocol, public-index, resolver, chain-expansion and hardening suites (`test/hardening.test.mjs`: every engine finding of the Revision 2 internal review, Bitcoin change re-derivation, seed/phrase parity), Revision 3 adds `test/wallet-pairing.test.mjs`, `test/nft-evm.test.mjs`, `test/nft-solana.test.mjs`, and the QR payload-view suites `test/pairing-payload.test.mjs` and `test/response-payload.test.mjs`. The registry test checks all 3,350 bundled tokens (address shape per chain, unique identities, on-chain decimals, provenance per layer, Solana token-program binding, and an icon pack with no gaps whose every image hashes to the id the registry uses). Native JavaScriptCore, device and UI results are recorded separately in the implementation status.

Bundle: **854090 bytes**, SHA-256 `36a00e6a35405519baf58595d09029ed099626beb52f37634fea71db5fc6d72b`; see [bundle-manifest.json](bundle-manifest.json). Public integration fixtures are under `test/fixtures`, including `public-plan-vectors.json` and `evm-public-ui.json`.

Tests contain only public mnemonics, synthetic transactions and attributed upstream public fixtures. Never send funds to those test identities. An independent security audit, device side-channel review and named-wallet camera round-trip matrix remain separate release work.
