# BitTool Signer for iOS · 1.0.0

**BitTool Signer** is an offline, air-gapped transaction signer published by BITTOOL PTE. LTD., meant to be used alongside **BitTool Wallet**: [bittool.com](https://bittool.com) · [bittool.com/signer](https://bittool.com/signer) · [bittool.com/wallet](https://bittool.com/wallet). Both apps share one mark; the signer uses the dark version and the wallet the light one. This repository is the app's source: [github.com/bitbill/bittool-signer-ios](https://github.com/bitbill/bittool-signer-ios).

SwiftUI with a JavaScriptCore engine, iOS 17 minimum, Liquid Glass on iOS 26 with native fallbacks on iOS 17 and 18. The app opens no network connection at any point: the signing engine, the token registry and every icon are bundled.

The interface is available in **21 languages**. The app is called BitTool Signer in all of them — the name is not translated; only the camera and Face ID permission prompts are localized.

**Test results, the fix log and the limits of what has actually been verified are in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md). A project that compiles and passes its tests is not the same thing as one certified compatible by third-party wallets, or independently audited.**

## License and review

Released under the [MIT License](LICENSE) (BITTOOL PTE. LTD., 2026).

The code has been through AI-assisted security review; the findings were fixed and covered by regression tests (see [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)). **That is not a third-party independent audit** and guarantees nothing. An independent audit is still on the list.

### Checking that the app you installed is this source

See [docs/Reproducible-Build.md](docs/Reproducible-Build.md). The short version: an App Store executable **cannot** be reproduced byte for byte — Apple re-signs it and FairPlay-encrypts it, and the Swift toolchain makes no determinism promise. What can be checked is the part that decides what you are signing. Every transaction parser, risk rule and signing plan lives in one unencrypted resource, `signer.js`, which you can extract from an `.ipa` you downloaded yourself and compare against a build from this source:

```sh
cd engine && npm ci --ignore-scripts && npm run build
shasum -a 256 ../BitToolSigner/Resources/signer.js
```

`scripts/release-manifest.sh` writes a release manifest: the commit, the hash of every tracked file in a fixed order, and an engine hash rebuilt from a clean dependency install in a throwaway copy of that commit. Run it on the same tag and `diff` the two.

## Building

Open `BitToolSigner.xcodeproj` and pick the BitTool Signer scheme. Creating a wallet on a real device needs a device passcode and your own development team.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BitToolSigner.xcodeproj -scheme BitToolSigner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test

