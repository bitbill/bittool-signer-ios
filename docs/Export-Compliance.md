# Export compliance: why `ITSAppUsesNonExemptEncryption = NO`

This document records one thing: **the technical basis for that determination.**
The next person filling in the App Store questionnaire should not have to guess —
check the code against the table below instead.

## The declaration

```
ITSAppUsesNonExemptEncryption = NO
```

Meaning: **this app either does not use encryption, or uses only encryption exempt
from export compliance documentation requirements.**

> Build 1 of 1.0.0 shipped this key as `YES`, with no recorded reason.
> It was changed to `NO` after checking the code item by item — see below.

## The common misconception

"It's a crypto wallet, so obviously it uses encryption, so answer YES."
**That is wrong, because signing is not encryption.**

Export control — US EAR, Category 5 Part 2, ECCN 5A002 — covers **confidentiality**.
**Digital signature, hashing and authentication are explicitly outside its scope.**
The primary work of an offline signer falls entirely on the uncontrolled side.

## What this app actually uses

| Function | Where | Implemented by | Controlled? |
| --- | --- | --- | --- |
| Digital signatures, ECDSA secp256k1 / Ed25519 | JS engine | Own (`@noble/curves`) | **No** — digital signature is an excluded function |
| Hashing: SHA-256/512, Keccak, RIPEMD-160 | JS engine | Own (`@noble/hashes`) | **No** — a hash is not encryption |
| BIP39 phrase → seed (PBKDF2-HMAC-SHA512) | Native + `@scure/bip39` | CommonCrypto / own | Key derivation, not confidentiality |
| Password → key (PBKDF2-HMAC-SHA256, 600,000 rounds) | Native | **Apple CommonCrypto** | OS-provided |
| **Vault encryption at rest (AES-GCM)** — the only place anything is encrypted | Native | **Apple CryptoKit** | OS-provided |
| Public index authentication (HMAC-SHA256) | Native | **Apple CryptoKit** | Authentication, not confidentiality |
| Randomness | Native | **Apple Security (`SecRandomCopyBytes`)** | OS-provided |

Two independent grounds for the exemption, either one sufficient:

1. **All confidentiality encryption comes from iOS itself.** The only place in this app
   that turns data into ciphertext is the wallet vault, using Apple's AES-GCM from
   CryptoKit. The app implements no cipher of its own.
2. **What the app does implement itself is limited to signatures, hashing and key
   derivation**, none of which is controlled as encryption.

## How to recheck it yourself

```sh
# The native layer only uses Apple's crypto frameworks and implements no block cipher.
git ls-files '*.swift' | xargs grep -h '^import' | sort -u | grep -iE 'crypto|security|common'
#   -> CryptoKit / CommonCrypto / Security

# The JS engine bundled into the app contains no confidentiality cipher at all.
for p in aes gcm chacha salsa secretbox; do
  printf '%s: %s\n' "$p" "$(grep -o -i "$p" BitToolSigner/Resources/signer.js | wc -l)"
done
#   -> all zero
```

That last check is the decisive evidence: the engine bundles its own cryptography
library, yet **not one symmetric cipher is linked into it** — because the engine never
encrypts anything. It parses, hashes and signs.

## Scope

This is a record of technical facts, **not legal advice**. The final answer on the
submission questionnaire is for you and your counsel to confirm. If the conclusion
ever differs — because an end-to-end encrypted sync feature is added, say, which
really would introduce a confidentiality function — **the key in the project must be
changed back at the same time.** Never let the project setting and the questionnaire
answer disagree.
