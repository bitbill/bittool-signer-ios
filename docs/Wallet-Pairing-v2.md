# BitTool Signer Wallet-Level QR Pairing v2 — implementation

> **This document is complete on its own.** It supersedes [Wallet-Pairing-v1.md](Wallet-Pairing-v1.md),
> which stays in the repository so an implementer can see exactly what changed and can test that
> a v1 code is refused. Everything v1 said about the envelope, the accounts, the canonical CBOR
> and the animated UR transport still holds; v2 adds two fields and one rule.

**What is new in v2 (BitTool Signer 1.1.0).** The payload carries a **wallet-identity signature**:
a signature, by the wallet's BIP44 identity key, of one fixed sentence. It proves that the holder
of that one key once signed that sentence, and it lets a receiver check that the key belongs to
the BIP44 legacy xpub in the same code. The receiving wallet verifies it **on the device,
offline**, and the backend verifies the same signature against the extended public key the wallet
registers, which is how a watch wallet paired from BitTool Signer and a hot wallet of the same seed
are recognised as one wallet.

It does **not** make the code tamper-evident or uncopyable — see
[What the signature does not prove](#what-the-signature-does-not-prove). An earlier draft of this
document said a receiver could "tell a real pairing from a copy"; that was wrong, and so was the
pairing page's wording to the same effect, both corrected in Revision 16.

- `version` is **2**. BitTool Signer no longer produces v1, and its reference decoder no longer
  accepts v1 — a watch wallet created from an unsigned code has no identity to register.
- Two new fields: `khSig` and `khEpoch`.
- Receivers **must** verify `khSig` locally before creating a wallet (see [Receiving side](#receiving-side)).
- Needs **BitTool Wallet 1.1.0 or later**. The pairing page says so.

Chain-specific QR exports (Connect › Coin Level) are **unchanged**.

## Where it is in the app

Connect › **Wallet Level**, which is where the page opens (Coin Level is the second segment; the
wallet page also links straight to it). BitTool Signer offers **one** wallet-level form: an
account **xpub** for each of the four single-sig Bitcoin script types, for EVM and for TRON, and
**all three Solana addresses**. It uses the draft's `full` layout (`"mode": "full"` inside the
payload; the interface shows no Simple/Full choice). The page shows one **animated** QR code, the
first address of every exported account to verify (four Bitcoin, EVM, TRON and three Solana, each
row naming which account it is), a note that the code needs BitTool Wallet 1.1.0 or later, the
payload size and master fingerprint, and a collapsed *Payload (JSON)* disclosure with the
developer view of the exact object. The toolbar copies the QR text. The page lists **BitTool
Wallet** (BITTOOL PTE. LTD., iOS and Android) as the wallet this format works with.

**When the password is asked.** A wallet created or imported on 1.1.0 signs its identity at that
moment, from the seed already in hand, and stores the signature beside its authenticated public
index — so opening the pairing page never asks for a password. A wallet saved by an earlier
version has no signature: the page shows a password field instead of a QR, once. After the
signature is stored the page behaves like any other wallet's. Cancelling simply leaves that
wallet without a wallet-level code; Coin Level keeps working.

The draft also defines a `simple` mode (one address per chain). BitTool Signer does not produce
it; its reference decoder still accepts it, as the draft specifies.

## The wallet-identity signature

| | |
| --- | --- |
| Identity key | `m/44'/0'/0'/0/1000000000` — the non-hardened child `AUTH_INDEX` of the **BIP44 receive-branch xpub** |
| `AUTH_INDEX` | `1000000000` |
| Message | `OwnbitAuth:v2:epoch=<khEpoch>` — ASCII, no spaces, epoch in decimal. Nothing else is ever signed. |
| Digest | `SHA256(SHA256(0x18 ‖ "Bitcoin Signed Message:\n" ‖ varint(len) ‖ message))` |
| Signature | ECDSA secp256k1, **RFC 6979** deterministic `k`, **low S**; base64 of 65 bytes: header ‖ R (32) ‖ S (32) |
| Header | `27 + recovery id + 4` (the `+ 4` marks a compressed key), so `31` or `32` in practice; a verifier must accept `27..42` |
| Verifying address | the P2PKH (`1…`) address of that key |
| `kh2` | lower-case hex of `SHA-256(R ‖ S)` with S folded into the low half — the value the backend stores a hash of |

**Why BIP44 and not BIP84.** The backend derives the identity key as the non-hardened child
`AUTH_INDEX` of the xpub the wallet registered in `extendedKeys`, and BitTool Wallet registers the
**BIP44 receive-branch xpub** (`m/44'/0'/0'/0`) — for a hot wallet of the same seed and for a watch
wallet paired from BitTool Signer alike, so the two are recognised as one wallet. The identity key
therefore sits under BIP44, even though the wallet's default receive addresses are BIP84. The
pairing payload carries that account's xpub as the `p2pkh` entry, which is what a receiver derives
from.

Because `k` is deterministic, the same wallet and epoch always produce the same bytes: a
reinstall re-derives exactly the identity the backend already holds.

`khEpoch` exists for rotation. The backend currently only has epoch 1; BitTool Signer signs epoch
1 and the field is carried so a later epoch needs no format change.

**Only one sentence can be signed.** The engine operation takes an epoch and nothing else — there
is no way to pass a message in, so an attacker who reaches the engine cannot have it sign
arbitrary text. The signature is also verified against its own key before it is returned, and
again against the wallet's public index before it goes into a payload.

## Transport and encoding

1. Logical object (below) → **canonical CBOR** → CBOR byte string → **`ur:bytes`** (BC-UR,
   BCR-2020-006 `bytes` type) → QR.
2. Canonical CBOR = RFC 8949 §4.2.1 core deterministic encoding: definite lengths, shortest-form
   integers, and map keys sorted by the bytewise order of their encoded keys (for text keys:
   shorter keys first, then bytewise). **Keys are the JSON field names as CBOR text strings.**
   Values are text strings, unsigned integers, arrays and maps only; fields whose value is absent
   are omitted. The two new keys sort with the rest: `khSig` (5 characters) before `khEpoch` (7),
   both after `mode` and before `network`.
3. The UR's CBOR is the byte string that contains the canonical payload (so the decoder reads a
   byte string, then decodes it).
4. The QR code is a **multi-part UR** (`ur:bytes/<seq>-<count>/<bytewords>`), upper-cased so each
   frame uses alphanumeric mode. The payload is split into 400-byte fragments, with the fragment
   size capped at half the payload so there are always at least two frames: 1666 bytes and
   **5 frames of 717 characters** for the test wallet. BitTool Signer refuses payloads above 4096
   bytes, which bounds the frame count and the scan time. A reader must collect every frame
   before decoding; single-part `ur:bytes` from other exporters is still accepted.

## Envelope

| Field | Type | Value |
| --- | --- | --- |
| `protocol` | text | `bittool-signer-wallet` |
| `version` | uint | **`2`** |
| `mode` | text | `full` (the draft also defines `simple`, which BitTool Signer does not produce) |
| `network` | text | `mainnet` |
| `masterFingerprint` | text | BIP32 master key fingerprint, 8 lowercase hex digits. Lets a watch wallet put BitTool Signer's fingerprint into PSBT and sign-request derivation data, which BitTool Signer uses to match requests. |
| `khSig` | text | **(new in v2)** the wallet-identity signature, base64 of 65 bytes |
| `khEpoch` | uint | **(new in v2)** the epoch the signature is for; `1` today |
| `accounts` | array | four `btc` entries (one per script type, in the order `p2wpkh`, `p2tr`, `p2sh-p2wpkh`, `p2pkh`), then `evm`, `tron`, `sol` — **read by `chain`/`script`, not by position** |

## Accounts

- `btc`: **four entries**, one per single-sig script type — `p2wpkh` (`m/84'/0'/0'`, `bc1q…`),
  `p2tr` (`m/86'/0'/0'`, `bc1p…`), `p2sh-p2wpkh` (`m/49'/0'/0'`, `3…`) and `p2pkh`
  (`m/44'/0'/0'`, `1…`). Each carries `accountPath`, `script`, `xpub` (standard BIP32 `xpub`
  version bytes for every type; the `script` field, not the prefix, states the address type) and
  `derive` `{ "receive": "0/*", "change": "1/*" }`. **The `p2pkh` entry is also the identity
  account**: `0/1000000000` under its xpub is the key that signed `khSig`. The two `m/48'`
  multisig profiles are **not** included: a multisig wallet needs every cosigner key and a
  threshold, which the cosigner export (Connect › Coin Level) carries instead.
- `evm`: `accountPath` `m/44'/60'/0'`, `xpub`, `derive` `0/*`.
- `tron`: `accountPath` `m/44'/195'/0'`, `xpub`, `derive` `0/*`.
- `sol`: `profile` `bip44-solana` and an `accounts` list with **three** entries, one per preset:
  `index` 0 `standard` `m/44'/501'/0'/0'`, `index` 1 `trust` `m/44'/501'/0'`, `index` 2 `legacy`
  `m/44'/501'`. Each entry carries `index`, `profile`, `path` and `address`. Ed25519 derivation is
  hardened, so Solana has no xpub and a watch wallet cannot derive one preset from another — that
  is why all three addresses are sent.

## Receiving side

A decoder must:

1. Require `protocol == "bittool-signer-wallet"`.
2. Require `version == 2`. **Refuse every other version, v1 included** — never read another
   version as v2. On a v1 code, tell the person to update BitTool Signer to 1.1.0 or later and
   scan again. (`fixtures/wallet-pairing-v1-rejected.json` is a v1 payload for exactly this test.)
3. Require `mode` ∈ `simple`/`full`.
4. Require `khEpoch` to be an integer ≥ 1, and `khSig` to decode to exactly 65 bytes with a
   header in `27..42` and `0 < R, S < n`. Missing or malformed → refuse.
5. **Verify `khSig` on the device.** Take the `btc` account whose `script` is `p2pkh` and whose
   `accountPath` is `m/44'/0'/0'`, derive `0/1000000000` from its xpub (public derivation), form
   that key's P2PKH address, and verify the Bitcoin message signature of
   `OwnbitAuth:v2:epoch=<khEpoch>` against it. **Does not verify → refuse the code.** Verifying
   both ways — the recovered key equals the derived key *and* an explicit ECDSA verification with
   low-S — rejects a malleated or re-headered signature.
6. Ignore unknown fields of any type, and may refuse a payload that is not canonical CBOR
   (BitTool Signer's reference decoder does).

Local verification is not a formality: it stops a code whose signature belongs to a different
wallet from being registered as this one. It does not establish that the rest of the code is what
BitTool Signer exported. Register the signature with the backend (`registerKhV2`, or `khSig` on the
create/import call) after it has verified locally.

**The receiving wallet must have the person compare the first address of every account** — all four
Bitcoin script types, EVM, TRON and the three Solana addresses — with the ones BitTool Signer shows
under the QR, before any of them is used to receive funds. Checking only the Bitcoin addresses is
not enough: the signature binds the BIP44 legacy account and nothing else.

## What the signature does not prove

The signature covers the sentence `OwnbitAuth:v2:epoch=<khEpoch>` and nothing else. Three things
follow, and a receiver has to be built around them:

1. **The other accounts are not bound.** Only the BIP44 legacy (`p2pkh`) xpub is tied to the
   signature, because that is the account the identity key derives from. The BIP84, BIP86 and
   BIP49 xpubs, the EVM and TRON xpubs and the Solana addresses are not covered. Someone who can
   replace what a person scans can keep the legacy xpub and the signature from a real code and
   swap every other account for their own; the signature still verifies.
2. **The code is static and copyable.** RFC 6979 makes the signature deterministic, and no
   challenge or time is signed, so a photograph or screenshot of a real code is a real code. A
   receiver cannot tell a first scan from a replay, nor a code shown by BitTool Signer from the
   same bytes shown by anything else.
3. **So the person is the check.** The first addresses BitTool Signer shows under the QR are the
   only reference that does not come from the code itself. A receiver must show the first address
   of every account it creates and ask the person to compare each one before use.

Closing gaps 1 and 2 needs a protocol change and a matching BitTool Wallet release: either a second,
domain-separated signature over the hash of the whole canonical CBOR body (binds every account; the
code stays static), or a challenge from the receiver that the Signer signs (prevents replay; needs
a QR round trip). Neither is implemented. Until one is, the limits above are the specification.

## Test vectors

Public, unfunded test phrase `abandon abandon abandon abandon abandon abandon abandon abandon
abandon abandon abandon about`, no passphrase. Never send assets to these addresses.

### Identity signature

Machine-readable: [`kh2_bittool_vectors.json`](kh2_bittool_vectors.json). Every BitTool platform
(Wallet iOS, Wallet Android, Signer Android) must reproduce these bytes exactly.

```
identity path          m/44'/0'/0'/0/1000000000
identity public key    02a61d47c2a0326f197d2d42bfc27b4171f7870e6b3d7ad37f3f210c3d602bab1c
identity address       1N8ju3BdMHttCNBJ4d8v3eCrpzdLk1m9Vo
registered xpub        xpub6ELHKXNimKbxMCytPh7EdC2QXx46T9qLDJWGnTraz1H9kMMFdcduoU69wh9cxP12wDxqAAfbaESWGYt5rREsX1J8iR2TEunvzvddduAPYcY
                       (m/44'/0'/0'/0 — its non-hardened child 1000000000 is the identity key)

epoch 1   message  OwnbitAuth:v2:epoch=1
          khSig    IDbq1RPzOmq1q37JrcXcPBa9vVjrpG0B+9/ltJXQjfWlDGoP/gwHDMeGFH5XdL693wnhbeAsBdfRj7x70s94Lm4=
          R        36ead513f33a6ab5ab7ec9adc5dc3c16bdbd58eba46d01fbdfe5b495d08df5a5
          S        0c6a0ffe0c070cc786147e5774bebddf09e16de02c05d7d18fbc7bd2cf782e6e
          kh2      4fb494ddc6dac144c283c3a24f92156937c855a1b2e3997981ef510465d948fc

epoch 2   message  OwnbitAuth:v2:epoch=2
          khSig    HyJlRiut4wBA9pcd0q6BFqC1ghMJUhpRd82P3pUS+LNLBY0MOquhqW11cNTf1QGYSHUJ3b8N930O+SvrVOIdYqE=
          R        2265462bade30040f6971dd2ae8116a0b5821309521a5177cd8fde9512f8b34b
          S        058d0c3aaba1a96d7570d4dfd50198487509ddbf0df77d0ef92beb54e21d62a1
          kh2      af8fde9ee528be6f31de021820fa7490b1584b0b753b29e12443927135ec5292
```

These two were produced independently three times before being published: by BitTool Signer's own
engine, by a from-scratch reference implementation, and — because this is the same phrase and the
same path Ownbit's shipped implementation uses — they are byte-identical to Ownbit's own
`HD-abandon-m/44h/0h/0h/0/1000000000` vectors for epochs 1 and 2.

### Payload

The full object, with `khSig` as above:

```json
{
  "protocol": "bittool-signer-wallet",
  "version": 2,
  "mode": "full",
  "network": "mainnet",
  "masterFingerprint": "73c5da0a",
  "khEpoch": 1,
  "khSig": "IDbq1RPzOmq1q37JrcXcPBa9vVjrpG0B+9/ltJXQjfWlDGoP/gwHDMeGFH5XdL693wnhbeAsBdfRj7x70s94Lm4=",
  "accounts": [
    {
      "chain": "btc",
      "accountPath": "m/84'/0'/0'",
      "script": "p2wpkh",
      "xpub": "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V",
      "derive": { "receive": "0/*", "change": "1/*" }
    },
    {
      "chain": "btc",
      "accountPath": "m/86'/0'/0'",
      "script": "p2tr",
      "xpub": "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ",
      "derive": { "receive": "0/*", "change": "1/*" }
    },
    {
      "chain": "btc",
      "accountPath": "m/49'/0'/0'",
      "script": "p2sh-p2wpkh",
      "xpub": "xpub6C6nQwHaWbSrzs5tZ1q7m5R9cPK9eYpNMFesiXsYrgc1P8bvLLAet9JfHjYXKjToD8cBRswJXXbbFpXgwsswVPAZzKMa1jUp2kVkGVUaJa7",
      "derive": { "receive": "0/*", "change": "1/*" }
    },
    {
      "chain": "btc",
      "accountPath": "m/44'/0'/0'",
      "script": "p2pkh",
      "xpub": "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj",
      "derive": { "receive": "0/*", "change": "1/*" }
    },
    {
      "chain": "evm",
      "accountPath": "m/44'/60'/0'",
      "xpub": "xpub6DCoCpSuQZB2jawqnGMEPS63ePKWkwWPH4TU45Q7LPXWuNd8TMtVxRrgjtEshuqpK3mdhaWHPFsBngh5GFZaM6si3yZdUsT8ddYM3PwnATt",
      "derive": "0/*"
    },
    {
      "chain": "tron",
      "accountPath": "m/44'/195'/0'",
      "xpub": "xpub6D1AabNHCupeiLM65ZR9UStMhJ1vCpyV4XbZdyhMZBiJXALQtmn9p42VTQckoHVn8WNqS7dqnJokZHAHcHGoaQgmv8D45oNUKx6DZMNZBCd",
      "derive": "0/*"
    },
    {
      "chain": "sol",
      "profile": "bip44-solana",
      "accounts": [
        { "index": 0, "profile": "standard", "path": "m/44'/501'/0'/0'", "address": "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk" },
        { "index": 1, "profile": "trust", "path": "m/44'/501'/0'", "address": "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL" },
        { "index": 2, "profile": "legacy", "path": "m/44'/501'", "address": "D2PPQSYFe83nDzk96FqGumVU8JA7J8vj2Rhjc2oXzEi5" }
      ]
    }
  ]
}
```

Canonical CBOR: **1666 bytes**, SHA-256
`cc911414877a3b544b90f6c8ac794c76197015b60c00002d12577608473894ef`; a five-frame multi-part UR of
717 characters per frame. The exact bytes, the frames and the derived identity are in
[`bittool-handoff/fixtures/wallet-pairing-current.json`](bittool-handoff/fixtures/wallet-pairing-current.json);
a v1 payload to test refusal against is in
[`bittool-handoff/fixtures/wallet-pairing-v1-rejected.json`](bittool-handoff/fixtures/wallet-pairing-v1-rejected.json).

The vector above is produced by `createWalletPairing` in `engine/protocols.js` and checked in
`engine/test/wallet-pairing.test.mjs` and `engine/test/kh2.test.mjs` (every xpub against
independent BIP32 derivation, each Solana address against an independent SLIP-0010
implementation, exactly six xpubs and three Solana addresses, the absence of the `m/48'` multisig
profiles, an animated frame sequence, canonical re-encoding, unknown-field tolerance, refusal of
other versions — v1 included — protocols, modes and non-canonical encodings, the published
identity vectors byte for byte, refusal of a missing, malformed, wrong-epoch, malleated or
other-wallet signature, and the fact that no text other than the fixed sentence can be signed).

## Security notes

- The payload contains only addresses, public keys, extended **public** keys and a signature over
  one fixed public sentence. The builder reads the HMAC-authenticated public index and never the
  vault; the signature is produced from the seed once, then stored beside that index under the
  same HMAC and device protection.
- `khSig` and `kh2` identify a wallet. They are never logged, and `kh2` is not put in the payload
  — a receiver computes it from the signature.
- Anyone who scans the QR code can see every BTC, EVM and TRON address of those accounts and the
  Solana addresses (privacy, not fund safety): treat it like sharing account xpubs. The signature
  adds nothing to that exposure. It proves only that the holder of the BIP44 identity key signed
  one fixed sentence — not that whoever shows the code built it.
- The signature does not authorize anything. It is not a transaction, cannot be replayed as one,
  and covers a sentence with no amounts, addresses or recipients in it.