cd engine
npm ci --ignore-scripts
npm test
npm run build
```

Installing dependencies needs a network; the app downloads nothing and executes no remote code at runtime. For the screenshot tour see `BitToolSignerUITests/ScreenshotTour.swift`: `TEST_RUNNER_BITTOOL_SIGNER_SHOT_DIR` writes light and dark screenshots to a local directory, and `TEST_RUNNER_BITTOOL_SIGNER_EXTRA_ARGS` passes extra launch arguments, larger dynamic type for instance.

## The interface

Four tabs: **Wallets · Scan · Activity · Settings**.

- **Wallets** — every wallet side by side; there is no "current wallet". A card shows an identity colour, the name, the master fingerprint (the same `masterFingerprint` the pairing QR carries) and the networks it supports, with direct links to Pair and Addresses. The detail page covers all four chains plus wallet-level pairing, receiving addresses, revealing the recovery phrase, changing the password, renaming and deleting. Tapping a chain opens Coin Level for it; tapping Wallet Level, or Pair on the card, opens Wallet Level.

  The Pair page switches between **Coin Level** (each chain's own standard format) and **Wallet Level**, which exports in one animated multi-frame QR code: account xpubs for **four Bitcoin script types** — `p2wpkh` (bc1q), `p2tr` (bc1p), `p2sh-p2wpkh` (3) and `p2pkh` (1) — an EVM xpub, a TRON xpub, and **three Solana addresses** (standard, trust, legacy; Ed25519 derivation is hardened, so a watch-only wallet cannot derive one of them from another). The format is specified in [docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md). Bitcoin exports an Account XPUB by default, and TRON can export any address index from 0 to 2³¹−1.

- **Scan** — the whole scan card is tappable, and a request can also be pasted or imported from a file. The review page runs summary → risk warnings → signing wallet → full fields → request fingerprint, with the risk acknowledgement and the Sign button pinned to the bottom. Every signature takes that wallet's own password.

  Any address a request would authorize — an `approve` spender, a `setApprovalForAll` operator, an EIP-712 spender or verifying contract — is compared offline against 1,720 bundled **known public contracts**. A hit names the deployment (`Permit2 — Uniswap · infra`); a miss says plainly that it is not on the list, and an unlisted spender or operator also raises the risk level (see [docs/KnownContracts.md](docs/KnownContracts.md)). Being listed identifies a deployment. It does not mean the request is safe.

  NFT transfers, approvals and marketplace orders (Seaport, LooksRare, Blur, and Solana's Metaplex, Bubblegum and Core) get their own review cards: the NFT contract or mint, the complete token ID, "you give / you receive / someone else receives", and red warnings for the usual phishing shapes.

- **Activity** — on-device signing records, grouped by date. BitTool Signer does not broadcast transactions. Each record shows both **input and output**: the input is the request as it was signed, handed back to the engine for a fresh review when opened, so the fields match the review page and the request fingerprint has to agree; the output is the signature produced, which can be shown again as a QR code for the other wallet to scan, exported as a file, or expanded as raw text. Only the last 25 records keep their raw payloads; older ones keep the summary. Everything stored is public data, in files with full encryption protection, excluded from backups.

- **Settings** — App Lock, appearance and interface language (21 languages; Arabic lays the whole interface out right to left), Networks, Tokens & Contracts (an offline registry of 3,350 tokens across 10 networks plus the 1,720 known public contract addresses, both searchable), compatibility notes listing the wallets that have been checked under "can sign by QR" and "watch-only", the air-gapped device guide, Open Source (what is published, the repository address, this build's own information, third-party notices), and the version and operating entity.

- First run: welcome → three onboarding pages, shown once, preserving the create-or-import intent → then four steps to create (generate → back up the phrase → fill the blanks back in order → set a password) or two to import (enter and validate → set a password).

- Backing up the recovery phrase: the top switches between **Words** and **QR**. Words, the QR code and the recovery cards are all concealed by default and reveal on a tap, then re-conceal immediately on a screenshot, a move to the background, or a screen recording. The QR code is a plaintext phrase QR, meant only for moving to another device of your own in private; it cannot be saved or shared. **Recovery Cards** splits the phrase across three cards, each hiding a third, so any two reconstruct it — with a warning at 12 and 15 words that a single card gives away too much. **Security Tips** collects the warnings in one place. The check at the end conceals most words and leaves 4–5 blanks to fill in order from a shuffled set.

- Importing accepts all 10 BIP39 languages: English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Italiano, Čeština, Português. The language is detected and the checksum validated as you type; Spanish and French work without accents, Chinese without spaces. When one set of words is valid in two languages — which would produce two different wallets — the app asks which language the backup was written in. Candidate words appear above the keyboard, and phrase QR codes (including the app's own) and SeedQR are both accepted.

Network icons for BTC, ETH, BNB Chain, Arbitrum, Base, TRON and Solana, and the app icon itself, are redrawn as vectors (see [design/Brand.md](design/Brand.md)). The remaining token icons come from verified official sources and CoinMarketCap listing images, deduplicated by content and packed into a single file (see [docs/TokenRegistrySources.md](docs/TokenRegistrySources.md)).

## The security model, in brief

- Every wallet is encrypted on its own: PBKDF2-HMAC-SHA256 at 600,000 iterations, then AES-256-GCM, then an outer layer under a device key that never leaves this device's Keychain. Vault format 2 authenticates the stored header bytes as they are.
- The Terms of Use and Privacy Policy (v1.1, English) are bundled and read inside Settings › About and from the welcome page. No browser is opened.
- Addresses and pairing read only the local public index; they never unlock the seed. That file is authenticated with HMAC-SHA256 under a Keychain key, and if it is tampered with or missing the wallet enters Repair, which rebuilds it after one password entry.
- Scan → parse locally → match the wallet by public key → fix the signing task → enter the password per task. There is no manual choice of signing wallet, no global unlock and no password-free signing.
- The BIP39 seed is computed natively with CommonCrypto and then handed to the engine. Every engine operation that touches a secret or untrusted input runs in a fresh JavaScriptCore context, and Release builds expose only a fixed allowlist of operations.
- App Lock is optional and off by default. It protects the interface and never authorizes a signature. It re-authenticates on a cold launch, or after 120 seconds in the background — a timer that keeps counting while the device sleeps. Moving to the background immediately clears passwords, risk acknowledgements and any revealed phrase.

The full account is in [docs/Security.md](docs/Security.md).

## Documentation

- [Implementation status, test results and the fix log](IMPLEMENTATION_STATUS.md)
- [Security model and permission boundaries](docs/Security.md)
- [Reproducible builds: verifying a published build](docs/Reproducible-Build.md)
- [Export compliance determination](docs/Export-Compliance.md)
- [Protocols, export semantics and compatibility evidence](docs/Compatibility.md)
- [Engine API and tests](engine/README.md)
- [Token registry sources and selection](docs/TokenRegistrySources.md) · [wallet icon sources](docs/WalletLogoSources.md)
- [Release acceptance](docs/Release-1.0.0.md)
- [Brand and icons](design/Brand.md)

Older reports under `docs/validation` are kept as history and do not describe the current state.
