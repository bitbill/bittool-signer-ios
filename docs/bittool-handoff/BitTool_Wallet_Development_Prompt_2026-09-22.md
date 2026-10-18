# BitTool Wallet × BitTool Signer development prompt

Based on the BitTool Signer workspace code, real QR round-trip tests, and the user-supplied
`BitTool Signer_Wallet_Level_QR_Pairing_v1_v2.md`. Source digests are in the accompanying
`fixtures/source-snapshot.json`. This is the implementation task for BitTool Wallet; the text below
can be handed straight to a development agent.

> **Updated 18 October 2026.** The wallet-level payload now exports **seven accounts** — four Bitcoin
> script types, EVM, TRON — and **three Solana addresses**, across four animated frames, with 1,561
> bytes of inner CBOR at a 400-byte fragment length. The earlier version of this document described
> three xpubs, one Solana address and 755 bytes. **Read entries by their `chain` and `script` or
> `profile` fields, never by array index**, and collect every frame before decoding. The fixtures
> accompanying this document have been regenerated and are the authoritative baseline.

## 1. Your task

Implement the online wallet side compatible with BitTool Signer iOS directly in the existing
**BitTool Wallet** project, following the project's existing architecture, design system, RPC services
and account model, and deliver the implementation, automated tests and integration notes. Inspect the
project first; do not stop at a plan or a UI mock.

Add one new account source: a **BitTool Signer air-gapped wallet**. Inside BitTool Wallet it is a
multi-chain wallet holding public account material only. BitTool Wallet is responsible for querying
balances, assets, history, fees, nonces, UTXOs and blockhashes online, for constructing transactions,
producing the QR code to be signed, receiving the signature, verifying it, assembling, broadcasting and
tracking confirmation. The private keys never leave BitTool Signer.

**Pairing must use the wallet-level QR and import Bitcoin, EVM, TRON and Solana in one pass.** The user
must not be asked to pair chain by chain. "Connect wallet" here means local pairing by camera, **not a
Web3 WalletConnect relay or session**; do not open a WebSocket, a deep-link handshake, Bluetooth or an
HTTP service to connect to BitTool Signer. If BitTool Wallet's existing dApp and WalletConnect features
are to use this account, they must hand off to the QR signing flow.

BitTool Wallet must never ask to import BitTool Signer's recovery phrase, seed, private key, xprv, BIP39
passphrase or vault password. Pairing by QR does not unlock the cold side's private keys; after a
transaction has been reviewed on screen, BitTool Signer authorizes it at the moment of signing. BitTool
Wallet neither maintains nor assumes an "unlocked session" on the cold side.

Keep BitTool Wallet's existing wallet functionality. For this new account type, replace local signing
with external QR signing; do not turn all of BitTool Wallet into a read-only wallet.

## 2. Establish the current compatibility target first

The following are **facts about the current code**. Do not infer from older screenshots or from
placeholders in the draft:

| Item | Current BitTool Signer | What BitTool Wallet must do |
|---|---|---|
| Wallet protocol version | Integer `1` | Refuse unknown versions explicitly; the v2 in the attached filename does not mean wire version 2 |
| Wallet QR | `ur:bytes` containing a CBOR byte string, inside which is a canonical CBOR object | Both CBOR layers must be decoded correctly |
| `mode` | The current export still carries `"full"`, and exports only this one format | Be compatible with the current export; show no Simple/Full UI |
| The draft has no `mode` | The current code has not dropped the field | **A receiver-side compatibility extension for BitTool Wallet**: allow it to be absent or `full`, treating both as synonymous, and refuse other values for now. Do not claim that BitTool Signer currently emits a mode-less format |
| Fingerprint | Top-level `masterFingerprint`, 8 lowercase hex characters | Store it, use it to locate signing material; never treat it as a unique wallet identity or as proof of authenticity |
| BTC | **Four account xpubs**: `p2wpkh` (m/84'), `p2tr` (m/86'), `p2sh-p2wpkh` (m/49') and `p2pkh` (m/44'), each with receive and change branches | Support all four, selected by the `script` field. A wallet may surface whichever it needs, but must not assume only one is present |
| EVM / TRON | One account xpub each, `0/*` | Derive from the exported root public key; never derive other chains from the Bitcoin xpub |
| SOL | **Three explicit addresses**: standard (`m/44'/501'/0'/0'`), trust (`m/44'/501'/0'`) and legacy (`m/44'/501'`), all at index 0 | Store the explicit path and address for each. Ed25519 derivation is hardened, so no Solana account can be derived from another — do not try |
| Internal public index | A cache internal to the cold side, not the wallet QR | It is not part of the external protocol; never require the hot side to submit or parse it |
| Current networks | Bitcoin, TRON and Solana mainnet; EVM supports the eight chain IDs listed below | Do not assume testnets or arbitrary EVM chains are supported |

