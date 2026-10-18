# Verification for this handoff package

Regenerated 18 October 2026 against the current code. This package only produces BitTool Wallet
development documentation and public interoperability data; it does not modify the BitTool
Signer app or its signing engine.

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
2. Ran `node --test test/wallet-pairing.test.mjs test/protocols.test.js`:
   **24 passed / 0 failed / 0 skipped.**
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
Wallet pairing protocol: 1
Current mode field: full
BTC: four account xpubs (p2wpkh, p2tr, p2sh-p2wpkh, p2pkh)
EVM / TRON: account xpubs
SOL: three explicit addresses (standard, trust, legacy), index 0
Inner CBOR bytes: 1561
BC-UR frames: 4 (fragmentLength 400)
Inner CBOR SHA-256:
c8db82cd92e0cf45cb6329b2429494b04a3b6bad7653c9bed1d2a5ef10f4a5fc

BitToolSigner/Resources/signer.js bytes: 1181026
Bundle SHA-256:
6933d0d8a6f60faa8222506ac0bd7eef80eb884c9f73e31e9f354b4740f21077
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
- The public vectors cover the protocol's basic paths. They do not mean that every token, NFT,
  multisig case, network error and UI acceptance item is complete; the full outstanding list is
  in the prompt.
