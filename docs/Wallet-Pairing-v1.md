# BitTool Signer Wallet-Level QR Pairing v1 — implementation

> **Payload widened, 18 October 2026 — the receiving side must be updated.** The wallet-level payload now carries **four Bitcoin accounts** (one per single-sig script type: `p2wpkh`, `p2tr`, `p2sh-p2wpkh`, `p2pkh`) instead of only BIP84, and **three Solana addresses** (the `standard`, `trust` and `legacy` presets, each entry now also carrying a `profile` field) instead of one. The `accounts` array is therefore 7 entries long, not 4, and a decoder must read the array by each entry's `chain`/`script` rather than by position. The payload no longer fits one QR code: it is now a **multi-part `ur:bytes` sequence** shown as an animated QR, so a decoder has to collect frames. Everything else — envelope fields, canonical CBOR, key names — is unchanged.
>
> **Renamed, 16 October 2026.** The app is now **BitTool Signer** and the wallet **BitTool Wallet**, both published by BITTOOL PTE. LTD. The wire identifiers changed with it, and the receiving side must be updated: the payload `protocol` is now **`bittool-signer-wallet`** (was `bitsigner-wallet`), the signing transport type is `bittool-signer-json`, and the device name inside `crypto-account` / `crypto-multi-accounts` is `BitTool Signer`. Everything else in this document is unchanged; the fixtures in this package are regenerated with the new names.

This document records exactly what BitTool Signer produces for the wallet-level pairing described in the draft *BitTool Signer Wallet-Level QR Pairing Protocol v1* (2026-09-22), and fills in the points that the draft's "Recommended Next Step" leaves open. The draft's decisions are followed as written; additions are marked **(addition)**. Chain-specific QR exports (Connect › Coin Level) are unchanged.

## Where it is in the app

Connect › **Wallet Level**, which is where the page opens (Coin Level is the second segment; the wallet page also links straight to it). BitTool Signer offers **one** wallet-level form: an account **xpub** for each of the four single-sig Bitcoin script types, for EVM and for TRON, and **all three Solana addresses**. It uses the draft's `full` layout (`"mode": "full"` inside the payload; the interface shows no Simple/Full choice). The page shows one **animated** QR code, the first address of every exported account to verify (four Bitcoin, EVM, TRON and three Solana, each row naming which account it is), the payload size and master fingerprint, and a collapsed *Payload (JSON)* disclosure with the developer view of the exact object. The toolbar copies the QR text. Only the wallet's authenticated public index is read; no password is asked. The page lists **BitTool Wallet** (BITTOOL PTE. LTD., iOS and Android) as the wallet this format works with.

The draft also defines a `simple` mode (one address per chain). BitTool Signer does not produce it; its reference decoder still accepts it, as the draft specifies.

## Transport and encoding