The draft governs product interaction; the actual byte protocol is defined by the current code and the
accompanying vectors. Mode-less reception is a hot-side compatibility strategy this task requires, and
is tested separately. Never silently change the cold-side protocol to simplify the hot side.

## 3. Product flow

### 3.1 Adding a wallet

Suggested entry: Add wallet → Connect hardware / air-gapped wallet → BitTool Signer → Scan wallet QR.

Support animated QR codes, out-of-order and repeated frames, and show real decoding progress. Once
reassembled, validate the protocol and every known field, then present the first address for each chain,
the fingerprint and the account count, so the user can compare them against BitTool Signer's own
verification section before naming and saving. Full addresses must be viewable and copyable; confirming
on a few leading and trailing characters is not enough.

A failed scan must give a clear reason: incomplete QR, unsupported format, unsupported version,
unsupported network, corrupt content, invalid account material, frames from another QR code mixed in.
"Nothing happens when I scan" is not acceptable. Scanning a transaction request or a signature at the
pairing entry should explain the type mismatch; a general scan entry may recognize the type and route to
the right flow.

Showing index 0 per chain by default is enough to keep BitTool Wallet simple, but the data layer must
store every descriptor and every exported Solana account. A multi-address entry can reuse BitTool
Wallet's existing capability; do not invent another QR format. If a Bitcoin change branch is used it
must be monitored, backed up, restored and used for change discovery as well — monitoring only receive
addresses would lose part of the balance. Record used indices and adopt an explicit address discovery
and gap-limit policy.

Importing the same descriptors again should be recognized as an existing wallet; the same fingerprint
with different public keys must never overwrite. The wallet name and BitTool Wallet's local ID are
generated by the hot side and never derived as authorization from arbitrary QR text.

### 3.2 Sending and authorizing

Select asset / transaction → construct online and show the details → user confirms → freeze the bytes to
be signed and the request → show the animated signing QR → the user scans and authorizes with BitTool
Signer → BitTool Wallet scans the signature back → verify locally → assemble → broadcast → track
confirmation.

The hot wallet's state should read "signed by BitTool Signer", never "unlock the vault before scanning".
A transaction needing several signatures shows how many are collected, which signers are missing and the
threshold required; broadcasting is allowed only once the threshold is met and verification passes.

A message or EIP-712 signature is returned to the original requester, not broadcast as an on-chain
transaction. Signed, broadcast, confirmed on chain and failed on chain must be distinct states.

A brief move to the background must preserve the current flow and the public pending state. When a
transaction expires, a nonce is used, a blockhash becomes invalid or the content changes, the old
signature is not reused: create a new requestId and a new QR code and sign again.

## 4. The exact structure of the wallet-level QR

### 4.1 Transport and encoding

```text
payloadObject
  → inner = deterministicCBOR(payloadObject)
  → urCBOR = CBOR_BYTE_STRING(inner)
  → new UR(urCBOR, "bytes")
  → BC-UR single/multipart QR
```

Decoding: BC-UR reassembly → `ur.type === "bytes"` → decode the outer CBOR to bytes → decode those
bytes to the inner map. It is not a JSON string, not UTF-8 hex or base64 treated as bytes, not
`ur:bittool-signer-wallet`, and not wrapped in an extra tag 24.

The inner object uses the **text keys** in the table below. Deterministic CBOR: definite lengths,
shortest-form integers and lengths, and map keys sorted by the byte order of their complete CBOR
encoding. Do not substitute alphabetical ordering of JSON keys. The fields known today are only text,
uint, array and map; unknown optional fields can safely be ignored, but the encoding, duplicate keys,
size and complexity must still be checked. Do not discard and re-encode in order to ignore unknown
fields, and do not wrongly refuse a legitimate extension.

The current export's inner payload has a 4,096-byte ceiling and a default `fragmentLength` of 400 bytes;
the current example is **1,561 bytes across 4 frames**. **That is not a length or frame count every
wallet must assume** — the payload does not fit in one QR code, so a receiver must always handle
multipart and must collect every frame before decoding. UR text should be recognized in either case.
Frames are not simple string slices: use the BC-UR fountain decoder, validate Bytewords and UR
integrity, support out-of-order and redundant frames, and refuse frames from mixed sessions.

Use bounded reassembly: at most 4,300 characters per frame, at most 1,048,576 characters of accumulated
retained text, a 131,072-byte ceiling on a signing payload, and count and time limits on frame
processing. Wallet pairing additionally enforces the 4,096-byte inner ceiling. Recognize repeated frames
without storing them permanently, and clear the collector when a session is cancelled or switched. The
QR animation should support pause, resume and rescan, and keep black modules on white with an adequate
quiet zone in both light and dark mode.

A minimal canonical encoding check:

```text
{version: 1, mode: "full", b: "x", aa: 2}
→ a46162617862616102646d6f64656466756c6c6776657273696f6e01
```

### 4.2 Envelope and per-chain descriptors

