# BitTool Signer 1.0.0 — scope of this round and of the release

Baseline: Revision 2 of 21 September 2026 (the full rebuild). Project version 1.0.0 (1),
iOS 17 minimum. Because the app has not shipped, this round adopts the new storage format
(vault format 2, an authenticated public index) with no migration of older development data.

Item-by-item implementation of the new specification, test results, screenshots and bundle
checksums are collected in [IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md). Older
reports are kept as history; early test counts are not a substitute for this round's
acceptance.

## Product direction for this round

Four tabs at the bottom: Wallets · Scan · Activity · Settings. Several independent wallets →
browsing and pairing public data → automatic matching on scan → fixed signing tasks, each
authorized by its own password. Face ID protects app pages only. There is no global "unlock
vault", no manual switching of the signing wallet, no TP proprietary format, no networking
and no testnet entry point in the product.

## External acceptance still required before release

1. Verify on a real iPhone: the device Keychain, removing the lock-screen passcode,
   reinstalling, backup exclusion, file protection, Face ID failure and cancellation, screen
   recording and mirroring, restoring from the background, and camera scanning. Simulator
   fixtures cannot stand in for these results.
2. For every wallet whose compatibility is to be claimed, record the version, platform, chain
   and entry point, then complete pairing, address checking, request construction, review,
   signing, scanning back and local signature verification — covering, separately, the
   single-signature, multisig, token, NFT, message and permission operations supported.
3. Spends that are not yet supported, such as BTC MuSig2, must not be passed off as supported
   merely because the PSBT container is; nor may a Solana address lookup table without
   trusted context, or an arbitrary multisig proposal, be claimed as fully parsed. The
   authoritative refusal boundaries are in the [engine documentation](../engine/README.md).
4. An independent security audit, fuzzing, a dependency review, reproducible builds, and
   Apple distribution signing with the store materials that requires.

## Suggested device acceptance

- Use a dedicated test wallet with the network disconnected, and confirm that creating and
  importing, addresses, pairing, scanning, matching, signing and handing the result back all
  work. With the network enabled there must still be no product-level network prompt or block.
- Check light and dark, small screens, large type and VoiceOver — particularly QR codes, long
  addresses, risk text and the App Lock screen.
- With App Lock on, check a cold launch and the 119-second and 120-second background
  boundaries. Whether or not the lock screen appears, the signing password must be cleared on
  entering the background.
- A wrong recovery phrase, a weak password, a wrong wallet password, a tampered request and
  conflicting signature metadata must all fail, without leaking a secret.
- The same phrase with the same BIP39 passphrase must restore to the same identity, and a
  different passphrase to a different one. After the public index file is deleted or tampered
  with, the wallet shows Repair and one password entry rebuilds it, leaving the encrypted file
  and the local UUID unchanged.

Outstanding external acceptance cannot be substituted by a version number, by self-testing
against the SDK, or by the fact that the project compiles. Compatibility of public addresses
and recovery paths is not the same thing as QR signing interoperability.
