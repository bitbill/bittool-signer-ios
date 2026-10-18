# Interface acceptance screenshots, 21 September 2026

Source: iPhone 16 Pro simulator, iOS 18.6; genuine UI automation screenshots. Wallets and
signatures are isolated public test vectors — no user wallet and no funds. Light and dark pages
were each checked individually, and no QR code or address has been redrawn by hand.

| Page | Screenshot | What it verifies |
|---|---|---|
| All wallets | [Light](Wallets-Light.png) | Eight-wallet total, stable IDs, Connect / Addresses |
| BTC pairing | [Light](Bitcoin-Pairing-Light.png) | Single-sig / multisig, path order, public key QR |
| Address browsing | [Dark, BTC](Addresses-Dark.png) / [Light, SOL](Solana-Addresses-Light.png) | Full addresses wrapping per character, public browsing, three Solana paths |
| Transaction review | [Light](Message-Review-Light.png) | A real message, with independent High risk / Decoded locally states |
| Signature result | [Light](Signature-Result-Light.png) | A public ETH signature response; not an indication that anything was broadcast |
| App Lock | [Dark](AppLock-Dark.png) | Face ID cancelled state, retry, and the wallet-password fallback |
| Welcome | [Light](Welcome-Light.png) | Local logo, slogan, create and import entry points |
| Invalid input | [Light](Invalid-Recovery-Light.png) | An invalid recovery phrase reports clearly and cannot be continued past |
| Full recovery phrase | [Concealed](Recovery-Hidden-Light.png) | Words are not shown by default |

Horizontal path options and vertical content both scroll; a screenshot shows the viewport at
that moment and does not imply that anything outside it is missing. Dynamic type, VoiceOver,
further screen sizes and real camera quality all remain device acceptance items.