The xpubs and addresses below are placeholders; the real data is in the accompanying vectors, and these
placeholders must not be used as test input:

```json
{
  "protocol": "bittool-signer-wallet",
  "version": 1,
  "mode": "full",
  "network": "mainnet",
  "masterFingerprint": "73c5da0a",
  "accounts": [
    {"chain":"btc","accountPath":"m/84'/0'/0'","script":"p2wpkh","xpub":"<BTC native xpub>","derive":{"receive":"0/*","change":"1/*"}},
    {"chain":"btc","accountPath":"m/86'/0'/0'","script":"p2tr","xpub":"<BTC taproot xpub>","derive":{"receive":"0/*","change":"1/*"}},
    {"chain":"btc","accountPath":"m/49'/0'/0'","script":"p2sh-p2wpkh","xpub":"<BTC nested xpub>","derive":{"receive":"0/*","change":"1/*"}},
    {"chain":"btc","accountPath":"m/44'/0'/0'","script":"p2pkh","xpub":"<BTC legacy xpub>","derive":{"receive":"0/*","change":"1/*"}},
    {"chain":"evm","accountPath":"m/44'/60'/0'","xpub":"<EVM account xpub>","derive":"0/*"},
    {"chain":"tron","accountPath":"m/44'/195'/0'","xpub":"<TRON account xpub>","derive":"0/*"},
    {"chain":"sol","profile":"bip44-solana","accounts":[
      {"index":0,"path":"m/44'/501'/0'/0'","address":"<32-byte public key in Base58>"},
      {"index":0,"path":"m/44'/501'/0'","address":"<32-byte public key in Base58>"},
      {"index":0,"path":"m/44'/501'","address":"<32-byte public key in Base58>"}
    ]}
  ]
}
```

**The current wallet-level QR carries four Bitcoin account xpubs, one EVM xpub, one TRON xpub and three
Solana addresses.** Do not fill in or derive any Solana account that was not exported, and do not assume
only one Bitcoin script type is present.

Receiver validation requirements:

- `protocol`, the integer `version` and `network` must match; only mainnet is supported in this round.
  Refuse an unknown version or network explicitly, with no fallback.
- **Look entries up by `chain` plus `script` (Bitcoin) or `profile` (Solana), never by array position.**
  A duplicate, missing or invalid known entry means the whole payload is refused — never create a
  wallet that looks complete but is not. An unknown future chain may be reported as not imported and
  its content must not be used for signing; unknown optional metadata may be ignored.
- The current compatibility mode requires a valid `masterFingerprint`. The draft not specifying a
  fingerprint does not mean an all-zero value may be substituted. If it is missing, tell the user a
  complete, compatible wallet QR is needed. It is the master BIP32 fingerprint — not the account xpub's
  own fingerprint, and not the parent fingerprint inside an xpub.
- Every xpub uses the standard mainnet BIP32 public version `0x0488b21e`, is valid Base58Check, has
  depth 3 and a child index of `0x80000000`, and carries a valid compressed secp256k1 public key and
  chain code. Refuse xprv, tpub, corrupt values and unexpected zpub or other versions: this interface
  emits xpub, and the script is decided by the `script` field.
- Only an xpub's structure and the consistency of the exported fields can be checked. An xpub alone
  cannot prove it came from the claimed hardened path or fingerprint, or that it shares a seed with the
  other chains. Manual address comparison is still necessary.
- Paths, scripts and `derive` must match the v1 profile above, and an unknown path must never be
  silently rewritten to a default. BIP32 child indices are non-hardened, `0 ≤ i < 2^31`; do not iterate
  the whole space or accept an unbounded search.
- Each Solana entry must decode from Base58 to exactly 32 bytes and be a valid Ed25519 public key, at
  index 0 with one of the three paths above. Refuse duplicate addresses and abnormal or small-order
  public keys. No xpub is produced for Solana and no unexported account may be derived.
- Any QR code is untrusted input: refuse duplicate CBOR map keys, truncation, trailing garbage, invalid
  UTF-8, non-canonical integer lengths, indefinite-length objects and excessively deep structures. On
  storage, rebuild a validated internal model; never spread the raw object straight into application
  configuration.

### 4.3 Address derivation

| Chain | From exported material to an address |
|---|---|
| BTC `p2wpkh` | `xpub → /0/i` receive, `/1/i` change; HASH160 of the compressed public key, P2WPKH witness v0, mainnet `bc1q…` |
| BTC `p2tr` | `xpub → /0/i`, x-only key with the BIP86 tweak applied, witness v1, mainnet `bc1p…` |
| BTC `p2sh-p2wpkh` | `xpub → /0/i`, P2WPKH wrapped in P2SH, mainnet address beginning `3` |
| BTC `p2pkh` | `xpub → /0/i`, HASH160 of the compressed public key, mainnet address beginning `1` |
| EVM | `xpub → /0/i`; decompress the secp256k1 public key, drop the `04`, Keccak-256 the 64 bytes and take the last 20, displayed as a checksum address |
| TRON | the separate TRON xpub → `/0/i`; the same Keccak derivation, last 20 bytes, prefixed `0x41`, Base58Check. Never reuse the EVM address path |
| SOL | use the explicit public key for each of the three hardened paths directly |