1. Logical object (below) → **canonical CBOR** → CBOR byte string → **`ur:bytes`** (BC-UR, BCR-2020-006 `bytes` type) → QR.
2. Canonical CBOR = RFC 8949 §4.2.1 core deterministic encoding: definite lengths, shortest-form integers, and map keys sorted by the bytewise order of their encoded keys (for text keys: shorter keys first, then bytewise). **Keys are the JSON field names as CBOR text strings** — the draft left integer keys open; text keys keep the JSON and CBOR views identical and self-describing. Values are text strings, unsigned integers, arrays and maps only; fields whose value is absent are omitted.
3. The UR's CBOR is the byte string that contains the canonical payload (so the decoder reads a byte string, then decodes it).
4. The QR code is a **multi-part UR** (`ur:bytes/<seq>-<count>/<bytewords>`), upper-cased so each frame uses alphanumeric mode. The payload is split into 400-byte fragments, with the fragment size capped at half the payload so there are always at least two frames: 1561 bytes and 4 frames of 831 characters for the test wallet. BitTool Signer refuses payloads above 4096 bytes, which bounds the frame count and the scan time. A reader must collect every frame before decoding; single-part `ur:bytes` from other exporters is still accepted, as BitTool Signer's reference decoder does.
5. A decoder must: require `protocol == "bittool-signer-wallet"`, require `version == 1` (other versions are refused, never read as v1), require `mode` ∈ `simple`/`full`, ignore unknown fields, and may refuse a payload that is not canonical CBOR (BitTool Signer's reference decoder does).

## Envelope

| Field | Type | Value |
| --- | --- | --- |
| `protocol` | text | `bittool-signer-wallet` |
| `version` | uint | `1` |
| `mode` | text | `full` (the draft also defines `simple`, which BitTool Signer does not produce) |
| `network` | text | `mainnet` |
| `masterFingerprint` | text | **(addition)** BIP32 master key fingerprint, 8 lowercase hex digits. Unknown-field rules make it safe for v1 parsers; it lets a watch wallet put BitTool Signer's fingerprint into PSBT and sign-request derivation data, which BitTool Signer uses to match requests. |
| `accounts` | array | four `btc` entries (one per script type, in the order `p2wpkh`, `p2tr`, `p2sh-p2wpkh`, `p2pkh`), then `evm`, `tron`, `sol` — **read by `chain`/`script`, not by position** |

## Accounts

- `btc`: **four entries**, one per single-sig script type — `p2wpkh` (`m/84'/0'/0'`, `bc1q…`), `p2tr` (`m/86'/0'/0'`, `bc1p…`), `p2sh-p2wpkh` (`m/49'/0'/0'`, `3…`) and `p2pkh` (`m/44'/0'/0'`, `1…`). Each carries `accountPath`, `script`, `xpub` (standard BIP32 `xpub` version bytes for every type; the `script` field, not the prefix, states the address type) and `derive` `{ "receive": "0/*", "change": "1/*" }`. The two `m/48'` multisig profiles are **not** included: a multisig wallet needs every cosigner key and a threshold, which the cosigner export (Connect › Coin Level) carries instead.
- `evm`: `accountPath` `m/44'/60'/0'`, `xpub`, `derive` `0/*`.
- `tron`: `accountPath` `m/44'/195'/0'`, `xpub`, `derive` `0/*`.
- `sol`: `profile` `bip44-solana` and an `accounts` list with **three** entries, one per preset: `index` 0 `standard` `m/44'/501'/0'/0'`, `index` 1 `trust` `m/44'/501'/0'`, `index` 2 `legacy` `m/44'/501'`. Each entry carries `index`, `profile`, `path` and `address`. Ed25519 derivation is hardened, so Solana has no xpub and a watch wallet cannot derive one preset from another — that is why all three addresses are sent. These are the Solana accounts whose signing requests BitTool Signer matches.

## Test vectors

Public, unfunded test phrase `abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about`, no passphrase.

### Payload

```json
{
  "protocol": "bittool-signer-wallet",
  "version": 1,
  "mode": "full",
  "network": "mainnet",
  "masterFingerprint": "73c5da0a",
  "accounts": [
    {
      "chain": "btc",
      "accountPath": "m/84'/0'/0'",
      "script": "p2wpkh",
      "xpub": "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V",
      "derive": {
        "receive": "0/*",
        "change": "1/*"
      }
    },
    {
      "chain": "btc",
      "accountPath": "m/86'/0'/0'",
      "script": "p2tr",
      "xpub": "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ",
      "derive": {
        "receive": "0/*",
        "change": "1/*"
      }
    },
    {
      "chain": "btc",
      "accountPath": "m/49'/0'/0'",
      "script": "p2sh-p2wpkh",
      "xpub": "xpub6C6nQwHaWbSrzs5tZ1q7m5R9cPK9eYpNMFesiXsYrgc1P8bvLLAet9JfHjYXKjToD8cBRswJXXbbFpXgwsswVPAZzKMa1jUp2kVkGVUaJa7",
      "derive": {
        "receive": "0/*",
        "change": "1/*"
      }
    },
    {
      "chain": "btc",
      "accountPath": "m/44'/0'/0'",
      "script": "p2pkh",
      "xpub": "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj",
      "derive": {
        "receive": "0/*",
        "change": "1/*"
      }
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
        {
          "index": 0,
          "profile": "standard",
          "path": "m/44'/501'/0'/0'",
          "address": "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"
        },
        {
          "index": 1,
          "profile": "trust",
          "path": "m/44'/501'/0'",
          "address": "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL"
        },
        {
          "index": 2,
          "profile": "legacy",
          "path": "m/44'/501'",
          "address": "D2PPQSYFe83nDzk96FqGumVU8JA7J8vj2Rhjc2oXzEi5"
        }
      ]
    }
  ]
}
```

Canonical CBOR: 1561 bytes, SHA-256 `c8db82cd92e0cf45cb6329b2429494b04a3b6bad7653c9bed1d2a5ef10f4a5fc`; a four-frame multi-part UR of 831 characters per frame. The vector above is complete; it is produced by `createWalletPairing` in `engine/protocols.js` and checked in `engine/test/wallet-pairing.test.mjs` (every xpub against independent BIP32 derivation, each Solana address against an independent SLIP-0010 implementation, exactly six xpubs and three Solana addresses, the absence of the `m/48'` multisig profiles, an animated frame sequence, canonical re-encoding, unknown-field tolerance, refusal of other versions, protocols, modes and non-canonical encodings).

## Security notes

- The payload contains only addresses, public keys and extended **public** keys; the builder reads the HMAC-authenticated public index and never the vault.
- Anyone who scans the QR code can see every BTC, EVM and TRON address of those accounts and the Solana address (privacy, not fund safety): treat it like sharing account xpubs.
- A wallet-level QR does not certify the receiving wallet. People should compare the first addresses shown under the QR with the receiving wallet before receiving funds.
