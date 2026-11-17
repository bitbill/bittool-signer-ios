# Verification for this handoff package

Regenerated 15 November 2026 against the current code. This package only produces BitTool Wallet
development documentation and public interoperability data; it does not modify the BitTool
Signer app or its signing engine.

> **Regenerated, 15 November 2026 — wallet pairing is now version 2.** The payload carries a
> **wallet-identity signature** (`khSig`, `khEpoch`), and the receiving side **must verify it on
> the device** against the code's own `p2pkh` account xpub before creating a wallet. Version 1 is
> no longer produced and the reference decoder refuses it; `fixtures/wallet-pairing-v1-rejected.json`
> is a v1 payload kept so a receiver can test that it refuses one. The signature vectors a
> receiver must reproduce byte for byte are in `../kh2_bittool_vectors.json`, and the format is
> specified in `../Wallet-Pairing-v2.md`. A receiver built against version 1 will not interoperate.
>
> **Regenerated, 18 October 2026.** The earlier version of this package described the
> pre-Revision-9 pairing payload: three account xpubs plus a single Solana address, 755 inner
> CBOR bytes. The shipping format now exports **seven accounts** — four Bitcoin script types,
> EVM, TRON — and **three Solana addresses**. The fixtures and the baseline below have been
> regenerated from current code. A receiving implementation built against the old numbers will
> not interoperate.

## What was done

1. Read the reference `BitTool Signer_Wallet_Level_QR_Pairing_v1_v2.md` against the current
   `protocols.js`, public index, resolver, the four chain signing implementations and their
   tests.
2. Ran `node --test test/wallet-pairing.test.mjs test/kh2.test.mjs test/solana-lookup-tables.test.mjs test/protocols.test.js`:
   **37 passed / 0 failed / 0 skipped.** The full engine suite is 238/238.
3. Ran `generate-fixtures.mjs`: wallet-level UR reassembly out of order, inner and outer CBOR
   bytes consistent; **9 real signing round-trip samples passed.**
4. Each sample goes through public account location and a fixed signing task, decodes the
   response as independent CBOR, and checks that the requestId and the signature or PSBT bytes
   are preserved exactly. EVM checks the recovered address (including multi-byte legacy `v`),
   Solana checks Ed25519, TRON checks the secp256k1 signature, and Bitcoin checks the ECDSA
   signature over the BIP143 digest and then finalizes and extracts the PSBT.
5. Every registered source file hashed identically before and after generation, and was
   re-checked afterwards against the snapshot. The app bundle's size and SHA-256 match its
   manifest.

## Baseline for this package

```text
Wallet pairing protocol: 2
Current mode field: full
BTC: four account xpubs (p2wpkh, p2tr, p2sh-p2wpkh, p2pkh)
EVM / TRON: account xpubs
SOL: three explicit addresses (standard, trust, legacy), index 0
Wallet identity: khSig over "OwnbitAuth:v2:epoch=1", key m/44'/0'/0'/0/1000000000
Identity address: 1N8ju3BdMHttCNBJ4d8v3eCrpzdLk1m9Vo
Inner CBOR bytes: 1666
BC-UR frames: 5 (fragmentLength 400)
Inner CBOR SHA-256:
cc911414877a3b544b90f6c8ac794c76197015b60c00002d12577608473894ef

BitToolSigner/Resources/signer.js bytes: 1194055
Bundle SHA-256:
a163698b989f2b0095d45ac12c6e482adf9d2433999e4ffe63cc69a997d89eee
```

The exact generation time, each source file's digest and the runtime versions are in
`fixtures/source-snapshot.json`. The source is the local working copy, not a release
certification or a Git commit snapshot.

## Scope of this verification

- The BitTool Wallet source was not accessed and no BitTool Wallet functionality was
  implemented. This handoff is the prompt and the vectors for that work.
- No real-device camera loop between BitTool Wallet and BitTool Signer was performed, no
  real-value broadcast, and no external wallet certification. None of those is claimed to pass.
- The no-`mode` vector is a proposed compatibility case for the BitTool Wallet receiving side.
  The current BitTool Signer reference decoder still requires `mode`, so that vector must not be
  treated as evidence of what the current cold side exports.
- The identity vectors were produced three independent ways before publication: by this engine,
  by a from-scratch reference implementation written from the written rule alone, and — because
  this is the same test phrase and the same derivation path — they are byte-identical to Ownbit's
  own published `HD-abandon-m/44h/0h/0h/0/1000000000` vectors for epochs 1 and 2. What has **not**
  been done is an end-to-end run against a real receiving wallet or a real server: no build yet
  reads a v2 code, so the vectors are the contract that stands in for that.
- The public vectors cover the protocol's basic paths. They do not mean that every token, NFT,
  multisig case, network error and UI acceptance item is complete; the full outstanding list is
  in the prompt.