The first addresses for the standard public test vector must equal:

```text
masterFingerprint = 73c5da0a

BTC p2wpkh       bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu        m/84'/0'/0'/0/0
BTC p2tr         bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr  m/86'/0'/0'/0/0
BTC p2sh-p2wpkh  37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf                m/49'/0'/0'/0/0
BTC p2pkh        1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA                m/44'/0'/0'/0/0
EVM              0x9858EfFD232B4033E47d90003D41EC34EcaEda94        m/44'/60'/0'/0/0
TRON             TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH                m/44'/195'/0'/0/0
SOL standard     HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk      m/44'/501'/0'/0'
SOL trust        GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL      m/44'/501'/0'
SOL legacy       D2PPQSYFe83nDzk96FqGumVU8JA7J8vj2Rhjc2oXzEi5      m/44'/501'
```

These are public test accounts that must never hold assets. A production import must not depend on or
embed their recovery phrase.

Deduplicate wallets using the normalized set of known public key descriptors, and optionally derive a
domain-separated hash as BitTool Wallet's local pairing ID. **Do not use the 32-bit masterFingerprint as
a unique ID.** BitTool Signer's internal `walletKeyId`, HMACs and public key caches are not part of the
QR protocol and the hot side is not expected to reproduce them.
## 5. After pairing: the public signing transports

The wallet-level QR is only for importing public accounts. **It is not a unified transaction signing
envelope.** Do not invent `bittool-signer-json` or `ur:bittool-signer-sign-request`, and do not use
BitTool Signer's internal `operation`/`request`/`plan` JSON as an external QR code.

| Chain | BitTool Wallet shows the cold side | BitTool Wallet receives from the cold side |
|---|---|---|
| BTC | `ur:crypto-psbt`, and `ur:psbt` is also supported | the same type, with signatures added |
| EVM | `ur:eth-sign-request` | `ur:eth-signature` |
| TRON | `ur:tron-sign-request` | `ur:tron-signature` |
| SOL | `ur:sol-sign-request` | `ur:sol-signature` |

A signing request UR's `cbor` is **the integer-keyed map itself**, not the two-layer byte wrapping used
for wallet pairing. Bitcoin is a CBOR byte string wrapping a raw PSBT. Do not confuse the three levels.

Generate a fresh random 16-byte requestId for every non-Bitcoin request, encoded as
`tag(37, byteString)` rather than UUID UTF-8 text. The response echoes key 1 unchanged. BitTool Signer's
ETH compatibility parsing also accepts a 1–64-byte opaque ID, but BitTool Wallet should use 16 bytes for
new requests and compare as bytes.

A signing path is a `crypto-keypath` map wrapped in CBOR `tag 304`:

```text
304({
  1: [44, true, 60, true, 0, true, 0, false, 0, false],
  2: 0x73c5da0a
})
```

That example is `m/44'/60'/0'/0/0`. Key 1 alternates index and a hardened boolean — **do not also add
0x80000000 to a hardened index** — and key 2 is the 4-byte fingerprint interpreted as a big-endian
uint32. Choose the actual leaf path; never send an account root or a wildcard. BIP32 path serialization
inside a PSBT follows BIP174 instead and is handled by the PSBT library; this alternating-array rule
does not apply there.

`origin` is `BitTool Wallet`, for display only. It is not an authenticated identity and not an arbitrary
remote callback URL. Do not add undefined fields to a signing map: ETH currently accepts keys 1–7 only,
and SOL and TRON keys 1–6 only.

## 6. Bitcoin: the P2WPKH loop and the multisig boundary

The baseline is a BIP84 single-signature wallet from the wallet-level pairing export, constructing a
PSBT v0 or v2; v0 is suggested for the first version. Use real UTXOs and the complete previous
transaction, and validate the txid, vout, amount and script.

**The cold side currently requires `nonWitnessUtxo`, the complete previous transaction, for legacy and
SegWit v0; `witnessUtxo` alone is not enough.** Even though the Bitcoin network does not require that
field for P2WPKH, BitTool Signer's security policy does. `witnessUtxo` may be supplied as well and must
agree.

Every input to be signed carries its public key, the masterFingerprint and the complete leaf path in
`bip32Derivation`. A change output also carries the corresponding derivation metadata and a consistent
script. Use SIGHASH_ALL; do not produce NONE, SINGLE or ANYONECANPAY, which are currently refused.
Whether the cold side identifies an output as change is decided by its own independent check — a hot-side
label is not proof.

