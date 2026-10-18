# Reproducible builds: checking that the app you installed is this source

BitTool Signer is an offline signer. Its entire value rests on **not having to trust us**.
So this document is written to be honest about the boundary: **what you can verify, what
you cannot, and why.**

## Start with what cannot be verified

**An App Store binary cannot be reproduced byte for byte.** That is not laziness on our
part; it is how the platform works:

1. The package you upload is **re-signed by Apple**, so its signature data differs from
   anything you build locally;
2. the executable delivered to a device carries **FairPlay encryption**
   (`LC_ENCRYPTION_INFO_64` in the Mach-O, `cryptid=1`), and the same code downloaded at
   different times or under different accounts yields different ciphertext;
3. Xcode and the Swift compiler make no determinism guarantee themselves — paths,
   timestamps and symbol ordering all end up in the output.

Anyone claiming an App Store app can be verified byte for byte is mistaken.
**So do not try to compare executable hashes. That route does not work.**

## Now the part that can be verified — which happens to be the part that matters

Inside an `.ipa`, **only the main executable is FairPlay-encrypted; resource files are
not**. And all of BitTool Signer's transaction parsing, risk assessment and signing logic
lives in a single resource:

```
BitToolSigner.app/signer.js
```

This is one JavaScript file bundled from `engine/src/`, and **it can be taken straight out
of the package installed on your own phone and compared, byte for byte, against the result
you build from source.** In other words: the code that decides *what you are actually
signing* is verifiable.

> The native Swift layer handles the interface, the Keychain and encrypted storage. Its
> source is published too, but it can only be reviewed by reading, not by comparing
> hashes. That division is exactly the boundary this document is about.

## Step 1: rebuild the engine from source

You need Node.js (see the `engines` field in `engine/package.json`; the exact version used
for a release is recorded in that release's `release-manifest.json`).

```bash
git clone https://github.com/bitbill/bittool-signer-ios
cd bittool-signer-ios
git checkout v1.0.0            # or whichever tag or commit you are checking
cd engine
npm ci --ignore-scripts        # exact versions from the lockfile, no install hooks
npm run build
shasum -a 256 ../BitToolSigner/Resources/signer.js
```

`--ignore-scripts` is not optional: a dependency's install hook can alter the build output,
and turning hooks off is what guarantees you get the code the lockfile describes.

The hash should match `engineBundle.shippedSHA256` in `release-manifest.json`, and the hash
recorded in `engine/bundle-manifest.json` in the repository. The `signer.js` in the
repository is a committed artifact and `npm run build` overwrites it in place — so if
`git status` is still clean after building, **the committed artifact and the result of
building from source are identical**, which is itself a verification:

```bash
cd .. && git status --porcelain BitToolSigner/Resources/signer.js   # no output = identical
```

## Step 2: extract signer.js from the app you installed

No jailbreak required.

1. On a Mac, use **Apple Configurator**, signed in with your Apple ID, to download the app
   as an `.ipa` (Apple Configurator → device → Add → Apps; the downloaded package lands in
   `~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Assets/TemporaryItems/MobileApps/`);
2. an `.ipa` is a zip:

```bash
unzip -o BitToolSigner.ipa -d extracted
shasum -a 256 extracted/Payload/BitToolSigner.app/signer.js
```

Compare that with the hash from step 1. **If they match, the transaction-parsing code
running on your phone is exactly what this source builds.**

## Step 3: check the whole source snapshot

`scripts/release-manifest.sh` produces a release manifest:

```bash
scripts/release-manifest.sh
```

It requires a clean working tree — otherwise the manifest would name a state nobody else
can check out — and then writes:

- `SHA256SUMS.txt`: the hash of **every file tracked by Git**, in a fixed order, so two
  manifests can be compared with a plain `diff`;
- `release-manifest.json`: the commit, the file count, the manifest hash, and the engine
  artifact's hash **as rebuilt after a clean dependency install in a throwaway copy of that
  commit** — so what is published is a hash that *reproduces*, not one that merely happens
  to exist on the release machine;
- `clean-install.log` and `clean-build.log`: the full output of that rebuild.

To check it, run the same thing yourself on the same tag and compare the two files:

```bash
diff release/SHA256SUMS.txt their-SHA256SUMS.txt
```

## Step 4: do not stop at hashes — read the code

A hash only proves that the source you are looking at is the source that was packaged. It
proves nothing about whether that source is safe. These are the places worth your time:

| What to look at | Where |
| --- | --- |
| Transaction parsing and risk assessment (whether the summary you see is correct) | `engine/src/bitcoin.js`, `evm.js`, `solana.js`, `tron.js` |
| Signing plans and signing bytes (what you are actually signing) | `engine/src/resolver.js`, `engine/src/keys.js` |
| Recovery phrase encryption at rest | `BitToolSigner/Core/VaultCrypto.swift`, `WalletVault.swift` |
| Password authorization and session invalidation | `BitToolSigner/Models/AppStore.swift` |
| The claim that it never goes online | grep the repository for `URLSession`, `Network`, `CFNetwork`, and run `otool -L` on a build product (neither CFNetwork nor Network.framework should appear) |

The review text the engine produces is **English only**, deliberately: that text is covered
by the request fingerprint and has to be reproduced byte for byte when the engine is
rebuilt, so it cannot change with the interface language. The interface translates it at
the last moment, as it draws (`BitToolSigner/Models/ReviewText.swift`).

## What this document does and does not promise

**It promises**: published source, locked dependencies, a reproducible engine artifact, and
a verification path you can walk end to end without relying on us.

**It does not promise**: the absence of unknown defects. Matching hashes mean the code was
not substituted. They do not mean the code is free of bugs. Weigh your funds at risk
against your own review, not against this document.