On receiving the PSBT, confirm the original transaction's inputs, outputs, amounts, scripts, sequences
and locktime are unchanged, verify each added signature independently against the input script and
sighash, preserve existing cosigner signatures and metadata, then finalize, extract and broadcast.
Bitcoin has no requestId as above, so bind the response to the locally pending unsigned transaction and
the PSBT's key constraints rather than to the QR type or a txid string alone.

The cold side also supports chain-level BIP44/49/86 exports, BIP48 multisig, and Taproot within its
policy. **A wallet-level xpub does not constitute a multisig wallet and contains no BIP48 cosigner key,
threshold or other signers.** Do not fabricate those accounts from this pairing. If BitTool Wallet's
existing Bitcoin multisig feature is to interoperate, import the cold signer's chain-level BIP48
cosigner QR separately, store the complete descriptor, threshold and every cosigner public key, and
collect signatures one at a time with PSBTs. That extension is tracked and accepted separately; MuSig2
and unknown Taproot scripts are not claimed as supported.

## 7. EVM: requests, address recovery and assembly

The `eth-sign-request` CBOR map:

| key | type | content |
|---|---|---|
| 1 | tag37(bytes16) | requestId; required from BitTool Wallet |
| 2 | bytes | the data to sign, per the table below |
| 3 | uint | dataType 1 / 2 / 3 / 4 |
| 4 | uint | chainId; set explicitly for on-chain transactions and for requests with network context |
| 5 | tag304(map) | the complete derivationPath plus masterFingerprint |
| 6 | bytes20 | the derived signing address, as raw bytes, not a `0x` string |
| 7 | text | `BitTool Wallet`, at most 256 characters |

| dataType | content of key 2 |
|---|---|
| 1 | Legacy unsigned transaction RLP; the unsigned serialization with an explicit EIP-155 chainId, not a transaction hash |
| 4 | An EIP-2718 typed unsigned transaction, first byte `0x01` or `0x02`, supporting 2930 and 1559 |
| 2 | The complete EIP-712 JSON encoded as UTF-8: domain, types, primaryType, message |
| 3 | The raw message bytes for personal_sign; do not prefix or hash in advance |

Permitted chain IDs: `1, 56, 42161, 8453, 10, 137, 100, 43114`. The same EVM descriptor is used for all
of them, and where a chainId appears in the transaction bytes, in UR key 4 and in an EIP-712 domain, they
must agree. Token registry coverage is not the same as signing support for a network; never disguise a
testnet, a blob transaction, EIP-7702 or a raw-hash `eth_sign` request as a supported request.

Use bigint or decimal strings for large integers; never compute amounts with JavaScript floats. EIP-712
preserves the exact schema and values: a bool must be a real bool, integers unambiguous, an address
exactly 20 hex bytes, and duplicate JSON keys are not accepted. A custom EIP712Domain's field order takes
part in the computation and must not be rewritten before signing.

`eth-signature` returns `{1: tag37(requestIdBytes), 2: signatureBytes}`. **It is not a signed
transaction.** The cold side currently returns `r[32] || s[32] || v[1..9]`, where v is an unsigned
big-endian shortest byte sequence:

- Legacy transactions: `v = chainId * 2 + 35 + yParity`, which may exceed one byte, so the whole
  signature can exceed 65 bytes.
- Typed transactions: `v = yParity`, 0 or 1.
- personal and EIP-712: `v = 27 + yParity`.

Parse according to the locally pending type; never fix on taking byte 65 as v in every case. Check the
r/s ranges and low-S, and for legacy confirm that the chainId and parity recovered equal the pending
ones. Recover the address from the correct digest, confirm it matches the paired address, and re-check
the transaction hash after assembling the raw transaction. A matching QR requestId does not mean the
signature is valid.

Support native currency, ERC-20, ERC-721 and ERC-1155 transfers and approvals. Route existing dApp
requests through this adapter; an unknown contract call may still display as opaque on the cold side and
must not be labelled "fully parsed by the cold side" on the hot side.

Safe multisig signs a `SafeTx` EIP-712 with the owner's paired EOA. The Safe contract address, network,
owner list, threshold, nonce, operation and gas refund parameters are fetched and displayed explicitly by
the hot side, and the Safe contract address must never be used as key 6's signing address. Collect,
validate and order owner signatures per the Safe protocol before executing. Prefer EIP-712 and avoid
applying personal_sign's v adjustment by mistake. Show delegatecall, MultiSend and permission changes
item by item with their risks.

## 8. TRON: raw protobuf, permissions and the signature back

The `tron-sign-request` CBOR map:

| key | type | content |
|---|---|---|
| 1 | tag37(bytes16) | requestId |
| 2 | bytes | dataType 1: the raw protobuf bytes of `raw_data_hex` after hex decoding; dataType 2: raw message bytes |
| 3 | uint | 1 transaction / 2 personal message |
| 4 | tag304(map) | `m/44'/195'/0'/0/i` plus masterFingerprint |
| 5 | bytes21 | `0x41` plus the 20-byte signing address, decoded from Base58Check — not the address text |
| 6 | text | `BitTool Wallet` |

This is the public Keystone TRON UR contract that BitTool Signer uses. Do not send TronLink or
TokenPocket proprietary action JSON, a URL scheme, `keystone-sign-request`, or a home-made QR containing
the full transaction JSON.

For a transaction, key 2 contains **only the raw_data protobuf** — not the complete Transaction protobuf
wrapping raw_data and signatures, not ASCII hex, and not the txID. BitTool Wallet is responsible for RPC
construction, the reference block, timestamp, expiration, fee_limit and permission_id, and must freeze
those values once the QR code is displayed. The transaction digest and txID are `SHA256(raw_data_bytes)`.

The cold side currently supports one contract per transaction: TRX, the common TRC-20, TRC-721 and
TRC-1155 ABIs, AccountPermissionUpdate, and Stake 2.0 and resource types 54–59. Unknown protobuf fields
and contracts, and TRC-10, are refused. A witness-only permission with ID 1 is not used for this
signature.

`tron-signature` is `{1: tag37(requestIdBytes), 2: bytes65}`, with the signature as
`r32 || s32 || recoveryId1`, where recoveryId currently uses the 0/1 form, not EVM's 27/28. Verify
against the original digest and recover the signer, keep the original `raw_data_hex` unchanged, and
append the signature to the original transaction's `signature[]`. If an SDK's message verification
interface requires a different v representation, convert explicitly at that call boundary rather than
altering the transaction signing protocol.

Messages use TronWeb's signMessageV2 length prefix:

```text
Keccak256(0x19 || UTF8("TRON Signed Message:\n") || UTF8(decimalByteLength) || originalMessageBytes)
```

Supporting 1–8,192 bytes. Do not use SHA256(message), the older fixed 32-byte prefix, or add the prefix
twice.

TRON multisig: `owner_address` may differ from the member actually signing, so key 5 and the path should
describe **this member as signer**. The cold side's UR receives only raw_data and does not receive the
hot side's existing `signature[]`, a complete permission snapshot or network proof. The hot side must
therefore store and validate existing signatures, generate a request per member, deduplicate signers, and
confirm current permission membership, weight, threshold and operation mask before broadcasting. Never
assume the cold side has validated on-chain permissions or that the threshold is met.

TRON bytes carry no trustworthy proof of network identity, so BitTool Wallet must pin this account to a
mainnet endpoint and display the network clearly, to prevent sending the same signature to the wrong
network. The index may be any valid non-hardened `i`; do not carry over the old 0–99 limit.

## 9. Solana: explicit public keys and signature slots

The `sol-sign-request` CBOR map:

| key | type | content |
|---|---|---|
| 1 | tag37(bytes16) | requestId |
| 2 | bytes | signType 1: the serialized Message; signType 2: the raw UTF-8 message |
| 3 | tag304(map) | the exported path (`m/44'/501'/0'/0'`, `m/44'/501'/0'` or `m/44'/501'`) plus masterFingerprint |
| 4 | bytes32 | the chosen explicit Ed25519 public key, Base58-decoded to bytes |
| 5 | text | `BitTool Wallet` |
| 6 | uint | 1 transaction / 2 message |

Send the **Message bytes** for a transaction, not a complete Transaction with a signature count and
slots, and not a message hash. Legacy messages and v0 with static accounts are supported;
**messages with an Address Lookup Table are not.** If the existing builder uses ALTs, the message must be
recompiled before signing into one the cold side supports and that stays within the network packet
limit — simply removing the lookup table is not enough. A transaction that cannot be recompiled must be
disabled explicitly, with the reason explained.

`sol-signature` returns `{1: tag37(requestIdBytes), 2: bytes64}`, a detached Ed25519 signature only.
Verify it against the frozen Message bytes and the expected public key, find the correct slot among the
required signers named by the header and fill it in, preserving and validating the other slots, then
serialize and broadcast once every required signature is present. **Do not always fill slot 0**: a
signer that is neither the fee payer nor a readonly required signer can be the one signing here. Note
that this wallet now has three Solana addresses, so the slot must be matched against whichever of them
is signing.

The hot side stores the complete unsigned or partial Transaction and all signatures; the cold side's UR
carries no existing signatures. Once a blockhash expires, do not swap the blockhash under existing
signatures: generate a new message and requestId and collect every affected signature again. A signed
transaction is bound to its fee payer, blockhash, instructions and account order.

A plain message is currently limited to 1–1,024 bytes of recognizable UTF-8 text, and a transaction
header disguised as one is refused; a transaction that cannot be parsed must not be downgraded to
signType 2. Ed25519 signs the message itself, with no SHA256 first.

Support SOL and SPL Token transfers, and use the existing chain libraries for NFTs and Token-2022 while
preserving the correct semantics for mint, decimals, authority and additional accounts; the supported
range is whatever real messages verify. Do not assume the cold side fully validates Token-2022
extensions, on-chain metadata or transfer hooks. SPL multisig is a matter of collecting several required
signers; Squads is program-level multisig, and a proposal reference does not mean the cold side has
received and fully reviewed the proposal's content. Keep the two distinct from an ordinary multi-signer
transaction.

## 10. Local pending state, response validation and data safety

Implement a recoverable state machine, for example:

```text
draft → prepared → awaitingSignature → signatureVerified
      → readyToBroadcast → broadcasting → submitted → confirmed / failed
```

Multisig can loop between awaitingSignature and partially verified states. An expired signature, a
cancelled request and a replaced transaction are distinct states and must never jump straight to success.

Store at least: the local pendingId, walletId, chain and network, the signer's address, public key and
path, the requestId (for Bitcoin, its transaction binding), the request type, **the exact bytes to be
signed**, the digest, the complete unsigned transaction, verified signatures, the creation time, the
expiry, nonce and blockhash constraints, and the broadcast result. The network inside a pending record
must never be replaced by the scanned-back QR.

Trust no signature bytes before they are scanned back and checked. First check the UR type, the CBOR
types and lengths and the requestId, then perform chain-specific verification, bind the signer to the
transaction content, and check for an already-used, cancelled or expired request. Refuse the wrong
wallet, the wrong network, the wrong ID, a tampered payload, a duplicate signature and cross-request
replay; never accept on a matching masterFingerprint alone.

There is no error-response UR in this QR protocol for refusing or cancelling a signature. Offer cancel,
back and regenerate, and never sit waiting for an online callback. Display local parsing errors
separately from a cold-side refusal reason.

Every address and xpub is public cryptographic data, but together they expose complete account linkage
and fund activity. Protect them under BitTool Wallet's privacy and local storage policy: never write a
complete xpub, QR or message to logs, analytics or crash reports, and never upload a complete pairing
package automatically. Submit only the addresses a query needs. Remote token and NFT images, URLs,
symbols and names must never override the real contract, mint or recipient address the user has to
confirm.

Do not treat a pairing fingerprint, a UR checksum or the words "from BitTool Signer" as an authenticating
signature. This protocol has no hot-side challenge authentication, and it conveys neither balances nor
authorization to move funds.

## 11. Suggested implementation structure

Follow the existing code organization. These responsibilities can be separated out; rewriting the project
or introducing another state management system is not required:

- `BitToolSignerPairingCodec`: BC-UR, the two CBOR layers, schema validation and descriptor
  normalization.
- `BitToolSignerWatchWallet`: chain accounts, address derivation and discovery, deduplication and
  persistence.
- `AirGapSigningCoordinator`: immutable pending records, the animated QR, scanned responses and recovery
  state.
- `Bitcoin/EVM/Tron/SolanaSigningAdapter`: constructing the public request, validating the response,
  assembling and broadcasting.
- `ExternalSignerAccount`: a signer provider for BitTool Wallet's existing account, transaction and dApp
  interfaces.

Reuse mature cryptography and protocol libraries with pinned versions; do not implement production ECDSA,
Ed25519, BIP32, CBOR or fountain coding yourself. The cold side's tests currently use
`@ngraveio/bc-ur 1.1.13` and the Keystone ETH registry `0.22.1` / SOL registry `0.9.5`. Those versions are
a reference baseline only and the hot side need not adopt every runtime library. Whether the
implementation is JavaScript, Swift or Kotlin, it must pass the same vectors.

## 12. Required tests and acceptance

### Automated tests

1. Import the accompanying real current pairing and compare item by item: **the four Bitcoin account
   xpubs, the EVM and TRON xpubs, the nine first addresses, and all three Solana paths and addresses**.
   Validate the inner CBOR and the UR outer bytes, and confirm out-of-order and repeated frames produce
   the same result. **All four frames must be required before a result is produced.**
2. Test the mode-less receiver extension separately. Refuse version `"1"` as a string, version 2, mode
   simple, an unknown network, xprv, a corrupt xpub, the wrong depth, index or path, a duplicate chain
   and script combination, a missing entry, duplicate Solana addresses, an oversized payload, duplicate
   CBOR keys, mixed sessions and a corrupt checksum. Unknown optional fields may be ignored.
3. Multiple Bitcoin receive and change indices for each of the four script types, non-zero EVM and TRON
   indices including TRON ≥ 100, and all three Solana addresses at index 0. Refuse Solana index 1 or any
   path not exported in this pairing, and refuse a hardened public child. Cross-validate public key
   derivation with an independent library.
4. For all four chains: request → cold-side decode, review, public matching and signing → response → hot
   side verifying independently and assembling. Cover the nine accompanying signing vectors; do not merely
   mock a success or compare fixed UI strings.
5. EVM must cover a legacy multi-byte v (chainId 43114 in the sample), 1559, personal, EIP-712, ERC-20 and
   NFT, and Safe. A wrong chainId, a wrong v or parity, the wrong signer, and a modified amount or
   recipient must all fail.
6. Bitcoin must cover a witness-only input being refused for a missing previous transaction, mixed receive
   and change inputs, existing signatures preserved, and a modified PSBT output refused. If the multisig
   extension is supported, add a real 2-of-3 flow.
7. TRON must cover raw_data and txID binding, a member differing from the owner, permission IDs, merging
   existing signatures, duplicate signers and an expired transaction, and must not put the complete
   transaction JSON in key 2.
8. Solana must cover the message and transaction distinction, a non-zero signer slot, existing signatures
   preserved, several signers, an expired blockhash, and ALT refusal. A failed transaction must never fall
   back to message signing.
9. UI tests: scan errors are visible, a denied camera permission is recoverable, the flow survives
   backgrounding and returning, an old response is not accepted after cancelling, QR codes work in light
   and dark mode, dynamic type and small-screen layouts hold, and paired public material and pending
   records display with no network.
10. Use a mock RPC for the broadcast layer to test the state machine, fee changes, nonce conflicts,
    timeout retries and duplicate broadcasts. "A signature was received" must never be treated as
    transaction success. When the network result is uncertain, query the transaction hash before deciding
    to retry — never pay twice.

### Real-device integration

Use a **newly created dedicated test wallet** to verify real-device camera scanning between BitTool
Signer and BitTool Wallet, first-address comparison on pairing, and request and response delivery on all
four chains. The fake UTXOs, reference blocks and blockhashes in the automated vectors must never be
broadcast. The cold side accepts no arbitrary testnet profile, and nothing should send real funds or
change a chainId for the sake of testing; broadcasting real assets requires a separately arranged,
explicitly authorized environment.

Report "unit tests passed", "camera loop passed" and "on-chain broadcast confirmed" as distinct
statements. Incomplete real-device or on-chain verification must not be written up as certified
compatibility for every token, NFT and multisig case. Where an environment check cannot be completed,
state the specific reason and the steps to reproduce it, and carry on with the code that can be tested.

### Delivery requirements

Deliver actual code, tests and results, with: the new files and key entry points, a support matrix, an
explanation of any protocol differences, operating instructions, and the list of outstanding integration
work. Basic four-chain pairing and the single-signature loop must be complete; multisig, tokens and NFTs
are implemented and accepted within the boundaries above. Do not substitute a button or a brand name for
genuine interoperability.

Inspect BitTool Wallet's existing account model, transaction construction, QR scanner and external signer
extension points first, outline the implementation order briefly, and then implement. Unless a necessary
precondition is missing and cannot be inferred, do not keep asking whether to begin.

## 13. Attachments and sources

- `fixtures/wallet-pairing-current.json`: the object the current code actually generates, the inner and
  outer CBOR, every animated frame, and the nine addresses to compare.
- `fixtures/wallet-pairing-no-mode-receiver-extension.json`: the mode-less test case for the hot-side
  compatibility draft; explicitly not current cold-side output.
- `fixtures/signing-roundtrips.json`: nine public test requests with real signatures back — a Bitcoin
  PSBT, EVM personal/1559/legacy/EIP-712, TRON message and TRX, and Solana message and legacy transfer.
- `fixtures/source-snapshot.json`: the SHA-256 of the source and the bundle at generation time, the
  capabilities, and fixture check information. Use the digests here to pin the actual workspace baseline;
  do not treat Git HEAD as the version of uncommitted source.
- `generate-fixtures.mjs`: regenerates the vectors in the BitTool Signer repository when its dependencies
  are installed. It calls the cold-side engine for testing and should not enter a BitTool Wallet
  production bundle; the hot side needs no recovery phrase and no cold-side internal API.

Code basis: `engine/protocols.js` (pairing, UR/CBOR and responses), `engine/src/public-index.js` (paths
and public keys), `engine/src/resolver.js` (locating public material and fixing signing tasks),
`engine/src/{bitcoin,evm,tron,solana}.js` (the actual signing and refusal conditions), and
`engine/test/{wallet-pairing.test.mjs,protocols.test.js,public-index.test.js}` (interoperability vectors).
Where any other description in the repository disagrees with the source, report the discrepancy: the
actual bytes and behaviour of this snapshot are the integration baseline.

Standard references supplement the encoding and registry formats only and do not replace the BitTool
Signer constraints above: deterministic CBOR in
[RFC 8949 §4.2.1](https://www.rfc-editor.org/rfc/rfc8949.html#section-4.2.1); UR transport in
[Blockchain Commons BCR-2020-005](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md);
ecosystem type libraries in [Keystone UR Registry](https://github.com/KeystoneHQ/ur-registry).
