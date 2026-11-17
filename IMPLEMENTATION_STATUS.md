# BitTool Signer implementation status · Revision 17 (17 November 2026)

This log records what was changed in each round, what was tested, and — just as importantly —
what has **not** been verified. Newest revisions first. Version **1.1.0 (2)**, iOS 17 minimum,
with Liquid Glass on iOS 26 and native fallbacks on iOS 17 and 18. Version 1.0.0 (1) was uploaded
to App Store Connect from tag `v1.0.0`; this round is the first change on top of it.

The app has not shipped, so each round adopts the new storage format directly and does not
migrate older development data. The product decisions (D01–D28) of the original Revision 1
specification were all retained in Revision 2; Revision 3 changed several of them at the user's
request: Bitcoin now exports an Account XPUB by default, the leaf-public-key mode is gone, TRON can
export any address index, and Ownbit and its display rules were removed. That specification was a
pre-implementation work order whose decisions this log supersedes in places, so it is no longer
published here; it remains in the Git history from the initial commit.

## Revision 17 (17 November 2026): the independent 1.1.0 audit, and three more from the Android port

**Where they came from.** Two sources, fixed together and synced to Android as one bundle:

1. An independent audit of this repository at 1.1.0, written from a third party's point of view
   (not published yet; see `SECURITY.md`): no Critical or High, six Medium. Five
   are fixed here. M-02 (Bitcoin change may sit at any derivation index of the wallet, the identity
   path included) is left as it is by product decision.
2. A brief from the Android port (`docs/qa/ios-fix-brief-2026-11-17/` in the Android repository),
   written after two audits of Android 1.1.0. Its M-01 is the audit's M-03 below. BTS-02 and BTS-11
   are in the shared engine; §4 is this app's own unlock delay.

| ID | What was wrong | Fix |
| --- | --- | --- |
| M-01 | About half of the engine's warnings, HIGH RISK ones included, reached people in English in all 20 languages. The Revision 15 check scanned source literals and missed warnings held in constants, returned by helpers, or numbered (`Order 2: …`) | `ReviewText` now draws every kind of engine text through one entry point, `render(english, as: kind)`, with kinds for phrases, headlines, Details labels and sentences. Labels are translated part by part (`Instruction 4 · Amount (USDC)`); numbered sentences keep their number and severity marker; values stay exactly as the engine wrote them. Templates moved to `ReviewTextTemplates.swift`: 23 → **96**, four of them with slots whose values are engine text in turn. A numbered sentence that does not translate in full is drawn exactly as the engine wrote it. Coverage is now measured on the engine's **real output**: `engine/test/support/review-text-corpus.mjs` runs the whole engine suite and records every warning, refusal, title, action, headline and label it produces (`engine/test/fixtures/review-text-corpus.json`); `ReviewTextCoverageTests` draws each through all 20 bundles and fails on any English fallback. Headlines that are only values (amounts, NFT IDs, roots) are exempt |
| M-03 (Android M-01) | A Solana dust transfer was the headline and the Activity summary of a transaction that also ran an instruction this device cannot decode, which can move anything the wallet controls | Beside a transfer, burn or permission change, an undecoded instruction makes the action `Sign Transaction`, the headline name both (`Moves funds and runs undecoded instructions · review each below`), the first warning a HIGH RISK one, and the summary end in ` and N undecoded instruction(s)`. Marketplace programs keep their own headline, but no longer cover another program's undecoded instruction |
| M-04 | A Safe transaction with no chain ID showed `Safe: Send` with no amount or recipient, at normal risk | The amount (`native coin`, 18 decimals) and recipient are shown; the yellow note became a HIGH RISK warning that the signature is valid on every chain the Safe exists on; risk is high |
| M-05 | A Safe MultiSend folded a 1,000,000 USDC transfer into `(+1 more)` behind three revokes | `decodeCall` reports each call's effect; transfers, DELEGATECALLs, undecoded calls and grants are always named before revokes, and more than eight of them become a count (`10 calls: 9 transfers, 1 other · review each below`) |
| M-06 | An EIP-7702 delegation of the whole account read `Send 0 ETH` | Title, action, headline, counterparty (`Delegate contract`) and summary describe the delegation; with value as well, both are named |
| BTS-02 | A burn beside a permission change was counted as a transfer: `Remove token authority (Mint tokens) and 1 transfer`, under `Changes permissions and moves funds` | Four kinds of effect, each named when another is present: permission change, burn, transfer, undecoded instruction. Six new fixed headlines (`Changes permissions and destroys assets · review each below` and its combinations), two new first warnings, and a summary that names the burn (`… and burn 1000000000 raw units`) and counts only real transfers. A burn beside transfers alone keeps its own headline, which already names both. Risk, the burn warnings and the acknowledgement are unchanged |
| BTS-11 | A Metaplex TransferV1 whose metadata, edition or token-record account came from a lookup table was refused outright: the table placeholder never equalled the derived PDA, so `INSTRUCTION` was thrown before the raw-bytes fallback | Each of the four comparisons first checks for a placeholder and throws `LOOKUP_TABLE`, so that instruction falls back to raw bytes and HIGH RISK. A wrong account that is in the message is still refused. No other `===` comparison in `solana.js` refuses a placeholder |
| §4 | The failed-password delay was a date. An offline phone's date is whatever its owner sets: forward skipped every delay, a clock reset locked the wallet for the gap | The delay runs on `CLOCK_MONOTONIC_RAW`, the clock App Lock already uses (counts sleep, cannot be set, restarts at boot). The `.attempts` file also stores `attemptUptime`; time left is `attemptUptime + delay − now`, never more than one delay. An attempt from an earlier boot is counted from the current boot, so a restart can only lengthen the wait; a file written by 1.0.0 runs one full delay from the first try. `retryAfter` is still written, so an older build can read the file, but is no longer read. `docs/Security.md` updated |

**Catalogue.** `engine/data/interface-strings.json` 1207 → **1538** keys (+331, none removed): Details
labels and their numbered keys, display actions and headlines (including the seven actions
Revision 16 listed as never catalogued), warnings, the 47 refusals the tests and the fuzzing reach
most, counterparty labels, unit words. All 20 languages written; `.lproj` files regenerated.

**Engine bundle.** SHA-256 `f774f1f2b0614e7faec0eeac30ee216bd351ae4f2a326846a057b489a7c01a96`,
**1,203,208** bytes (was `40670e04…`, 1,198,633). Rebuilt in an isolated directory: byte-identical,
`bundle-manifest.json` too. The network and `eval` patterns occur 0 times. Handoff
`source-snapshot.json` and `SHA256SUMS.json` regenerated; pairing and signing fixtures unchanged.

**Tests.** Engine **265/265** (was 257): `headline-consequence.test.mjs` (5, new), two new in
`solana-authority-headline.test.mjs`, one new in `solana-lookup-accounts.test.mjs` (the BTS-11 role
matrix, each signed after acknowledgement and the signature verified), and updated expectations in
`nft-solana.test.mjs` and `nft-evm.test.mjs`. The Android repro prints what its brief expects. Swift
**192 tests in 26 suites**, all passing: `ReviewTextCoverageTests` (new; every engine text in 20
languages) and two clock tests in `SecurityTests`. The Connect QR timing test that failed once under
a machine load of about 200 passed in this run.

**Not verified in this round.** The new strings were written by AI and not read by a native speaker
of any language. The lookup-table, burn and Safe cases are synthetic; nothing was put on a chain.
The unlock delay was tested with an injected clock only: sleep, a changed date and a restart were not
tried on a device, and that the clock counts sleep rests on Darwin's `clock_gettime(3)`. UI tests
were not rerun, and nothing was tested on a physical device. **Known gap:** Solana burn headlines
(`Destroys 1000000 tokens · 1 other transfer below`, `Destroys 2 NFT in 2 burns`) still show in English: the
coverage test treats `Destroys <amount> …` as a value, but these carry words. Translating them needs
a template slot for amounts with unit words, and Android must follow, so it is left for a later
round. Still open from the 1.1.0 audits: M-02 (above), L-2 (one damaged vault file hides every
wallet), L-3 (`docs/Security.md` is still titled v1.0.0), and the two product questions from the Android audits (raising the delay past five minutes,
a list of common passwords).

## Revision 16 (16 November 2026, night): eight findings from an external 1.1.0 audit, and two of ours

**Where they came from.** An external AI audit of the Android 1.1.0 workspace raised six findings,
and the Android port found two more while doing Revision 15. Every one of them lives in code this
repository owns — the shared engine, its tests, `docs/Wallet-Pairing-v2.md` and the string catalogue
— so they are fixed here and Android syncs the result byte for byte. Each was reproduced on this
workspace before it was fixed; the reproduction for each is in its test. Two more are from this
repository's own 1.1.0 audit (not published): L-1, and a constraint on
the BTS-10 fix that the Android brief did not state.

| ID | What was wrong | Fix |
| --- | --- | --- |
| §7.1 | Five HIGH RISK warnings — both lookup-table warnings, the lookup-table instruction warning and both EIP-7702 delegation warnings — stayed in **English in every language**. The engine writes `transaction's`; the catalogue keys, written by hand in Revision 15, read `transaction’s`, and the template regex matched neither to the other | `ReviewText.Template` matches either apostrophe to either, values captured from the original text. A new test runs the **real engine** and reads its warnings through the **ja and zh-Hans** bundles: falling back to English fails it. The Revision 15 test ran in English, where a fallback passes, so it could not have caught this |
| §7.2 | `ReviewText.substitute` returned the translation with `%@` still in it when its placeholders did not fit | Returns nil; the caller shows the engine's English. `sentence(_:translate:)` takes the lookup as a parameter so a test can hand it a broken translation |
| BTS-02 | A one-lamport SOL transfer became the headline and the Activity summary (`0.000000001 SOL`) of a transaction that also approved an unlimited token delegate, re-owned a token account, removed a mint authority or reassigned an account | A change of control — SPL Approve and ApproveChecked, SetAuthority (to an address or to none), System Assign, Stake Authorize, Metaplex and Bubblegum delegates — now leads `display` and `summary` ahead of burns and transfers and names the new holder as the counterparty. When funds also move, the headline names both (see R-1). Headlines are fixed phrases so they can be translated |
| R-1 | **Introduced by the first BTS-02 fix and found re-reviewing it.** Leading with the change of control *instead of* the amount opened the mirror image: 1,000 SOL out beside an approval of zero tokens read "Approve delegate — Lets another address spend these tokens", with no amount, "also transfers funds" as the last of five warnings and "… and 1 transfer" in Activity. Before the fix that transaction's headline was "1000 SOL" | When both are present the headline names both — "Changes permissions and moves funds · review each below" — and neither alone; the **first** warning says to check every transfer as carefully as the permission change; the Activity summary keeps the amount for a single transfer ("… and 1 transfer of 1000 SOL"). Tested in both instruction orders |
| BTS-02 | Stake **Authorize** and **AuthorizeChecked** were not decoded at all: shown as raw bytes | Decoded, with a separate HIGH RISK sentence for the withdraw authority (every lamport, both authorities) and the stake authority |
| BTS-07 | The pairing page and `Wallet-Pairing-v2.md` said the identity signature lets a receiver "tell a real pairing from a copied QR code", "closes" replay, and proves possession of "the public keys it exports". It signs one fixed sentence, deterministically: a photograph is a valid code, and only the BIP44 legacy account is bound | Page text replaced (20 translations); the spec now says what is proved and adds **What the signature does not prove**, requiring receivers to have the person compare the first address of *every* account. The protocol is unchanged — binding the whole body, or a challenge, needs a BitTool Wallet release and is a product decision |
| BTS-08 | A self-revocation signed for a nonce at which it cannot apply read `normal`, `fullyDecoded`, "restores a plain account", with no acknowledgement — identical to one that does apply | EIP-7702 increments the sender's nonce before the list, and each applied entry increments its authority's. For this wallet's own entries that nonce is known offline, so an entry that cannot take effect is **refused**, grants and chain-0 entries included. Another account's revocation now says it applies only at a nonce this device cannot see, and is at least `partiallyDecoded` |
| BTS-08 | Whether an entry was this wallet's depended on the request naming its sender; a request without `address` or `from` could not be held to the rule | `parseEVM` takes the matched signer from the plan (`resolveSigningPlan`, `signPlanTask`, `signEVM`); it never enters the request hash or the signing bytes. This was I-6 of the 1.1.0 audit |
| BTS-09 | A type 4 transaction with an empty authorization list read `normal`; one with no destination was signable after acknowledgement. EIP-7702 makes both invalid | Both refused, whatever is acknowledged |
| BTS-10 | An associated-token-account instruction whose token account, owner or mint came from a lookup table refused the **whole transaction** with an untranslated `Unknown letter: "["` and no error code — the shape of Jupiter and Stargate transactions, which is what Revision 13 added lookup tables for. The 1.1.0 audit had called this fail-closed and correct; for safety it was, for function it was not | Reviewed, not refused: shown with its placeholders, `partiallyDecoded`, and a sentence saying ownership cannot be checked. Program accounts from a table make that instruction raw bytes. `pubkey()` refuses a placeholder with code `LOOKUP_TABLE`, and one instruction that fails that way falls back to raw bytes instead of refusing the transaction. The Metaplex recipient check and the transfer-hook check say what they cannot check |
| BTS-10 constraint | Not in the brief. The recipient fold (`t.movement.to = x.owner`) trusts that an ATA it finds was proven; the PDA check was what made that true. Skipping the check for table accounts but still recording the ATA would let a review read "to <respectable owner>" while the tokens go to whatever the table holds | An unproven ATA is never recorded for folding. A regression test builds exactly that transaction and asserts the claimed owner never appears as the recipient |
| L-1 | The engine required the risk acknowledgement only for partially decoded or opaque requests; a fully decoded HIGH RISK request (an unlimited approval, a burn, a message) signed without it. The interface asked; the engine did not check | The engine refuses a HIGH RISK request that is not acknowledged. Eleven engine-test calls and one native test now pass the acknowledgement the review screen would ask for — the native one through `TransactionReview.requiresAcknowledgement`, the app's own rule |
| BTS-06 | The bundle test returned early, and passed, when `signer.js` was missing | It fails. The path literal is unchanged, because Android's sync rewrites that exact string |

**Also:** the engine bundle's banner said `BitTool Signer 1.0.0`; it says 1.1.0 (I-5 of the audit).

**Strings.** 29 added and 2 removed in all 20 languages (1180 → **1207** keys): ten engine
sentences, two templates, sixteen display phrases (actions, headlines, the `Delegate` label) and
the new pairing-page paragraph. Removed: the "delegates nothing" warning (that transaction is now
refused) and the old pairing paragraph. Templates: 21 → **23**. New template English, for Android's
`TEMPLATES`:

- `Authorization %@ cannot take effect: it is signed for nonce %@, but this wallet’s nonce will be %@ when it is applied.`
- `%@ asks to remove the code delegation on %@. It takes effect only if that account’s nonce is %@ when this transaction runs, which BitTool Signer cannot check offline.`

**Engine bundle.** SHA-256 `40670e04574b40d3999265570a8e0481082ca1ac1cd60e5dea1bd4a7f8fba40f`,
**1,198,633** bytes (was `a163698b…`, 1,194,055). Rebuilt in an isolated directory from the pinned
dependencies: byte-identical. `fetch(`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `sendBeacon`,
`importScripts`, `eval(` and `new Function(` occur 0 times. Handoff `source-snapshot.json` and
`SHA256SUMS.json` regenerated; the pairing fixtures did not change.

**Tests.** Engine **257/257** (was 242): `solana-lookup-accounts.test.mjs` (6, new),
`solana-authority-headline.test.mjs` (5, new), four new and one rewritten in
`evm-7702-and-chains.test.mjs`. The Android repro (`docs/qa/ios-fix-brief-2026-11-16/repro.mjs` in
the Android repository) now reports what its brief expects: nonce 5 refused, nonce 6 unchanged,
empty list refused, the lookup-table ATA reviewed. Swift **186 tests in 25 suites** (was 183), run against the final bundle. UI: the 18 functional tests
and the pairing-states screenshot passed (19, no failures, the known `typeText` flake included); that
run used the bundle before the R-1 change, which alters only Solana headlines no UI test reaches. The
pairing page was checked by screenshot with the new paragraph.

This round was re-reviewed in a report that supersedes the first review. Neither review is
published yet.

**Not verified in this round.** No EIP-7702 transaction was put on a chain, so the nonce rule rests
on the specification, not on an observed skip. No real Jupiter or Stargate transaction was decoded;
the lookup-table tests are synthetic. The 28 new strings were not read by a native speaker of any
language. Nothing was tested on a physical device. Still open from the 1.1.0 audit: L-2 (one damaged
vault file hides every wallet), L-3 (`docs/Security.md` describes 1.0.0), and seven engine display
actions that were never in the catalogue (`Sign Transaction`, `Burn` and five more), so they show in
English.

## Revision 15 (16 November 2026, late): the engine's own sentences, in all 21 languages

**The engine spoke English.** Its field labels, titles and display actions were already translated
at draw time by `ReviewText`, but the two kinds of sentence that carry the meaning were not: the
**warnings** on a review card, and the **refusals** that appear when a request is rejected. A
Japanese or Russian user saw a fully translated card with an English red callout — and worse, when
the Signer refused a code, the refusal was the *only* text on screen, in English.

**398 engine sentences, in all 20 non-English languages.** The string list went from 782 keys per
language to **1180**:

| What | Keys | Notes |
| --- | --- | --- |
| Review warnings | 76 whole sentences + 17 templates | Everything `warnings.push`, `warnings.unshift` or a literal `warnings` array can hold |
| Engine refusals | 282 | Every whole-sentence `check()` message across `protocols.js` and `src/*.js` |
| Host refusals | 11 | `SigningEngine.swift`'s own messages, which surface the same way |
| Refusal templates | 4 | The ones the engine builds around a value |
| Compatibility page | 2 rewritten | See below |

**How a sentence with a value in it is translated.** `ReviewText.sentence(_:)` tries an exact
lookup first, then each registered `Template` — the English sentence compiled into an anchored
regular expression with `(.+?)` where the value goes. The captured values are substituted into the
translated string with `String(format:)`, so a language that needs another order says so with
positional specifiers (`%1$@`), which five of them do for "X of Y". A sentence that matches nothing
is shown in the engine's own words rather than mangled. 21 templates are registered.

**Severity is still read from the English.** `RequestReviewView` calls `isSevere(warning)` on the
engine's original text, never on the translation: "HIGH RISK" is a marker in the source string, so
no translator can change a callout's colour, and `SigningEngineError` keeps its untranslated
`message` for the tests and the code path while `errorDescription` returns the translated one.

**Two warnings are assembled from a branch**, not written whole: `'The leaf owner' + (payer ? ' or
payer' : '') + ' does not sign…'`. A template would have left " or payer" in English inside an
otherwise translated sentence, so both complete forms were registered as exact keys instead.

**Three guards, so this cannot rot.** `engine/test/warning-coverage.test.mjs` (new, four tests)
scans the engine source for every warning literal and every lone-literal `check()` message,
resolves the JavaScript escapes, keeps the ones that are whole sentences, and asserts each has a
key — with a floor on how many it found, so the scan going blind fails too. A second test asserts
every translation keeps the placeholder count its English has; a third pins the assembled forms and
fails if the engine rewords a fragment. On the Swift side `BitToolSignerTests/ReviewWarningTests.swift`
(new, nine tests) covers the fallback, template matching, multi-value order, a value that looks like
a pattern, every template matching its own sentence, no two templates claiming the same sentence, a
reordering round trip, a real translation loaded from the zh-Hans/ja/de/ru bundles, and the live
engine's warnings never leaving a `%@` behind.

**What the scan caught.** An earlier, looser filter (`s[0] === s[0].toUpperCase()`, which is true
for a space or a period) let six concatenation fragments through as if they were sentences;
tightening it to `/^[A-Z]/` surfaced two templates that genuinely had no translation. The
lone-literal test for refusals first matched `'This message is ' + bytes.length + ' bytes. …'` as a
whole string, because the regex's `.` could cross the closing quote; it now scans for the matching
quote and requires it to be the last character.

**Three findings from the Android review, all real, all fixed here.**

1. **Settings › Compatibility was out of date in two rows.** Solana still said "Address lookup
   tables are not supported offline" — untrue since Revision 13 — and EVM still listed only
   Legacy / EIP-2930 / EIP-1559, with no mention of EIP-7702 or of every chain being signed. Both
   rows were rewritten and translated; the two stale keys were removed from the string list and
   from all 20 translation files. These sentences live in the iOS-maintained catalogue, so Android
   picks them up by re-syncing rather than by writing its own.
2. **`AddressFormatter.short` was abbreviating things that are not addresses.** With Revision 13 a
   `display.counterparty` can be a lookup-table placeholder — `[lookup table <pubkey> · entry 3]` —
   and the Activity record ran it through `short(leading: 6, trailing: 6)`, producing
   `[looku…try 3]`. It is now abbreviated only when `AddressFormatter.looksLikeAddress` says so,
   which is the same distinction `AddressText` already makes between an identifier and prose.
3. **The wallet-level QR format line** already mentions the identity signature on iOS (Revision 12);
   nothing to do here. Android's copy of that sentence is its own string and is listed in the
   hand-off prompt.

**Tests.** Engine **242/242** (was 238): four new in `warning-coverage.test.mjs`. Swift
**183 tests in 25 suites** (was 174 in 24): `ReviewWarningTests` is the new suite. The 21 UI tests
were not re-run in this round — nothing they assert changed, but that is an assumption, not a
result.

**Also in this round: the password field was invisible on the pairing page.** On *Pair Wallet ›
Wallet Level*, a wallet from before 1.1.0 asks for its password, and the field read as a line of
grey body text — nothing said it accepted typing. The cause was not that page: **every other call
site drew the box itself** (`.padding(14).background(Palette.card / .raised, …)`), so the chrome was
the caller's job and `ConnectView.swift:518` was the one that forgot.

The box now belongs to `PasswordField`, and is on by default, so a call site that does nothing is
correct. `chrome: .plain` opts out in the four `Form` rows, where the grouped-list row is
iOS's own idiom for a field and reads as one. Everywhere outside a `Form` the field draws its box:
the four single-field sites — App Lock, the recovery-phrase unlock, the signing password sheet and
the pairing page — had their hand-rolled boxes removed, and the two pairs that shared one card with
a `Divider` between them (Set a Password, and the BIP39 passphrase) became two boxes in a spaced
stack. That card had the same failing as the pairing page, just less obviously: a divider between
two paragraphs of grey placeholder. One rule now: inside a `Form`, the row is the field; outside
one, the outline is.

It is an **outline**, not a fill. The call to action directly beneath is a capsule that stays greyed
out until something is typed, so a grey filled field above a grey filled button is two lozenges with
nothing to say which one takes text; both `tertiarySystemFill` and `secondarySystemFill` were tried
on screen and neither read as an input. An outline's fill is whatever is behind it — the card on the
pairing page, the page itself during setup — so one treatment works on both backgrounds and in both
appearances.

Verified by screenshot through `ScreenshotTour`, not by eye over the code: `15f-wallet-level-password`
before and after. No test can catch this class of bug — the UI tests found and typed into the field
the whole time it was invisible — which is why the fix is structural rather than a fifth copy of the
box.

**Not verified in this round.** The translations are the work of this round and have not been read
by a native speaker of any of the 20 languages; the tests prove that every sentence has an entry,
that the entry loads, and that it keeps its placeholders — not that it reads well. Nothing here was
tested on a physical device. No refusal was triggered on screen in each language; the proof that a
refusal is translated is the key being present and `errorDescription` going through
`ReviewText.sentence`, which `ReviewWarningTests` exercises directly but not through the error path.

## Revision 14 (16 November 2026): every EVM chain, 60 of them named, and EIP-7702

**Every EVM chain ID is signed now.** The engine used to refuse any chain outside a list of eight,
which meant every other legitimate network was simply unusable. The list was never a safety boundary — it is a display registry,
holding a network's name and its native ticker so a fee can be denominated and a token identity
looked up — and refusing an unnamed chain protected nobody: the chain ID is inside what gets
signed (EIP-155), so a signature made for one chain is valid on that chain and on no other.

**60 EVM chains are named, up from 8.** Naming a chain is what lets a fee be denominated and a
token identity looked up, so the eight that were there covered eight networks and left every other
one anonymous. 52 more were added: the major rollups (Linea, Scroll, zkSync Era, Blast, Taiko,
Mode, Zora, World Chain, Unichain, Ink, Soneium, Swellchain, Zircuit, Abstract, Lisk, BOB, Manta
Pacific, Boba, Polygon zkEVM, Arbitrum Nova, MegaETH) and the major alternative L1s and sidechains
(Mantle, Celo, opBNB, Berachain, Sei, Monad, Sonic, Ronin, Kaia, Cronos, Core, Flare, Rootstock,
Moonbeam, Moonriver, Astar, Metis, Kava, Gravity, Immutable zkEVM, Oasis Sapphire, ApeChain,
Etherlink, Plume, Bitlayer, Merlin, Fantom, Fraxtal, Shibarium, Degen, Aurora, Harmony).

Every name and native ticker was taken from the `ethereum-lists/chains` registry rather than typed
from memory, which caught three things memory had wrong: chain 999 is Wanchain Testnet in that
registry and not Hyperliquid, chain 1514 is Data Network and not Story, and Fraxtal's native
currency is FRAX rather than frxETH. Where the registry is ambiguous — Hyperliquid's mainnet has
no uncontested entry — the chain was left unnamed rather than guessed at: an unnamed chain still
signs, a mislabelled one misleads. All 60 have an 18-decimal native currency, which is what the
fee display assumes.

**Naming a chain is not knowing its tokens.** The bundled token registry still covers only the
original eight, so a token on any of the 52 resolves to nothing and reads as an unregistered
contract — which is the truth, and is tested.

**A fee is only called high where there is a reference for normal.** The high-fee warning compares
against a per-chain ceiling, and a ceiling is a claim about what the native currency is worth —
something an offline device cannot know. The eight calibrated chains keep theirs, anything else
denominated in ETH takes the same 0.05 ETH ceiling Ethereum uses, and opBNB takes BNB Smart
Chain's. On the remaining 31, whose native currency has no ceiling here, **no claim is made**: the
maximum fee is shown and the review says plainly that it could not be judged. Guessing 31
thresholds from token prices that move would have produced false alarms on the cheap ones, and a
warning that cries wolf is worse than none.

An unnamed chain is still signed and **said to be unnamed**: it is called `Chain <id>`, its native
unit is `native units` rather than a guessed ticker, no token or contract on it resolves against
the bundled registry (so every address reads as unregistered, which is the truth), and a notice
says all of that and tells the person to check the network in the wallet that built the request.
The risk level rises to `warning` where it would otherwise be `normal`. **Chain ID 0 stays
refused**: that is an unprotected transaction, which replays on every network, and is a different
thing from a network this device cannot name.

**EIP-7702 (transaction type 4) is supported.** Type 4 was refused outright, which locks the
device out of every smart-account application now building on it. It is read now, and the
`authorization_list` is where the whole risk lives, so that is what the review is about:

- Each entry says that the code at some address may act as an account's own code from then on.
  The account — the *authority* — is **not stated in the entry**; it is recovered from the
  entry's own signature, which is the only way to tell whose account is being handed over.
- When the recovered authority is the wallet being asked to sign, the warning says so in those
  words: this hands your own account to that contract, which can then move everything in it on
  every later transaction until the delegation is replaced.
- `chainId` 0 inside an entry means the delegation applies on **every** EVM chain, and gets its
  own warning. An entry for some other specific chain is a mismatch and is refused.
- Delegating to `0x0` is the opposite operation — it removes a delegation — so it is described
  as restoring a plain account, is not labelled HIGH RISK, and does not trip the acknowledgement
  gate. A list that both revokes and grants is still a grant.
- A non-empty list is always `high` risk and never `fullyDecoded`: the delegate's code is
  on-chain and this device cannot read it, so signing needs an explicit acknowledgement.

The transport gate had to be opened too: an `eth-sign-request` of dataType 4 (EIP-2718 typed
transaction) previously accepted only transaction-type bytes 1 and 2, so a 7702 payload was
refused before anything could read it. Type 3 (blob) is still refused there, as before.

**Tests.** The engine suite is **238/238** (was 230). New: `engine/test/evm-7702-and-chains.test.mjs`
— the wallet's own account being delegated and the wording that goes with it; another account's
delegation not being described as this wallet's; a chain-0 entry called out and a wrong-chain
entry refused; a revocation not dressed up as a grant, and a mixed list still treated as one; an
empty list; a full sign that recovers to the signing wallet with the inner authorization intact
and the unsigned hash unchanged; twelve of the newly named chains resolving to the right
name and ticker, an unnamed one signing under a numeric name with a notice, a token on a newly
named chain still reading as unregistered, the fee being judged on a calibrated chain and
explicitly not judged on an uncalibrated one, chain 0 still refused; and a type 4 payload travelling through
the UR transport while a blob payload still stops there.

**Not verified.** No real EIP-7702 transaction from a live smart-account wallet has been through
this, and nothing has been signed on any of the 52 new chains on a device — both are exercised only
by fixtures built here. The chain data is as good as the `ethereum-lists/chains` registry was on
16 November 2026; a chain that renames itself or relaunches will go stale silently.
**BitTool Wallet cannot produce a 7702 request** — its own EVM builder
(`AirGapRequestBuilder.evmTransaction`) hardcodes `type: 2` — and by the owner's decision that is
left as it is for now, so a delegation reaching BitTool Signer has to come from another wallet or
an application that builds the request itself.

## Revision 13 (16 November 2026): Solana address lookup tables, and a transaction sent as a message

**Reported from the outside.** A user posted that a Stargate bridge claim on Solana failed in
BitTool Signer with *"Solana messages must be 1–1024 bytes"*, and added that a plain swap did not
work either. Both turned out to be real, and they are two separate problems.

**1. Address lookup tables are now read instead of refused.** Until this round a version 0
message carrying any address lookup table was rejected outright, on the grounds that the addresses
a table supplies live in an on-chain account an offline device cannot read. That reasoning is
sound and the conclusion was wrong: Jupiter, Stargate and essentially every current Solana
application build v0 transactions with lookup tables, so the rule did not make signing safer, it
made Solana signing **impossible** — which is what the second half of the report was about.

A table is now parsed and the transaction is signable, with everything it costs stated plainly:

- The tables are listed in full (account, writable and read-only entry counts) and so is the
  number of accounts they supply. All of that is in the message, so all of it can be shown.
- Solana resolves accounts as static keys, then every table's writable entries, then every
  table's read-only ones. Each supplied account becomes `[lookup table <account> · entry <n>]`.
  Square brackets are outside the base58 alphabet, so a placeholder can never read as an address.
- An instruction whose **program** comes from a table is shown as raw bytes and nothing else:
  with no program identity there is nothing truthful to say about what it does.
- An instruction whose **accounts** include supplied ones still decodes — the amount is in the
  instruction data, not in the table — but it says how many of its accounts could not be shown.
- The transaction can never read as `fullyDecoded`, and its risk level is always `high`, so
  `signPlanTask` demands an explicit acknowledgement before it will sign. The leading warning
  says how many accounts came from how many tables and that any of them could be a recipient the
  person did not intend.

Signer matching is unaffected: Solana cannot load a signer through a lookup table, so required
signers are always static keys.

The first run of this on a device showed the placeholder being cut into four-character groups in
the headline "To" box — `AddressText` groups every value it is handed, so that two identifiers can
be compared character by character, and on a sentence that only made it unreadable. It now shows
anything containing whitespace as ordinary text, which is right for every caller, not just this
one.

**2. A transaction sent through the message path now says so.** Solana message signing has no
mandatory domain prefix, so a signature over transaction bytes *is* a usable transaction
signature. Two checks already caught that — a 1024-byte ceiling and a first-byte test — but they
reported a byte count, which tells nobody what went wrong. The parser now recognises the shape
first and names it: a bare transaction message, or a **whole serialized transaction** (a
signature array followed by its message), with the advice that the sending wallet should use a
transaction request. The size limit remains as a backstop and now states the limit and the actual
size. EVM and TRON were audited for the same class of problem and do not have it: both
domain-separate messages from transactions (`\x19Ethereum Signed Message:` / EIP-712 `\x19\x01`,
`\x19TRON Signed Message:`), so a message signature can never be replayed as a transaction one.

**3. The hole that produced the report (BitTool Wallet).** `WCRequestChecks.isSolanaTransactionMessage`
recognised only a bare transaction message. A dApp calling `solana_signMessage` with a whole
serialized transaction slipped past it — the leading signature array makes the header parse read
`keyCount` out of a signature byte and fail — and was forwarded to BitTool Signer as a message,
where it hit the byte-count refusal. The guard now strips a leading signature array and re-checks.
BitTool Wallet also no longer refuses v0 transactions on the BitTool Signer path, and its Solana
bridge can split a serialized v0 transaction into the message that gets signed without a versioned
transaction class, which the bundled web3.js does not have. A hot wallet still refuses v0: there
is nothing in that bundle to put a signature back into.

**Tests.** The engine suite is **230/230** (was 224). New: `engine/test/solana-lookup-tables.test.mjs`
— six tests covering a table being read, named and gated; a supplied account never being shown as
an address; a supplied program being shown as bytes and never guessed at; the acknowledgement gate
firing and the resulting signature verifying against the message; five malformed table shapes
refused; and the message path naming a bare transaction, a serialized transaction and an oversized
message instead of measuring them. `engine/test/engine.test.mjs` had its ALT case rewritten from
"refuses" to "reads but gates", with a table-free control that still reads as fully decoded. On
the wallet side `SecurityAuditFixTests.solanaTransactionMessagesAreRecognised` gained the
serialized-transaction cases, signed and unsigned, legacy and v0.

**Not verified.** No real Stargate or Jupiter transaction has been through this end to end: the
tests use synthetic v0 messages built here. What a lookup-table-heavy swap looks like on the
review screen — how many placeholder rows a real Jupiter route produces, and whether that is
readable rather than merely honest — has not been seen on a device. The option of having the
online wallet send the resolved table contents, so the Signer could show them clearly marked as
claimed-but-unverified, is **not** implemented: it needs a `sol-sign-request` extension and is a
protocol decision.

## Revision 12 (15 November 2026): wallet-level pairing v2 and the KH v2 wallet-identity signature

**The pairing code now proves who made it.** A wallet-level QR used to be unauthenticated: anyone
who photographed one could replay it, and the receiving wallet had no way to tell a genuine
pairing from a copy. `bittool-signer-wallet` is now **version 2** and carries `khSig` and
`khEpoch` — a Bitcoin message signature over the fixed sentence `OwnbitAuth:v2:epoch=<N>` made
with the wallet's identity key. The receiving wallet verifies it on the device, offline, against
the code's own public keys, and the backend verifies the same signature against the extended
public key the wallet registers. v1 is no longer produced, and the reference decoder refuses it.
The full format is in [docs/Wallet-Pairing-v2.md](docs/Wallet-Pairing-v2.md); v1 stays in the
repository as history and as something to test refusal against.

**The identity key is `m/44'/0'/0'/0/1000000000` — not BIP84, and this was worth stopping over.**
The specification for this round said BitTool Wallet registers the **BIP84** receive-branch xpub
(`m/84'/0'/0'/0`) as its `extendedKeys`, which would have put the identity key under BIP84. The
code says otherwise: BitTool Wallet iOS registers the **BIP44** receive-branch xpub, both for a
hot wallet (`derived.mainPubkey` in `CreateWalletConfirmPasswordView`, pinned to
`btc[.legacy].receiveXpub`, purpose 44) and for a watch wallet paired from BitTool Signer
(`identityXpub` in `BitToolSignerWalletService`, BIP84 only as a fallback for the pre-2026-10-18
single-account QR). Since the backend derives the identity key as the non-hardened child
`AUTH_INDEX` of whatever is in `extendedKeys`, a BIP84 signature would have been rejected with
−140 on every call, and the vectors published for the other three platforms would have been
wrong. Two further confirmations: Ownbit's shipped implementation signs under
`w.mainExtPublicKey` at `<seedTypePath>/0/1000000000`, and its own published HD vector is at
`m/44'/0'/0'/0/1000000000`. The owner confirmed BIP44; the specification's sentence is a drafting
slip.

**The signature is produced once and stored, never recomputed on demand.** A wallet created or
imported on 1.1.0 signs its identity at that moment, from the seed already in hand, and the
signature is written beside the authenticated public index under the same HMAC and device
protection — so opening the pairing page never asks for a password. A wallet saved by 1.0.0 has
none: the Wallet Level page shows a one-time password field (`WalletIdentityAuthorizationView`)
instead of a QR, explains why, and says that the recovery phrase and password do not change.
Cancelling leaves that wallet without a wallet-level code; Coin Level is unaffected. Repairing a
wallet and resetting its password both already decrypt the seed, so they fill a missing signature
in silently rather than leaving a second prompt behind. Rebuilding the public index without a
signature **drops** any stored one: the two come from the same seed and must never disagree.

**Only one sentence can ever be signed.** The new engine operation `signKhV2` takes an epoch and
nothing else — there is no message parameter, so an attacker who reaches the engine cannot use it
as an oracle for arbitrary text. A test passes `path` and `message` alongside a valid request and
asserts the output is unchanged. The signature is verified against its own key before it is
returned, again against the wallet's public index before it enters a payload, and the host checks
the `walletKeyId` the same engine call reports before filing it next to a wallet's keys.
`signKhV2` is on the release allowlist but deliberately **not** on the warm-context list: it
receives a secret, so it runs in a fresh JavaScriptCore context like every other signing path.

**Published vectors, verified three ways.** `docs/kh2_bittool_vectors.json` holds epochs 1 and 2
for the public `abandon … about` phrase; the other three BitTool platforms must reproduce those
bytes exactly. Before any of this was written, a from-scratch pure-Python reference (secp256k1,
RFC 6979, BIP32, BIP39, the Bitcoin message digest and base58check, all by hand) was checked
against **all seven** of Ownbit's published `kh2_vectors.json` vectors, including the high-S
negative case, and reproduced every one byte for byte. The engine's output then matched that
reference — and, because this is the same phrase and path, it is byte-identical to Ownbit's own
`HD-abandon-m/44h/0h/0h/0/1000000000` vectors for both epochs. Three independent implementations,
one answer.

**Tests.** The engine suite is **224/224** (was 210). New: `engine/test/kh2.test.mjs` — six tests
covering Ownbit's four published vectors, the high-S copy that must not verify but must still fold
to the same `kh2`, BitTool's own two vectors byte for byte, RFC 6979 determinism, phrase-and-seed
equivalence, a BIP39 passphrase giving a different identity, the Bitcoin Signed Message digest
recomputed independently from the rule, the public-data-only identity derivation, nine malformed
signature shapes, and the fixed-text restriction. `engine/test/wallet-pairing.test.mjs` was
rewritten for v2 and gained a test that refuses a missing, malformed, wrong-epoch, malleated,
re-headered or other-wallet signature, and that v1 and v3 are both refused like any other version.
On the Swift side, `BitToolSignerTests/WalletIdentityTests.swift` covers the stored value's
validation, the engine reproducing the published vector through the real bundled runtime and
ignoring an injected path and message, a new wallet signing at creation and surviving a reload, a
1.0.0 wallet having no code until the right password is entered (and a wrong one changing
nothing), repair filling the signature in, and a rewritten index dropping a stale signature.

**Payload size.** 1561 → **1666** canonical CBOR bytes, SHA-256
`cc911414877a3b544b90f6c8ac794c76197015b60c00002d12577608473894ef`, five animated frames of 717
characters (was four of 831). The engine bundle is
`6679136fc523914b970c147dfacd44ff9275a3f82be265b987c2323521583217`.

**Also in this round, carried over from the commits after the 1.0.0 tag** (they are part of what
1.1.0 ships): the scan-page status strings and the App Lock unlock button were localized, BitTool
Wallet is described as running on Android as well as iOS, and the three findings of the Android
security review that live in the shared engine were fixed.

**Two stale "v1" labels on screen.** The Pair page's *Format* line and the Compatibility page's
*QR format* line both still named `bittool-signer-wallet v1` after the payload became v2. Neither
is localized — both are `Text(verbatim:)` literals naming a wire format — so neither showed up in
the string export, and the only test that touched one asserted the old text. Both now say v2, the
Compatibility line also mentions the identity signature, and both are pinned by UI assertions
(`testConnectAndAddressesUsePublicDataOnly` and `testSettingsReferencePagesAndGuide`) so they
cannot drift again. The internal `.v1` suffixes in Keychain service names, storage keys and HMAC
domain labels are untouched: changing those would orphan existing device keys.

**Eight new interface strings**, translated into all 20 non-English languages and regenerated
through `scripts/write-localizations.py` (790 keys each). Release notes for all 21 languages are
in [docs/Release-Notes-1.1.0.md](docs/Release-Notes-1.1.0.md).

**Not verified in this round.** The receiving side: no BitTool Wallet build yet reads a v2 code,
so the end-to-end pairing — scan, local verification, `registerKhV2`, watch wallet created — has
not been exercised against a real server or a real wallet build. The published vectors are the
contract that stands in for it until then. The rotation path (`khEpoch` ≥ 2) is implemented and
unit-tested but has no server to rotate against: the backend only has epoch 1 today. Nothing here
was tested on a physical device.

## Revision 11 (18 October 2026, late): the three open R2 findings, password reset, delete confirmation

**1. All three open findings of BTS-SEC-2026-1018 R2 were reproduced and fixed.** R2 confirmed the
earlier F-01 to F-04 fixes were effective, but rated F-01 only "partially fixed": that round had
corrected the immediate value and left the recursion and the second entry point alone.

| ID | Severity | Problem | Fix |
| --- | --- | --- | --- |
| R2-01 A | HIGH | A `DELEGATECALL` child inside MultiSend always had `moves = 0n`. But a delegatecall **executes in the Safe's own account context**, so a CALL inside it spends the Safe's money. "Delegatecall into another MultiSend that pays 40 ETH" therefore showed nothing at all on the main card, and that branch did not count as a spending call, so the headline's three-item truncation could hide it | `decodeCall` now returns `forwards`: **how much native currency this call's body pays out of the executing account** (zero for every ordinary method; `moved` for MultiSend). The parent then does `moved += op ? inner.forwards : innerValue` — a CALL counts only the value handed to it, since what the target then does is the target's own money and must not be double-counted, while a DELEGATECALL counts what its descendants actually spend. The headline's "must be described" set widened from spending calls to spending-or-delegating calls |
| R2-01 A' | HIGH | When a delegatecall's body cannot be decoded, the amount is genuinely **incomplete**, but the interface did not say so | Such branches are counted, `decodeStatus` drops to `partiallyDecoded`, and a HIGH RISK warning says the amount shown is incomplete because N DELEGATECALL branches run with the Safe's own balance and their bodies are not fully decoded. If it cannot be determined, say so rather than implying zero |
| R2-01 B | HIGH | The `execTransaction` entry point passed `a[1]` (the value) straight to `decodeCall` **without ever reading `a[3]` (the operation)**. The SafeTx typed-data path had been corrected long before, so the two entry points reached opposite conclusions about the same bytes: one said "100 ETH was paid", the other "nothing moved" | The same rule as SafeTx: `delegated ? 0n : a[1]`, with the ignored value given its own field and a warning. Both entry points now say the same thing |
| R2-02 | LOW | The relative fee rule compared `fee*2 > outputTotal`, and `outputTotal` **includes change**. Change is money returning to your own wallet; it was never sent. So an identical payment with an identical fee went quiet as soon as a large change output was added | The rule was extracted into one function, `highFeeWarning(fee, payment)`, shared by the parser and the resolver. The parser cannot know which outputs are change, so it uses `outputTotal`; the resolver recomputes against the real payment **after change has been verified from the signing wallet's own public keys**. Change only makes `payment` smaller, so recomputing can **add** the warning and never withdraw one. When every output returns to the wallet (consolidation or self-send) there is a separate line: the fee is the whole cost of the transaction |
| R2-02' | LOW | The same root cause had a second site: `review.summary` ("Send 1.0002 BTC") was also computed from `outputTotal`, and that is **the line the history and the signature receipt show** — the main card had long shown only the real payment, while the history overstated it | The resolver recomputes the summary once change is verified, consistent with the card, and writes "every output returns to your wallet" rather than "Send 0 BTC" when nothing leaves |
| R2-03 | LOW | The Solana burn summary always took `burns[0]` as the principal amount. "Burn 0.000001 USDC, then burn 1,000,000 USDC" showed 0.000001 on the main card, and so did "a small burn plus a 1,000 SOL transfer" | Burns are grouped by **mint, symbol and decimals** and totalled: several burns of one mint merge into a single total ("Destroys 1000000.000001 USDC in 2 burns"). **A single headline amount is shown only when one number describes the whole transaction** — different mints, or a transfer beside a burn, means no headline amount, and the headline enumerates the effects instead ("Destroys A + B · 1 other transfer below"). Every burn keeps its own exact HIGH RISK warning |

Both informational items were fixed too: **I-01**, the history labelling TRON's energy budget as a
network fee (the review page had distinguished `feeKind` for some time; the history had not caught
up), and **I-02**, `RepairWalletSheet` clearing its password draft only when the sheet disappeared,
where it now clears as soon as the app is suspended, like every other password field.

Regressions: [engine/test/audit-bts-2026-1018-r2.test.mjs](engine/test/audit-bts-2026-1018-r2.test.mjs),
16 cases, each finding covered both for the failing scenario and for "existing correct behaviour
must not regress". The R2-01 case "a CALL's descendants are still the target's money" exists
specifically to prevent over-correction: counting descendant spending into a CALL would
double-count and overstate what leaves the wallet.

> R2-01 exposed a structural problem worth recording. One of `decodeCall`'s three `return`
> statements — the opaque contract call — omitted `forwards`, so `moved += undefined` threw
> "Cannot mix BigInt and other types": **a crash while drawing the review page**, before any
> authorization, the same class of fault as F-03. Besides adding the field, the accumulator is
> now written `inner.forwards ?? 0n`. A missing field should make an amount display as
> incomplete, not take the app down.

**2. A forgotten password can be reset with the recovery phrase** (replacing "delete the wallet and
import it again").

- The password screen's hint now reads: **if you forget this password, import this recovery phrase
  again to set a new one.**
- If, on import, the phrase and any BIP39 passphrase are **identical** to a wallet already on the
  device, the password step switches to reset mode: the title and button become Reset Password, the
  "if you forget" hint disappears — this screen is now doing the thing it describes — and the
  wallet to be reset is shown along with a note that only the password changes. The completion page
  says Password Reset and does not offer to pair a wallet.
- New: `WalletVault.resetPassword(id:mnemonic:passphrase:newPassword:)` re-encrypts using the
  existing device key and header metadata, so **the wallet keeps its name, creation date, addresses,
  paired wallets and activity history** — exactly what delete-and-reimport loses. The failed-attempt
  counter is also cleared: someone who has just proved ownership with the phrase should not be left
  queueing behind a password they have forgotten.
- The proof is the phrase, not the old password: **whoever holds the phrase already controls the
  funds**, so this grants nothing extra and simply does "re-import" in place. `AppStore.resetPassword`
  re-derives the public index and compares `walletKeyId` before writing anything — otherwise this
  would be a way to overwrite wallet B's encrypted record using wallet A's phrase.

**3. Deleting a wallet asks for biometrics only when App Lock is on.** The condition used to be
`biometry.isAvailable` (does the device have Face ID); it is now `isEnabled && biometry.isAvailable`
(does this app use Face ID). Turning App Lock off is a statement that this app does not use Face ID,
and deleting a wallet should not put back the prompt the person just declined. The footer text
follows the same branch, and the password remains the step that actually authorizes the deletion.

**4. The delete confirmation toggle now says "I confirm I want to delete this wallet"** (previously
"I have a backup of the recovery phrase"). The red callout above it already explains that only the
recovery phrase can restore the wallet; what the toggle needs to confirm is **the deletion itself**.

Tests: the vault reset covers "the old password stops working, the phrase and passphrase come back
unchanged, the name and creation date survive, and no second wallet appears", "a weak password and a
non-existent wallet are both refused without leaving a trace", and "a reset clears the failed-attempt
counter". `AppAccessController` covers "no biometric prompt while App Lock is off, a prompt while it
is on, and none again after it is turned off". A new UI test,
`testImportingAnExistingPhraseResetsItsPasswordInPlace`, walks the whole path: import the fixture
wallet's own phrase → the page becomes Reset Password and the "if you forget" hint is gone → set a new
password → Password Reset → the wallet list still holds exactly one wallet with the same name → the
old password no longer opens it and the new one returns the same recovery phrase.

The string list grew from 765 to **773 entries** (10 added, 2 removed), with all 20 non-English
languages filled in and validated by `scripts/write-localizations.py`.
## Revision 10 (18 October 2026, evening): the four findings of the second review, the fee rule, and assorted fixes

**1. All four findings of BTS-SEC-2026-1018 were reproduced and fixed.** All four were real, and two
of them were regressions introduced by Revision 9 itself:

| ID | Severity | Problem | Fix |
| --- | --- | --- | --- |
| F-01 | HIGH | A Safe `DELEGATECALL` does not transfer `value` (the Executor hands value to `call` only), but the code displayed it as an amount paid; MultiSend had the same fault, and because the headline listed only three calls, a real transfer in the fourth or later would vanish from the main screen | `evm.js`: a `DELEGATECALL` passes `0n` to `decodeCall`, and the ignored value gets its own field and a warning; MultiSend accumulates `moved` only for a `CALL`; and **any call spending native currency is always in the headline**, so truncation can no longer hide a transfer |
| F-02 | HIGH | SPL Token Burn and BurnChecked were written only into Details, never into `movements`, and never raised the risk level. So "burn 1,000,000 USDC and send 1 lamport" showed as 0.000000001 SOL on the main card, with no risk acknowledgement required | `solana.js`: a burn enters `movements` as a first-class destructive effect, **a burn always leads the summary** (the same rule as a Bitcoin burn), `riskLevel='high'` forces acknowledgement, and a HIGH RISK warning is emitted |
| F-03 | MEDIUM | `ReviewText.shortDecimal` carried by computing `Int(whole) + 1`. When the integer part of a fee equals `Int.max` that traps on overflow, **crashing while the review page is being drawn** — before anything has been authorized | `ReviewText.swift`: the whole part carries as a string and is never parsed into an `Int`. A request can name any fee the engine can represent, and the renderer should not depend on amounts being reasonable to stay alive |
| F-04 | LOW | Revision 9's Bitcoin burn fix wrote `note: undefined`; `stable()` refuses `undefined`, so it threw "Expected a plain JSON object." before the plan was even hashed, making **every transaction containing a burn output unsignable** | `bitcoin.js`: an absent optional field simply omits the key. The regression test goes through the full `resolveSigningPlan`, not just `bitcoinDisplay` |

Regressions: [engine/test/audit-bts-2026-1018.test.mjs](engine/test/audit-bts-2026-1018.test.mjs)
and `BitToolSignerTests/ReviewTextTests.swift`.

> F-04's lesson is worth recording: testing `bitcoinDisplay`'s return value cannot see the problem,
> because `JSON.stringify` silently drops `undefined`. The test has to go all the way through
> `resolveSigningPlan`.

**2. The Bitcoin high-fee rule.** The old rule — over 0.01 BTC, or over 1% of the inputs — fired on
almost every small payment, because a small transaction's fee is naturally a large share of it, and
the result is training people to tick the box without reading. The new rule: **over 0.01 BTC, or
(over half the amount being sent and over 0.0001 BTC)**. That 0.0001 BTC floor exists precisely to
keep small payments quiet. See
[engine/test/bitcoin-fee-warning.test.mjs](engine/test/bitcoin-fee-warning.test.mjs).

**3. A "Contact us" section on the About page**: the operating entity and `support@bittool.com`. The
address is copyable text rather than a `mailto:` link — the app opens neither a browser nor a mail
client.

**4. Simplified the wrong-password message**: "The password is incorrect, or the encrypted wallet has
been modified." became "The password is incorrect." AES-GCM cannot distinguish a wrong key from
tampered ciphertext, so the original wording was literally accurate, but for someone who simply
mistyped it is just alarming. Tampering still fails closed; it just no longer gets its own wording.

**5. The camera reappeared after tapping Done on a finished signature (a Revision 9 regression).** The
scan button's "already handled" marker lived in `ScanHomeView`'s `@State`, and that view is destroyed
when a request arrives and rebuilt once signing finishes, so the `@State` reset to zero and the camera
opened again. The marker moved to `AppRouter`, which survives the whole flow, and is consumed by
`consumeScanRequest()`. The regression test
[BitToolSignerTests/ScanRequestRouterTests.swift](BitToolSignerTests/ScanRequestRouterTests.swift)
walks "request → review → result → Done" and requires that none of those four steps opens the camera.

## Revision 9 (18 October 2026): 21 languages, localized engine text, animated pairing QR, Connect renamed Pair, wallet directory

**1. Languages completed to 21.** Added uk, es-419, it, pt-BR, pt-PT, pl, id, tr, th, vi and fil — 11
new — joining the existing en, zh-Hans, zh-Hant, ja, ko, ru, de, fr, es and ar for 21 in total,
matching BitTool Wallet's language count. pt-BR/pt-PT and es/es-419 were each written out separately
rather than mechanically substituted: the two Portuguese variants differ systematically in
palavra-passe vs senha, ecrã vs tela, ficheiro vs arquivo and in progressive forms ("A descodificar…"
vs "Decodificando…"), and the two Spanish variants in billetera vs cartera, monto vs importe and
Configuración vs Ajustes. `knownRegions` was extended to 22 entries, including Base.

**2. The engine's review text is now translated too.** The engine (JavaScript) still writes English
only — that text is what the request fingerprint covers and what a rebuilt engine must reproduce byte
for byte, so it cannot vary with the language. Translation happens **at the last moment, as the text
is drawn**: the new [BitToolSigner/Models/ReviewText.swift](BitToolSigner/Models/ReviewText.swift)
provides `phrase` for whole phrases (Details field labels, `display.action`, counterparty labels),
`label` for field names carrying a bracketed unit ("Amount (USDC)" translates only the stem), and
`headline` for titles shaped as a fixed phrase plus an engine-supplied value, such as
"Method 0x3593564c". When no translation exists it falls back to the engine's own English, so a label
added to the engine later shows in English rather than disappearing. The string list
[engine/data/interface-strings.json](engine/data/interface-strings.json) grew from 548 to **742**
entries: 558 from Xcode's extraction plus 184 static field names, display actions, counterparty
labels, review titles and resultTypes pulled out of the engine source.

**3. Fee ceilings show at most 8 decimal places.** The review page used to print
`0.000396834604360128 ETH` verbatim. `ReviewText.shortDecimal` cuts to 8 places and **rounds up**
(adding one to the last kept digit when anything dropped was non-zero, carrying into the whole part
if needed), because this is a "no more than" ceiling and rounding down would understate it. Details
still carries the exact value.

**4. Leaving the scan page turned the interface dark.** `QRScannerView` used
`.preferredColorScheme(.dark)` to give the camera interface dark material, but that is a
**window-level** preference: when the app's appearance setting is "follow the system" the root passes
`nil`, meaning "no preference", so after the modal closed there was no preference to override it and
the window stayed dark. Changed to `.environment(\.colorScheme, .dark)`, which affects only the scan
page's own view tree and leaves the window alone.

**5. Interface text that had been missed.** `QRScannerView`'s `title` and `hint` became
`LocalizedStringKey` ("Scan Request", "Scan Recovery QR" and two hint lines had been plain `String`,
so they were always drawn as written); the recovery-phrase input's status line ("12–24 words · any
BIP39 language", "1 word", "%lld words", "Unknown: %@") moved to `String(localized:bundle:)`; and the
address detail title `%@ address #%lld`, Solana's `%@ account` and the `Sign with %@` button were
given the same treatment.

**6. Regressions.** [BitToolSignerTests/ReviewTextTests.swift](BitToolSignerTests/ReviewTextTests.swift)
covers falling back to English when no translation exists, preserving the engine-filled value in a
prefix translation, and the fee truncation's carry (`0.999999999 → 1.00000000`) alongside the cases
it must leave alone (no fraction, no unit, already short). The new wallet-level pairing shape is
asserted in `engine/test/wallet-pairing.test.mjs` and `BitToolSignerTests/SessionTests.swift`: an xpub
for each of the four script types, three Solana addresses, no `m/48'`, and at least two frames.

**7. The wallet-level QR became animated and carries every address type.** It used to export only
Bitcoin BIP84 (bc1q) and a single Solana address. `accounts` now carries **four Bitcoin account
xpubs** — `p2wpkh` (bc1q, m/84'), `p2tr` (bc1p, m/86'), `p2sh-p2wpkh` (3, m/49') and `p2pkh`
(1, m/44') — plus EVM and TRON xpubs and **three Solana addresses** (standard, trust, legacy;
Ed25519 derivation is hardened, so a watch-only wallet cannot derive one from another and all three
must be sent). The two `m/48'` multisig profiles are excluded: multisig needs every cosigner's public
key and the threshold, which is what the Coin Level cosigner export is for. The payload therefore grew
from 755 bytes to **1,561**, which does not fit in one QR code, so it became a **multi-frame animated
`ur:bytes`** (400-byte fragments; the test wallet is 4 frames of 831 characters, with the fragment
length taken as `min(400, ⌈payload/2⌉)` to guarantee at least 2 frames). The cap was raised from 1,024
to 4,096 bytes. The verification section now lists the first address of **every exported account**:
four Bitcoin, EVM, TRON and three Solana — nine rows.

> **BitTool Wallet must be updated to match**: the `accounts` array went from 4 entries to 7, a
> decoder must read each entry by its `chain` and `script` fields rather than by index, Solana entries
> gain a `profile` field, and all frames must be collected before decoding. The protocol document
> [docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md) is updated, and the test vectors and SHA-256
> regenerated.

**8. Connect was renamed Pair.** Buttons and titles changed from Connect to Pair — `Connect Wallet` →
`Pair Wallet`, `Connect Bitcoin` → `Pair Bitcoin`, `Connect a Wallet` → `Pair a Wallet` — along with
the two sentences of body text that refer to the button by name. Three reasons: first, the text that
explains the feature already said pairing (`Pairing level`, `wallet pairing`, "Pair BitTool Signer
with a watch-only wallet…") and only the button said Connect, so the app contradicted itself; second,
connecting is precisely what an offline signer **never** does, and the app elsewhere says it never
goes online while the button said "Connect"; third, Connect Wallet in the dApp world means attaching
your wallet to a website, which is the opposite direction from this (exporting public keys to a
watch-only wallet), so borrowing the term invites a misreading.

> Only user-facing text changed. Accessibility identifiers (`connect.level`, `connect.copy`,
> `wallet.connect.*`), type names (`ConnectView`, `PairingLevel`) and code comments were left alone to
> avoid a pointless diff. Terms with a different meaning, such as `Network connections` in Settings
> and "the app never connects", are unaffected.

**9. Duplicate addresses in the pairing verification list (a Revision 9 regression).** After item 7
raised the exported accounts from 4 to 9, the four Bitcoin rows on the page all showed the same bc1q
address and the same path, and so did the three Solana rows. The engine was in fact returning nine
distinct addresses; the fault was `WalletPairingPayload.Line`'s `var id: String { chain }` — one chain
used to mean one row, and with four rows per chain `ForEach` saw duplicate ids and drew only the first
row's content. The fix: the engine's `verify` entries gained a `profile`
(`native`/`taproot`/`nested`/`legacy`, and `standard`/`trust`/`legacy` for Solana) and `id` became
`chain + "/" + profile`. Each row now also names which account it is — "Bitcoin · Taproot",
"Solana · Trust" — reusing the `AccountProfile` names from the Coin Level selector so both pages say
the same thing; the heading changed from "check the first address of each chain" to "of each account",
since a chain now has more than one.

> `profile` appears only in `verify` (interface data), not in the CBOR payload, so the protocol's test
> vectors and SHA-256 are unchanged and BitTool Wallet is unaffected by this item. The regression
> assertions are in `SessionTests`: the nine rows' ids, addresses and paths must all be pairwise
> distinct, and the Bitcoin and Solana profile order must be correct.
## Revision 8 (17 October 2026): welcome page bottom spacing, staying on iOS 17

**1. The welcome page's legal links sit closer to the bottom.** `bottomActionBar` gained a
`bottomPadding` parameter (still 8 by default) and the welcome page passes 0. An action bar that ends
with a Terms of Use / Privacy Policy line does not need the padding a button does. Measured on an
iPhone 16 Pro at @3x: the gap below the links went from 130 px to 106 px, that is **43.3 pt → 35.3 pt**,
exactly the 8 pt removed. **The remaining ~34 pt is the system home indicator safe area; compressing
it further would draw under the gesture bar, so it stays.** The other three call sites (the create
flow, the signature result page and the welcome page's onboarding branch) are unchanged.

**2. iOS 17 remains the minimum.** The Revision 7 assessment's conclusion — do not lower it — was
adopted, no code changed, and the assessment is kept in
[docs/DeploymentTarget.md](docs/DeploymentTarget.md) in case the question is reopened.

**3. Restored a deployment target Xcode had changed on its own.** During the iOS 15 assessment
`IPHONEOS_DEPLOYMENT_TARGET` was temporarily set to 15.0 and restored from a backup after building;
afterwards Xcode, with the project open, took it upon itself to change the two **project-level**
configurations to `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)` while the four target-level ones stayed
at 17.0. The symptom was iOS 17 and 18 simulators disappearing from the destination list, leaving only
26.4 and 27.x. Restored to 17.0; `project.pbxproj` is byte-identical to its pre-assessment state and
the simulator list is back to normal.

## Revision 7 (17 October 2026): default Pair level, Activity input and output

**1. Tapping a chain opens Coin Level.** The Bitcoin / Ethereum & EVM / TRON / Solana rows on a
wallet's detail page now open **Coin Level** with that chain already selected — choosing a chain is
itself a coin-level choice. Revision 4's "default to Wallet Level" is kept for the entry points that
**do not** name a chain: the Connect button on a wallet card, "Connect a Wallet" on the creation
completion page, and the Wallet Level row on the detail page, all three of which now use the
`connectWallet` route. One omission was fixed in passing: the wallet-level route had not been wired to
the prefetched QR code, and both routes are now wired, so switching from a chain page to Wallet Level
is also complete on the first frame.

**2. Activity shows input and output.** Each signature now records **the request that was signed** (the
canonical JSON the engine reviewed) and **the signature produced** (QR frames plus export text), so the
detail page gained two sections:

- **Input**: a few key lines — operation, amount, counterparty, fee — an "All Decoded Fields" link to a
  full page (reusing the review page's summary card, contract notice, warnings and Details), and the
  expandable raw request. Those key lines are not a stored summary: opening the page **hands the stored
  request back to the engine for a fresh review**, so the fields are the same ones the review page
  showed, and the recomputed request fingerprint must equal the one in the record — if it does not, no
  decoded content is shown. Decoded fields therefore cost no extra storage and can never drift from the
  raw request.
- **Output**: `Show QR Code` displays that signature QR again (useful when the other wallet failed to
  scan it; scanning again produces nothing new), `Export as File`, and the expandable raw signature.

Storage: `SigningReceipt` gained `requestJSON`, `responseFrames` and `responseText`, with a 32 KiB cap
per payload (over that, the record stores no payload at all rather than truncating), and payloads are
kept only for the **last 25** records, with older records keeping every other field and losing only the
payload. The file cap rose from 256 KiB to 2 MiB, and each record is validated on read. The file itself
is still `completeFileProtection`, 0o600 and excluded from backups. Both stored items are public data —
a request and a signature — involving no secret, and a test checks that no recovery phrase, password or
private key appears in the record file.

**3. The request fingerprint is uppercase.** On the same card the wallet "Fingerprint" was uppercase
(`store.fingerprint(for:)` always was) while "Request fingerprint" was lowercase: two things called a
fingerprint, inconsistently. `HashText` now displays uppercase throughout (display only; comparison
remains case-insensitive).

**4. A test-tooling problem.** The new known-contract UI test passed reliably on its own and failed
reliably inside the full suite. The cause was not in the app: `typeText` drops characters when the
simulator is under load (the whole suite running as parallel clones), so the 400-character UR text
failed validation and presented as "the review page never appeared". It now reads `field.value` back
after typing and retypes on a mismatch (`typePayload(_:into:in:)`), and all three long-payload pastes
use it.

**5. The minimum OS assessment (decided: do not lower).** Lowering iOS 17 to iOS 15 was assessed and
**iOS 17 was kept**, with no code changed; the record is in
[docs/DeploymentTarget.md](docs/DeploymentTarget.md). In short: the toolchain accepts iOS 15.0;
reaching **iOS 16** is about 63 mechanical replacements with no architectural change (gaining the
iPhone 8); reaching **iOS 15** additionally requires rewriting `NavigationStack` as `NavigationView`,
and navigation is exactly where post-signing state transitions are most tightly coupled. The
recommendation at the time was to take iOS 16 first and make iOS 15 its own project; the decision is
now to do neither.

## Revision 6 (17 October 2026): known public contracts

Ownbit's WalletConnect known-contract library was brought over and used in two places: **signature
review** and **Settings browsing**. Details in [docs/KnownContracts.md](docs/KnownContracts.md).

**1. The library.** From the Ownbit security centre
(`wallet-ios-core/scripts/security-center/known_contracts.json`, sourceVersion 1, 9 October 2026):
**1,720 addresses across 307 projects** — Ethereum 329, Base 217, BNB Smart Chain 194, Polygon 191,
Arbitrum 186, OP Mainnet 169, Solana 262, TRON 139, Avalanche 6 — plus 27 CREATE2 deterministic
deployments (Permit2, Seaport, the ERC-4337 EntryPoint, Multicall3, Safe and others) that have the same
address on every EVM network, used as a fallback when a per-chain lookup misses and annotated in the
review as "the same address on every EVM network". HyperEVM (999, 132 entries) was dropped because the
app does not review that network. `scripts/build-known-contracts.py` validates address format, category
and duplicates, then writes two projections: a columnar string for the engine (139 KiB, split only on
first use, so a request that touches no contract pays nothing) and the complete JSON for in-app browsing
(277 KiB).

**Being listed means only "this address is a deployment the project itself published", not that a
request is safe** — a known contract can drain an account just as well. The difference is being able to
tell "the Permit2 everyone uses" from "an address nobody has seen", which is exactly what an imitation
contract relies on.

**2. Applied at signing time.** The lookup is on **the address a request would authorize**, which is not
necessarily the contract being called: `approve` looks up the spender, `setApprovalForAll(…, true)` the
operator, an EIP-712 message its `spender` or `operator` if present and otherwise
`domain.verifyingContract`, and anything else the called contract. A `SafeTx` verifying contract is
skipped outright: every Safe is deployed by its own user, so "not on the list" would be pure noise.

On a hit the review gains a field such as `Spender (known contract)` and `review.contract` carries the
name, project and category. On a miss the token registry is consulted first — an address the token
registry already recognizes is shown as that token rather than "unknown" — and otherwise a warning is
issued, with **only an unlisted spender or operator** raising the risk level to `warning`. An unlisted
ordinary contract does not raise it: the vast majority of contracts are new or private deployments, and
flagging them all would drain the signal of meaning.

**3. Solana.** One Solana transaction is many instructions with no single counterparty, so
`review.contract` is not set; instead a `Program (known)` line is added for programs **the engine does
not decode itself** — writing "Raydium AMM v4 — Raydium · dex" beside an instruction that would
otherwise be raw bytes. Programs the engine does decode (System, Token, Token-2022, ATA, Compute
Budget, Memo, Stake, Squads, and the Metaplex and marketplace programs) keep their own names, because
their Action field says more than a list label would. An unlisted Solana program raises no extra alarm:
whether an instruction was decoded is itself the signal, and an undecoded instruction is already high
risk.

**4. How the review page shows it.** When the address is already in the summary card's counterparty box
(authorization-type requests), the notice sits on the line below it; when they differ — a token transfer
authorizes the token contract, not the recipient — it gets its own card. Four states: listed is amber
with a seal icon (**not green** — putting a green tick beside an address that is being granted an
unlimited allowance would claim more than the list can support), an unlisted spender or operator is red,
an unlisted ordinary contract is a grey question mark, and one the token registry recognizes uses the
accent colour.

**5. Settings merged into Networks, Tokens & Contracts.** The former "Networks & Tokens" expanded to
browse tokens and known contracts together. Each network page uses a segmented control to switch
between them, sharing one search field (contracts are searchable by name, project, category or
address), and the switcher is hidden when only one side has content (Gnosis has only tokens).
Deterministic deployments get their own "All EVM networks" row.

**6. Tests this round.** Engine **179/179** (one new Solana known-program case: a hit is named, an
unlisted program raises no extra alarm, and a program the engine decodes itself is not renamed); native
unit **156/156** (new `KnownContractTests`, 14 cases: the packed file's record integrity and declared
counts, every chain reachable in Settings, `ReviewContract` parsing and fallback, and whether the
summary already shows that address); UI automation **16/16** (new
`testApprovalNamesAKnownSpenderAndFlagsAnUnlistedOne`: a real `eth-sign-request` QR code walking an
unlimited USDT approval to Permit2 and an approval to an unlisted address, asserting the corresponding
notice does and does not appear; `testSettingsReferencePagesAndGuide` extended to contract browsing and
search). The screenshot tour gained `28/29-review-known-contract` and `44c/44d/44e-contracts`.

**7. Fixed in passing.** The Info.plist camera and Face ID usage descriptions could previously only be
English, because they come from build settings and do not go through `Localizable.strings`.
`translations/<language>.json` gained an `infoPlist` section, which `scripts/write-localizations.py`
writes out as `InfoPlist.strings`. `AppNameTests` changed accordingly: system prompts may be
translated, but the app name may not.

## Revision 5 (17 October 2026): interface language, delete confirmation, assorted fixes

**1. Interface language (Settings › Appearance › Language).** A language picker was added under Theme.
Switching takes effect immediately with no restart — the chosen language applies to the whole view tree
through `.environment(\.locale)` (`AppLanguage` plus `LanguageEnvironment`). Arabic also switches
`layoutDirection`, mirroring the entire interface right to left (tab order, in-row alignment and back
arrows all flip). Navigation bar titles are cached by the system, so switching language rebuilds the
whole tree once and returns to the first tab.

The language list follows BitTool Wallet's, **21 in total** (en, zh-Hans, zh-Hant, ja, ko, ru, uk, es,
es-419, de, fr, it, pt-BR, pt-PT, pl, id, tr, th, vi, fil, ar). The picker lists only languages that are
**actually translated**, so there is no case of choosing one and still seeing English. *(At the time of
this revision only zh-Hans, zh-Hant and ar were done, at 388 strings each; Revision 9 completed all 21,
and the list now stands at 773 strings.)*

The string list is no longer produced by hand-written regular expressions: Xcode's own extraction
(`xcodebuild -exportLocalizations`) gives the authoritative list, which is then merged with the static
text the engine produces (see Revision 9), in
[engine/data/interface-strings.json](engine/data/interface-strings.json).
[scripts/write-localizations.py](scripts/write-localizations.py) turns `translations/<language>.json`
into `.lproj/Localizable.strings`, refusing a file that misses an entry or alters a `%@` or `%lld`
specifier — a misplaced specifier would make the runtime format against the wrong value.

To make the translation thorough, every component and local helper that took display text as a `String`
was changed to `LocalizedStringKey` (`Callout`, `DetailLine`, `WalletGroup`, `StepRow`,
`PayloadDisclosure`, `SetupScaffold`, `ProfileMenu`, the onboarding `Page`, the Scan page's
`optionTile`, the password requirement rows, and the address page's group titles and footnotes).
Dynamic text returned by the engine goes through the `verbatim:` entry points and is left as it is.

Still English at this point: **the review text the JS engine generates** (warnings, field names and risk
explanations — several hundred strings, and the most security-relevant) and the Terms and Privacy Policy
(English by decision). Revision 9 addressed the first of those.

**2. Deleting a wallet became Face ID plus password.** Tapping Delete Wallet first ran Face ID where the
device supported it (cancelling aborts; if biometrics are unavailable or fail it continues to the
password), then prompted for the password, and only the correct wallet password actually deleted
anything. The password field used to be an inline row in the form, which was easy to overlook. The trash
icon rendered dark on the red button and was forced to white. *(Revision 11 narrowed the Face ID step to
apply only when App Lock is enabled.)*

**3. The passphrase field can dismiss the keyboard.** That field carries its own Done toolbar
(`inputAccessoryView`), because it sits right against the bottom action bar and the page has no other way
to dismiss the keyboard. It also gained `frame(maxWidth: .infinity)` to stop the UIKit text field
shrinking to its content width.

**4. Settings adjustments.** Offline Setup Guide was removed from Reference (the onboarding pages still
appear on first use); Open Source in About was renamed **Fully Open Source**.
## Revision 4 (16 October 2026): rebranding and legal documents

The app was renamed from **BitSigner** to **BitTool Signer**, the former BitTool became **BitTool
Wallet**, the operating entity is **BITTOOL PTE. LTD.**, the sites are [bittool.com](https://bittool.com),
[bittool.com/signer](https://bittool.com/signer) and [bittool.com/wallet](https://bittool.com/wallet),
and the contact address is support@bittool.com. The app has not shipped, so the rename was done
completely and without compatibility shims:

**1. Project and identifiers.** `BitToolSigner.xcodeproj` and every target, scheme and source directory
were renamed; the bundle id became `com.bittool.signer` (with `.tests` and `.uitests`) and the display
name `BitTool Signer`. The Keychain service, the encryption AAD, the public index AAD, the UI tests'
arguments and environment variables, and the local directory (`Application Support/BitToolSigner/…`)
all moved to `com.bittool.signer.*`. The wallet identity domain separator became
`BitTool-Signer/WalletKeyId/v1`, and the `walletKeyId` vectors were updated with it (including the
fixed vectors in the tests). **Development wallets already on a device therefore cannot be opened any
more and have to be imported again from the recovery phrase.**

**2. Pairing protocol.** The wallet-level payload's `protocol` became `bittool-signer-wallet`, the
signature receipt transport `bittool-signer-json`, and the device name third-party wallets display
inside `crypto-account` / `crypto-multi-accounts` `BitTool Signer`. Both
[docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md) and
[docs/bittool-handoff/](docs/bittool-handoff/) gained a rename notice at the top and their fixtures
were regenerated with the new names — **the parsing on the BitTool Wallet side needs updating to
match**.

**3. Icons.** Both apps share the BitTool mark (a ring plus a solid node), with the geometry measured
directly from the Wallet icon (ring 288–372, node radius 94.8 centred at (828.5, 511.5)). Wallet uses
the light version (ink mark on white), Signer the dark one (white mark on `#0A0A0C`).
`scripts/make-brand-assets.py` was rewritten to need no third-party library: every shape is a circle,
so it rasterizes by coverage directly and writes the PNG with zlib.

**4. Terms of Use (v1.1).** Rewritten to the requirement that liability is zero and the user is
responsible for their own funds, following common practice for self-custody wallets. New sections cover
self-custody, the risks you accept, your indemnity to us, and dispute resolution, and the limitation of
liability states **total liability of zero with no compensation** (preserving non-excludable statutory
rights and consumer protections). Governing law is Singapore. The Privacy Policy was updated to v1.1 in
step, adding the operating entity and contact details. Both documents give
BITTOOL PTE. LTD. / support@bittool.com / https://bittool.com/signer.

**5. Pair defaults to wallet level.** The Pair page opens on **Wallet Level**, with Coin Level as the
second option. Prefetching switched to the wallet-level QR code (it had been the Bitcoin coin-level
one), so the first push still shows a complete page on the first frame; Coin Level loads when selected.
*(Revision 7 narrowed this: entry points that name a chain open Coin Level instead.)*

**6. The local simulator environment.** Xcode on this Mac is **26.4**, but the only installed iOS 26
runtime is still a **beta (23A5276e)**. A build made with the 26.4 SDK crashes with `SIGABRT` on that
older beta runtime at `glassEffect` (`GlassCircle`), unable to find type metadata — unrelated to the
rename, and everything passes on the iOS 18.6 runtime instead. This round's verification therefore ran
on **iPhone 16 Pro · iOS 18.6** (UI 15/15 and the screenshot tour passing). Re-verifying the Liquid
Glass path needs a released iOS 26 runtime matching 26.4 installed in Xcode.

**7. The app's name.** It is **BitTool Signer** in every language and is not translated. The name is set
in exactly one place, `INFOPLIST_KEY_CFBundleDisplayName` in the project (the store listing name is
entered per language in App Store Connect). The app deliberately **declares no additional languages**:
declaring them makes the system's own controls (permission dialog buttons, the keyboard, the share
sheet) follow the device language while the app interface stays English, which looks half-translated.
`AppNameTests` guards this.

**8. BIP39 passphrase visibility and AutoFill.** The passphrase fields in create and import gained an
eye button on the right to reveal the text, which re-conceals automatically when the app goes to the
background. A mistyped passphrase produces no error — it silently opens a different wallet — so being
able to read it back and check is essential. The field moved to a UIKit `UITextField`
(`MaskedTextField`): concealment is just a property of that field rather than a different view, and for
newly created secrets (the passphrase and a new password) iOS **AutoFill is disabled**, because
AutoFill's strong-password flow replaces whatever the user typed. The other password fields remain
SwiftUI `SecureField` and were not changed. The passphrase field also sets an empty `passwordRules`,
which removes the iOS strong-password generator entirely.

**9. Welcome page selling points.** The second point changed from "Sign with QR codes" to **Fully open
source** ("Every line that touches your keys is published. Read it, or rebuild it and compare."), with
QR signing folded into the third point; the second onboarding page still introduces QR compatibility in
full.

**10. The "Wireless Data" prompt in China.** The app contains no networking code and links neither
CFNetwork nor Network.framework (verifiable with `otool -L`). On iPhones sold in mainland China, iOS
gives every app a wireless-data switch and asks on first use; that prompt comes from the system, not
the app. The offline guide gained a line — if iOS asks whether to allow wireless data, choose Don't
Allow — and the Privacy Policy a short section explaining it.

## Revision 3 (22 September 2026): pairing, backup and NFT review

This round implemented the user's ten pieces of feedback. (Item 8 ended mid-sentence with "another
thing, now tapping:" and could not be acted on.)

**1. "Connect a Wallet" hung after creation finished.** Confirmed as an app bug. The connect page used
to be pushed onto the wallet navigation stack at the same moment the creation sheet was dismissed, so
two transitions ran at once and the push animation stalled halfway. The route is now recorded first and
pushed after the sheet has fully closed (`onDismiss`). A UI test goes from the completion page into the
connect page and confirms the QR code loads and chain switching works.

**2. The selected chain was not visible at the top of the pairing page.** The selected item became a
light block with an accent-coloured border, its icon full-colour and slightly enlarged, while unselected
items have desaturated, more transparent icons and grey text; both are unmistakable in light and dark
mode. At large type sizes only the icons show, and VoiceOver still reads the chain name.

**3. TRON address index.** Raised from 0–99 to 0 through 2³¹−1, the BIP32 non-hardened ceiling. The
pairing page offers a stepper and direct entry, with the path shown underneath at all times, and clamps
to the maximum when the limit is exceeded. The engine derives from the account node on demand and the
address page scrolls indefinitely. `tron-sign-request` always carries a path, so a signing request for
any index can match; a request with an address but no path is still compared only against the cached
0–99.

**4. Sparrow, BlueWallet and XPUB.** A survey confirmed both import account xpubs (`crypto-account`) by
default and can sign by QR with `crypto-psbt`, so Bitcoin's default became Account XPUB. It also found
that the previous "Public Key" mode (the `/0/0` leaf public key with no chain code) does not conform to
BCR-2020-015 and could not be imported by any wallet surveyed, so it was removed from the interface and
the engine.

**5. Supported wallets.** Ownbit was removed. Each wallet and each export was checked against official
documentation, source code, or Keystone's official guides and firmware, then an independent reviewer
tried to refute each entry, and only confirmed ones were kept. The Pair page and Settings ›
Compatibility split them into "can sign by QR" and "watch-only"
(`BitToolSigner/Models/CompatibleWallets.swift`, with the evidence in
[docs/Compatibility.md](docs/Compatibility.md)).
- Bitcoin signing: Sparrow, BlueWallet, Nunchuk, Bitcoin Keeper, BULL Bitcoin, Specter, Bitcoin Safe,
  ZEUS (no Legacy); multisig coordinators: Sparrow, BlueWallet, Nunchuk, Keeper, Specter, Bitcoin Safe;
  address watching: BlueWallet, Electrum.
- EVM signing: MetaMask, Rabby, imToken, TokenPocket (EIP-4527), Ambire; address watching: Rabby,
  TokenPocket, OKX Wallet, Trust Wallet.
- Solana signing: Solflare, Helium Wallet; address watching: Phantom, Backpack, Jupiter, OKX Wallet,
  TokenPocket.
- TRON is watch-only: TokenPocket, TronLink, OKX Wallet, OneKey. **TokenPocket does support watching
  TRX and SOL addresses**, but its cold-wallet signing uses a proprietary protocol, and no mainstream
  hot wallet currently generates a `tron-sign-request` from a plain-address export.
- Safe was removed (the old iOS app is archived and the new one has no QR signer); Backpack's Solana
  signing flow has no official documentation and dropped to watch-only. Fourteen official wallet icons
  were added and the Ownbit and Safe icons removed ([sources](docs/WalletLogoSources.md)).

**6. Token registry expansion.** From 358 entries to **596** (Ethereum 196, BNB Smart Chain 112,
Arbitrum 67, Base 86, TRON 14, Solana 121). A new discovery script,
`scripts/discover-token-candidates.py`, loosened the thresholds; one reviewer picked the mainstream
tokens per network and an independent checker re-verified each against primary sources, dropping 28
(deprecated ERC-20s, low-tier memes, tokens launched only weeks earlier, one that had just been
exploited). All 596 were re-checked by the build script against CoinGecko mappings, independent lists
or issuer documentation, on-chain decimals and symbols, and every icon was inspected by eye. TRON gained
nothing: every mainstream, active TRC-20 that CoinGecko maps to TRON was already included. The build
script gained two things: issuer documentation (`officialSource`, where the original page must contain
the address) counts as an independent source, and CoinGecko "broken image" placeholders are rejected by
hash.

**6b. Further expansion from the CoinMarketCap top 2000.** On top of the 596 manually vetted entries,
tokens from the CoinMarketCap top 2000 deployed on supported chains were added, for **3,350** in total
(Ethereum 1,008, BNB Smart Chain 876, Solana 585, Base 333, Arbitrum 225, Polygon 137, Avalanche 75, OP
Mainnet 53, Gnosis 32, TRON 26). The listing decides only *which* tokens are included and supplies the
name, symbol and icon; **decimals are always read on-chain** (EVM `decimals()`, Solana
`getMultipleAccounts`, TRON `triggerconstantcontract`), and 3,242 of 3,250 contracts answered — the rest
were simply not included. The symbol is whatever the contract's own `symbol()` reports (2,276 entries);
of the 235 that disagree with the listing, 161 differ only in case or punctuation (`frxUSD`, `$MBG`) and
most of the rest are bridged or wrapped versions (Avalanche's `LINK.e`, `UNI.e`, `DAI.e`, plus `wROSE`,
`pONT`, `axlSAGA`, and the pre-rename `LUNA` and `UST`) — showing the listing's name would present them
as the original token. The 486 contracts overlapping the original 596 were an independent check: the
on-chain decimals matched the manually vetted values **in every case**. New scripts:
`scripts/refresh-cmc-snapshot.py` (the API key is read only from the `CMC_API_KEY` environment variable
and never written into the repository) and `scripts/build-expanded-registry.py` (manual entries always
win). The review interface treats old and new entries identically with no extra annotation; inclusion
has never implied endorsement.

**6c. Icons became a content-addressed pack file.** All 596 `token_*.imageset` folders left
Assets.xcassets (the asset catalogue went from 10.9 MB to 484 KB), and the icons for 3,350 records
deduplicated by byte SHA-256 down to **1,985 images** (the same token on several chains shares one),
assembled into a single `TokenIcons.pack` (10.7 MiB) plus a `TokenIcons.index.json` offset table, which
`TokenIconStore` reads by mmap and decodes on demand. Two thousand loose small files would each occupy
a full filesystem block on the device, about 4 MB more.

The engine's slim registry changed to "store each network and program string once, plus one
tab-separated string per row" (313 KiB), so entering a new VM allocates a single string and the table is
only split and built on the first lookup by a request that genuinely involves a token. Measured in the
simulator: 66–75 ms per VM start (47–59 ms with 596 entries), and under 1 ms for the first token lookup.

**7. NFT display.** A dedicated NFT review was added (see "How NFTs are shown in the review" in
[docs/Compatibility.md](docs/Compatibility.md)).
- EVM and TRON: ERC-721/1155 and TRC-721 transfers and approvals; `approve` and `transferFrom` show both
  readings when the selector is identical to ERC-20's; `setApprovalForAll(true)` gets a red warning;
  ERC-1155 batches are merged; over-long token IDs are abbreviated and also shown in full; NFT calls
  inside a MultiSend are annotated one by one.
- NFT marketplace signatures: Seaport 1.5/1.6 (including bulk orders) and LooksRare v2 are decoded into
  "you give / you receive / someone else receives", with red warnings for phishing shapes — a zero
  price, a price falling to zero, any token being selectable, an order that never expires, an ERC-20
  disguised as an NFT; Blur's blind-signed Merkle root is marked undecoded and high risk.
- Solana: a 0-decimal, quantity-1 SPL transfer ("likely NFT"), Metaplex Token Metadata TransferV1,
  Bubblegum compressed NFTs, Core TransferV1, Token-2022 transfer hooks, NFT delegate/lock/burn, and
  marketplace program names.
- The review card gained NFT icons, an NFT contract (not verified) or Mint/Asset ID address box, the
  complete token ID, and give/receive/others lists. Every constant was checked against official
  repositories and independently reviewed; NFT display never uses a green "verified" indicator.

**8. Tap to Reveal.** A single tap now reveals, with no confirmation dialog. A screenshot, a move to the
background or a screen recording still conceals immediately, and content cannot be revealed again until
the screenshot warning is acknowledged.

**9. The QR code.** Changed to a plaintext phrase QR (words separated by spaces, without the
passphrase), blurred by default and revealed on a tap, with its purpose explained above and a red
warning below, and no save or share. Importing by scan now uses the spelling in the QR code and no
longer asks for the language. The previous encrypted backup (`BSBK1:`), its password form and the photo
library write permission were all removed.

**10. Recovery cards (2 of 3).** "Word Cards" became recovery cards: three cards each hiding a third of
the words (shown as xxxx), any two of which reconstruct the phrase. The layout depends only on the word
count (three positions per row, one hidden per row), so it is identical when reopened or generated on
another device; concealed by default, revealed on a tap. At 12 and 15 words a single card is missing
only 40 or 50 bits, and the interface says a single card still needs to be kept safe.

**Problems found and fixed during testing and review**
- The pairing page was sending the TRON index to Bitcoin, EVM and Solana as well, so changing the TRON
  index made the other chains error out and show no QR code (found by independent review).
- With Recovery Cards or Security Tips open, the concealed phrase view underneath was still listening
  for screenshots: one screenshot triggered two warnings and could break Tap to Reveal. The lower
  session is now suspended while covered by a sheet.
- The three-column word grid truncated eight-letter words to "…" on 375 pt iPhones (SE, mini), present
  since Revision 2, which could have led to copying a word down wrongly. The column count is now
  computed from the actual width and font size, dropping to two columns or one when needed, in all
  three places: backup, cards and the fill-in check.
- At 12 and 15 words the card explanation said losing one card was still safe, which contradicts the
  entropy arithmetic; rewritten per word count.
- Address index row: at six digits or more the label wrapped to two lines and the path was truncated;
  the input width did not follow the font size; and beyond the ceiling the number shown disagreed with
  what was exported. All fixed.
- The multisig toggle state carried over to the EVM page, making EVM show "Cosigner account path".
  Fixed.
- An error scanning a recovery phrase displayed the signing-request wording. Now distinguished by
  purpose.
- "Hide QR Code" on the QR page could not be tapped when it sat under the bottom bar; moved directly
  below the QR code.
- Token build: CoinGecko's image for DoubleZero (2Z) was a broken-image placeholder that the automatic
  check did not catch; that token was dropped and the placeholder is now blocked by hash. A
  non-standard 404 marker left in another tool's cache crashed the build and was cleaned up.

### Revision 3 follow-ups (same day)

- **One font size per word grid, every word complete.** Each cell used to shrink independently to fit
  its word, so long words were smaller than short ones and still produced "proper…" when they did not
  fit. A grid now uses a single size: the largest that fits the longest word completely, not below 80%
  of the normal size; smaller than that, it drops to two columns or one. The phrase grid, the recovery
  cards and the fill-in check all behave the same.
- **Wallet-level pairing.** Implemented from the user's *BitTool Signer Wallet-Level QR Pairing Protocol
  v1* draft, with a Coin Level (default, the existing per-chain formats) / Wallet Level switch at the top
  of the Pair page. At the user's subsequent request, Wallet Level had exactly one form: a single static
  QR code (one `ur:bytes`, not framed or animated) carrying only the Bitcoin (BIP84), EVM and TRON
  account xpubs and one Solana address (`m/44'/501'/0'/0'`; Ed25519 derivation is hardened, so there is
  no xpub), with no Simple/Full wording in the interface. The test wallet's payload was 755 bytes and
  1,533 QR characters (version 23, error correction L). *(Revision 9 replaced this with seven accounts,
  three Solana addresses and four animated frames.)* The encoding is `ur:bytes` plus canonical CBOR
  (RFC 8949 §4.2.1, with field names identical to the JSON keys) and an added `masterFingerprint`
  field; the exact rules and test vectors are in
  [docs/Wallet-Pairing-v1.md](docs/Wallet-Pairing-v1.md). The wallet supported by default is **BitTool
  Wallet** (BITTOOL PTE. LTD., iOS; listed at the user's direction, with the official icon added and its
  source recorded), shown on both the Pair page and Settings › Compatibility. The Solana address comes
  from the existing standard preset, the public index stays at version 1, and existing wallets need no
  Repair. (An intermediate version exported ten Solana accounts and raised the public index to version 2
  for it; that was withdrawn at the user's request.)
- **Background tasks.** The three "running" tasks the user saw were checked: no process was running and
  all the work had finished. Two were leftover listener records from completed subtasks and were cleaned
  up.
- **A device stuck on the launch screen with a dark background card.** Not an app bug. Two Xcode Run
  actions overlapped at 14:58, and after the second failed to attach a debugger it left an orphaned
  debugserver on the phone; every subsequent Run then stopped at "Launching suspended and the debugger
  is responsible for resuming", with the app process suspended and not one line of code executed, so the
  phone kept showing the system launch image, which does not follow the app's appearance setting.
  Clearing the debug session restored normal behaviour. The appearance combinations were then verified
  one by one in the simulator (system light/dark × app setting System/Light/Dark, including switching
  the system appearance while backgrounded): the background card always follows the app setting, and
  only turns dark when the app setting is System and the phone itself switches to dark, which is
  correct. As hardening, the privacy shield window now explicitly uses the app's appearance setting and
  updates live when it changes, and while recording or mirroring the shield explains "Hidden while your
  screen is recorded or mirrored" rather than looking like a stuck launch.
- **Address type right-hand padding.** It had been a menu-style Picker whose built-in padding differs
  between iOS versions, leaving the value and chevron almost touching the card's right edge. It became a
  Menu with a custom label, 14 pt on each side, with the whole row tappable; at accessibility type sizes
  it stacks vertically, and VoiceOver reads both the current value and the explanation. Pair and
  Addresses share it.
- **The TRON address list no longer shows the derivation path.** The group header changed from
  "Receive · m/44'/195'/0'/0/i" to "Receive · TRX and TRC-20 tokens", matching Bitcoin's
  "Receive · Native SegWit" and EVM's "Receive · All EVM networks", and the Bitcoin footer dropped its
  "(…/0/i)". The UI tests and screenshot tour gained the TRON address list.
- **The first push into Pair stalled mid-animation.** Measured in the simulator with timing probes rather
  than XCUITest, to avoid its accessibility queries interfering: on the first entry the JS engine starts
  cold, the pairing result returns halfway through the slide-in animation, and the main thread then
  inserts the QR code and verification card and relays out the whole page (about 300 pt of movement with
  a fade), while CoreImage/Metal renders a QR code for the first time in the same moment. The fix: once
  wallets are on screen, and while the app is foreground, unlocked and not being recorded, the QR code
  Pair opens on by default is generated for each wallet in the background (the Bitcoin Native SegWit
  account xpub, using only the device's own authenticated public index, held in memory only), so opening
  Pair arrives with a finished result and calls no engine, renders no QR code and relays out nothing
  during the push. QR codes now render on the CPU (one pixel per module, negligible cost), avoiding
  Metal's first initialization, and when prefetching misses, the first result no longer fades in.
  Measured on the first push: previously 286–329 ms of stall at the start plus another 75–83 ms
  mid-animation; now a single ~190 ms at the start (a Debug build, first construction of the page) and no
  mid-animation stall. Prefetched results and the warm JS context are cleared on backgrounding, App Lock
  and screen recording — the documentation had said the warm VM was released in the background, but the
  code never called it, which is now fixed — and regenerated on returning to the foreground.

### Revision 3 follow-ups (second round)

- **Wallet identity became the fingerprint.** On wallet cards, the detail page, the review page's signing
  wallet, the password entry header and Activity details, the former "Wallet ID" (a truncated
  `walletKeyId`) became **Fingerprint**, showing the BIP32 master fingerprint such as `C6A5A927`,
  identical to `masterFingerprint` in the Wallet Level payload and to the Master fingerprint on the Pair
  page. Signing records now store the fingerprint too. Internal identity and request matching still use
  `walletKeyId`; the fingerprint is display only. The wallet picker before App Lock unlocks shows names
  only: a fingerprint also appears in exported PSBTs and xpubs, and is not exposed before unlocking.
- **Every Coin Level QR code gained a Payload section.** The verification card gained a "Format" line
  (such as `ur:crypto-account · CBOR · 162 bytes`) below the fingerprint and a collapsed
  "Payload (JSON)" / "Payload (Text)". The content comes from the engine re-decoding the frames it has
  just generated, with field names from the BC-UR registry; see "The QR payload view" in
  [docs/Compatibility.md](docs/Compatibility.md). A fingerprint in a UR is a 32-bit integer, and the
  Payload section notes the corresponding hexadecimal form. Wallet Level uses the same component.
  Copying became "Copy Payload" to the local, expiring clipboard, and selecting the whole text into the
  general clipboard is no longer allowed.
- **The review page's signing wallet card was trimmed.** When Details already lists the request's signing
  address and derivation path (EVM, Solana, TRON), the signing wallet card no longer repeats them.
  Bitcoin PSBT details carry no signing path, so it is still shown there.
- **Format and Master fingerprint order unified.** Both Coin Level and Wallet Level verification cards
  now run Format, then Master fingerprint, then Payload.
- **Terms of Use and Privacy Policy became bundled documents (v1.0).** Settings › About and the welcome
  page footer used to be web links to `bittool.com/signer`, which opened a browser — the footer line
  "Legal links open in your browser." existed to warn about exactly that, and has been removed. That
  contradicted "offline throughout", and before launch the links did not even resolve. Both English
  documents, `BitToolSigner/Resources/TERMS_OF_USE.txt` and `PRIVACY_POLICY.txt`, are now bundled and
  read inside the app (a page from Settings › About, a sheet from the welcome page), are selectable and
  copyable, and contain no URL anywhere. This is a deliberate change to D27 of the Revision 1
  specification, which had asked for links to the website instead.
  - The Privacy Policy corresponds line by line to actual behaviour: no data collected, no networking
    code, no third-party SDK; what is stored locally (the encrypted phrase and passphrase, authenticated
    public wallet data, up to 100 Activity records, preferences), file protection and backup exclusion;
    the camera opens only while scanning and keeps no frames; Face ID returns only success or failure;
    copying goes only to the local clipboard and expires after two minutes; the interface is covered on
    backgrounding, recording and mirroring; and deleting a wallet or the app deletes the device key from
    the Keychain with it.
  - Three placeholders — `[Publisher legal name]`, `[Governing law jurisdiction]` and `[Contact email]` —
    had to be filled in before submission, and a unit test checks that no other placeholder and no URL
    appears.
  - The first draft was checked sentence by sentence against the code by several reviewers, which
    corrected a few inaccurate statements: the plaintext phrase QR on the backup page is an exception
    that *does* leave the device; preferences live in UserDefaults and therefore do enter device backups
    (only wallet files, public data and Activity do not); deleting a wallet does not delete its Activity
    records, which display as "Deleted wallet"; the device key may survive in the Keychain after the app
    is deleted; the Activity record fields were completed; the failed-attempt counter file was added; and
    file import and export can land in a cloud directory under Files. The Terms gained explanations of
    the passphrase and of forgetting the password, Apple's minimum EULA clauses, and a corrected list of
    surviving clauses.
  - Settings › Third-Party Licenses was fixed in passing: the original file had three "undefined
    undefined" entries and one "[object Object]". The new `scripts/build-third-party-licenses.mjs`
    regenerates it from the 67 packages actually bundled per `engine/bundle-manifest.json` (including the
    nested @noble/curves 1.2.0, @noble/hashes 1.3.2 and ethers 6.17.0), each with a name, version,
    licence and the full licence text.
- **The wallet detail page gained a Wallet Level row.** The Pair group has a row below the four chains,
  "Wallet Level · One QR code for all four chains", which opens Pair at Wallet Level directly (the new
  `WalletRoute.connectWallet` route).
- **The signature result page** keeps a single primary button, **Done**. Below the result QR code is a new
  card: Format, a collapsed "Payload (JSON)" (eth/sol/tron signatures show `request-id` and `signature`;
  Bitcoin shows `psbt_base64` and a `decoded` section using Bitcoin Core `decodepsbt` field names,
  ordered first so it stays visible when a large PSBT is truncated), and "Export as File" demoted to a
  secondary action.

## Revision 2.1 (22 September 2026): multilingual phrase import and the new backup flow

Two additions this round: importing BIP39 phrases in other languages, and rebuilding the phrase backup
flow following Ownbit's latest approach, styled with this app's own colours and components.

**Multilingual import**
- All 10 official BIP39 wordlists: English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français,
  Italiano, Čeština, Português.
- The wordlists are taken byte for byte from bitcoin/bips with pinned SHA-256 hashes, checked word by
  word against two independent sources (@scure/bip39 and ethers). Validation, including the checksum,
  moved to a native implementation.
- The language is detected as you type, the status line names it, and candidate words come from that
  language.
- Accents may be omitted, capitals are accepted, numbering and commas are allowed, Chinese may be
  entered without spaces and Japanese with full-width spaces. The app always converts back to the
  official spelling before computing a seed, and the vault stores NFC.
- One set of unaccented words can be valid in two languages and correspond to two different wallets (the
  instance found in testing: Italian "nomina solido comodo …", which is also valid Spanish once
  accented). The app then asks which language the backup was written in rather than guessing. If accents
  were typed, the exact spelling is used.
- The phrase input moved to the system keyboard so Apple's Chinese, Japanese and Korean input methods
  can be used; third-party keyboards remain refused app-wide.

**The new backup flow**
- The top of the backup page switches between Words and QR:
  - Words are blurred by default and shown after confirmation.
  - "Word Cards" showed one large word at a time (changed to 2-of-3 recovery cards in Revision 3).
  - "Security Tips" collects the safety guidance in one place.
  - The "I've Written Them Down in Order" button at the bottom becomes available only after the words
    have been shown once.
- The QR page once produced an encrypted backup QR code (changed in Revision 3, at the user's request, to
  a plaintext phrase QR, with the encrypted backup removed).
- The check page became fill-in-the-blanks:
  - Every position shows as "n. ••••••" with 4 left blank (5 for 18 words or more); the words for those
    blanks appear shuffled at the bottom, pinned to the bottom bar so they stay tappable on small
    screens.
  - Tap them in order to fill the blanks; tapping a blank chooses which position to fill next, and
    tapping a filled position takes the word back; the current blank scrolls itself into view.
  - A wrong answer clears what was filled in but leaves the blanks and the word order unchanged;
    backgrounding or a screenshot also clears it.

**Problems found and fixed this round**
- The rule that ignores numbering such as "1." was testing for Unicode digits, which discarded Chinese
  phrases containing 一 and 十; it now ignores ASCII digits only.
- The cross-language ambiguity above used to be imported silently as a different wallet; exact spelling
  now wins, and the user is asked when it is ambiguous.
- Pressing Return in the backup password form did not move to the confirmation field (that form was
  removed in Revision 3).
- On small screens the words used for filling in were hidden behind the bottom bar and needed scrolling
  to tap; they are now pinned to it. The current blank's highlight was greyed out by the system's
  disabled style; fixed.
- The import page still said "English words"; changed to say ten languages are supported.
- At accessibility type sizes: the phrase status line was truncated and now wraps; the QR page's two
  buttons stack vertically; and "Security Tips" moved above the bottom bar's primary button, matching
  Ownbit's layout, so it is tappable at any size.
- An encrypted backup made from an ambiguous phrase asked for the language again on restore (changed in
  Revision 3: a scanned phrase QR is imported with its own spelling).
## Test results

Current as of Revision 14 (16 November 2026).

| Check | Result | Scope |
|---|---|---|
| JS engine (Node) | **238/238 passed** | Protocols, the public index, the resolver, signing on four chains, `hardening.test.mjs` (the Revision 2 review regressions), wallet-level pairing v2 and the KH v2 wallet-identity signature (`kh2.test.mjs`: the published vectors byte for byte, the message digest recomputed independently, malleated, wrong-epoch and other-wallet signatures refused, and no text but the fixed sentence signable), NFT display for EVM and Solana, TRON arbitrary indices, the Bitcoin Account XPUB default, the QR payload view (22 Pair exports and 17 signature returns; frames are re-decoded, and URs and signatures are cross-checked against Keystone's parser), the Bitcoin fee policy, and both rounds of review findings (`audit-bts-2026-1018` and `-r2`). The token registry test checks all 3,350 records item by item: address shape, uniqueness, on-chain decimals, the icon pack having no holes with each image's hash equal to its id, and Solana's token program binding |
| Native unit tests | **186 tests in 25 suites passed** | The real JavaScriptCore bridge, the wallet-identity signature (`WalletIdentityTests`: the published vector through the bundled runtime, an injected path and message ignored, a new wallet signed at creation, a pre-1.1.0 wallet gated on its password, repair filling it in, a rebuilt index dropping a stale signature), payload view parsing and signature result payloads, signing records storing the fingerprint, the vault and public index HMAC, wallet-level pairing v2 (public index read-only, four Bitcoin script types, three Solana addresses, public index version 1, the identity signature in the payload), Pair prefetching (generated only when permitted, cleared on suspension, expired results discarded), the privacy shield window following the app's appearance, the 2-of-3 recovery card layout, one font size per word grid, recovery privacy (direct reveal, screenshot warning), scan purpose, the compatible wallet list, NFT display, the ten BIP39 languages, the vault password reset, and App Lock gating of the delete confirmation |
| UI automation | **17 tests, 1 known flake** | iPhone 17 Pro · iOS 26.4 simulator, isolated fixtures, public unfunded vectors. Run serially, 16 of 17 pass; `testApprovalNamesAKnownSpenderAndFlagsAnUnlistedOne` fails intermittently because `typeText` drops characters from a long payload under load, and passes when rerun on its own. Its known-contract assertions, which run before the failing line, pass even in the failing run |
| Screenshot tour | **Passed for 1.0.0; Revisions 12–13 ran only their own new shots** | iPhone 17 Pro light and dark (120 shots) and iPhone SE 3rd generation on iOS 17.2 light (60 shots) for 1.0.0. Revision 12 added `testWalletLevelPairingStates` (the Wallet Level page with a signed wallet and with a pre-1.1.0 wallet) and Revision 13 added `testSolanaLookupTableReview` (a v0 transfer whose recipient comes from a lookup table); both were run, the full tour has not been re-run |
| Release device build | **Not re-run in Revision 12** | Last verified for 1.0.0 (1): `generic/platform=iOS`, unsigned, and archiving as Release with a dSYM. The 1.1.0 (2) archive has not been built |
| Clean-room engine rebuild | **Byte-identical** | `npm ci --ignore-scripts` plus `npm run build` in a throwaway copy of the commit reproduces the shipped `signer.js` exactly |
| Bundle | 1,181,026 bytes | SHA-256 `6933d0d8a6f60faa8222506ac0bd7eef80eb884c9f73e31e9f354b4740f21077`, see [engine/bundle-manifest.json](engine/bundle-manifest.json) |

The UI automation flows: onboarding appears once and preserves the import intent; importing and sealing
a wallet; creating (concealed backup, re-reveal, concealment on backgrounding, filling blanks in order,
blanks unchanged after a wrong order, taking a filled word back, clearing filled words and passwords on
backgrounding); the backup page's Recovery Cards (2 of 3), Security Tips and plaintext phrase QR;
importing an unaccented Spanish phrase with language detection, and being asked to choose on an
Italian/Spanish ambiguity; "show the phrase again" returning to the same draft; an import draft
surviving backgrounding; paste a request → automatic match → risk acknowledgement → authorization
cleared on backgrounding → wrong password → sign → Activity → clear; rejecting a request; the whole scan
card opening the camera; Pair and Addresses using public data only; changing the password (a wrong
password reports and stays on the page, the old password stops working, no crash on backgrounding);
renaming and then deleting the last wallet returns to the welcome page; importing an existing phrase
resets that wallet's password in place; App Lock cold launch, Face ID cancellation, wrong password,
unlocking with the wallet password, and no re-lock after a brief backgrounding; and Settings (App Lock
requiring successful biometrics, the Networks & Tokens list and search, the compatibility page surviving
backgrounding, the offline guide).

## Main changes of the rebuild

### Interface

- A new structure, `Features/{Main, Wallets, Setup, Onboarding, Sign, Activity, Settings, Lock}` with a
  shared `Design/`, replacing the old `Views/`.
- Four tabs at the bottom: Wallets · Scan · Activity · Settings. The tab bar stays expanded and does not
  collapse on scroll, so Activity and Settings are always one step away.
- A design system: system grouped backgrounds, cards, Liquid Glass primary and secondary buttons (filled
  and outlined capsules on iOS 17/18), a bottom action bar (`safeAreaBar` on iOS 26), callouts, status
  pills, grouped address display with bold first and last groups, copy confirmations, and status
  announcements VoiceOver can read.
- Wallet cards: an avatar colour derived from the key identity, the name, the master fingerprint (changed
  from Wallet ID to Fingerprint during Revision 3), network icons, and Pair / Addresses shortcuts. The
  detail page covers pairing for all four chains, receiving addresses, the recovery phrase, changing the
  password, renaming, deleting and repair.
- Create and import: unified step pages; live word counting and checking while entering a phrase;
  candidate words above the keyboard; SeedQR support; an optional BIP39 passphrase; password strength and
  a requirements checklist; and a completion page that leads straight to pairing.
- Signing: the whole scan card is tappable; the review page runs summary (amount, counterparty, network
  and token icons) → warnings → signing wallet → full fields → request fingerprint; the risk
  acknowledgement and Sign are pinned to the bottom; the authorization sheet takes the password on its
  own; and the result page shows an animated QR code and can export a file.
- Activity groups by date, has a detail page and can be cleared; Settings holds App Lock, appearance,
  Networks & Tokens with search, compatibility notes, the offline guide, Open Source and the legal
  documents.
- Brand: the app icon, launch screen and in-app mark were redrawn as precise vectors from the original
  "B plus lightning signature band" concept ([design/Brand.md](design/Brand.md), reproducible with
  `scripts/make-brand-assets.py`). The seven network icons for BTC, ETH, BNB Chain, Arbitrum, Base, TRON
  and Solana are vector redraws.
- Text standardized on "this device" to suit both iPhone and iPad, and the camera permission description
  changed to its actual purpose: scanning signing requests and recovery phrase QR codes.

### Security, logic, JavaScript and cryptography

Every problem found by internal review was fixed with a regression test (details in
[docs/Security.md](docs/Security.md#2026-09-21-review-fixes)):

- **F1 (critical)**: EIP-712 values must match their declared types strictly. A truthy string could
  previously be signed as `bool: true` while the interface displayed a string.
- **F2**: `eth-signature`'s `v` is EIP-155 for legacy transactions and y-parity for typed ones.
- **F3–F6, F10–F12**: Safe gas refunds, native currency sent with a call, fees, TRON call value and fee
  limit, non-text TRON messages, Solana durable nonces and transfers of tokens outside the registry are
  all shown in the review and raise the risk level where appropriate; a summary no longer joins one
  transfer's amount to another's address.
- **F7, F14**: ambiguous integer and address spellings are refused; the separator is computed in the
  declared domain order; unused types are ignored.
- **F8**: App Lock's background timer uses a clock that keeps counting while the device sleeps.
- **F9**: vault format 2 uses the stored raw header bytes as AES-GCM authenticated data.
- **F13**: animated QR codes are collected incrementally in a context of their own per scan, the result
  matches batch decoding, and frames from another request are refused.
- **F15**: `ur:psbt` requests are supported, answered with the same type, as are multi-line wrapped
  base64 PSBT files.
- **F16**: Release builds expose only a fixed allowlist of engine operations.
- **F17**: the public index file is authenticated with HMAC-SHA256 under a Keychain key and requires
  repair when tampered with.
- **F18**: Taproot (BIP340) signatures use fresh 32-byte auxiliary randomness.
- Bitcoin change is only acknowledged for outputs re-derived from the signing wallet's own public keys.

Performance and engine boundaries: the BIP39 seed moved to native CommonCrypto. JavaScriptCore has no
JIT on iOS, so PBKDF2 in JavaScript took about 0.6 seconds where native takes a few milliseconds, making
creation, import and signing markedly faster. Every operation touching a secret or external input uses a
fresh JS context; only the address and pairing pages, which read the device's own public index, reuse one
warm context, and that is discarded on entering the background.

### Token registry and icons

- The offline token registry holds **3,350 entries** in two layers. The manually vetted layer has 596
  (Ethereum 196, BNB Smart Chain 112, Arbitrum One 67, Base 86, TRON 14, Solana 121), ordered by actual
  value per network (the lesser of CoinGecko market capitalization and on-chain supply × price) and
  requiring volume, holder count and at least one independent listing as corroboration, excluding equity
  tokens, funds, receipt tokens, deprecated contracts and sanctioned assets. The listing layer's 2,754
  entries come from the CoinMarketCap top 2000 and decide only inclusion and the name, symbol and icon;
  decimals are all read on-chain and symbols are whatever the contract reports. The two layers are not
  distinguished in the interface, and inclusion never implies endorsement. Sources, selection and
  exclusion reasons are in [docs/TokenRegistrySources.md](docs/TokenRegistrySources.md), reproducible with
  `scripts/build-token-registry.py` and `scripts/build-expanded-registry.py`.
- Coverage grew from 6 networks to 10: tokens on Polygon, Avalanche C-Chain, OP Mainnet and Gnosis now
  display with a name and decimals instead of a raw figure.
- There are 1,985 icons (deduplicated by content, at most 128 px), packed into a single
  `TokenIcons.pack` plus an offset table, about 10.7 MiB in all, which the app reads by mmap and decodes
  on demand, never downloading anything. The Networks & Tokens page groups by network and orders by rank,
  with popular tokens first, and searches by symbol, name or address.
- The compatibility page's wallet icons are all official app or repository icons, 23 of them as of
  Revision 3 ([sources](docs/WalletLogoSources.md)).

## Problems found and fixed during testing

- **Crash**: backgrounding the app while the "view recovery phrase" sheet was showing its content crashed
  reliably (a UIKit `NSInternalInconsistencyException`, two navigation bars contending for one navigation
  item). The cause was `.privacySensitive()` wrapped outside the sheet's `NavigationStack`: iOS 26
  conceals privacy-sensitive content when taking a background snapshot, which triggered the conflict. It
  moved onto the inner content, and the fix was verified after reproducing it with a UI test.
- **Swallowed errors**: entering a wrong password when changing the password or deleting a wallet showed
  no message at all. The store called `suspend()` first, invalidating the session, and the sheet then
  discarded the error when comparing sessions. The password is now validated first and a failure displays
  normally. (Nothing was ever wrongly deleted; there was simply no feedback.)
- Navigation reset back to the wallet list after a successful password change. It now stays on the page
  and shows "Password Changed".
- "Show the Phrase Again" on the backup verification page sat at the bottom of the content and overlapped
  the iOS 26 floating bottom bar, so tapping its centre hit the bar instead. It moved into the bar, below
  Continue.
- Tapping a network in Networks & Tokens did nothing (a value-type NavigationLink inside a pushed page),
  and on iOS 26 the token search field was collapsed by default and unreachable by accessibility. The
  search field is now always visible.
- SF Symbols: a backup hint used a non-existent `camera.slash`, leaving a blank icon, and the Wallets
  tab's `wallet.bifold` requires iOS 18 and was missing on iOS 17. Both were replaced with valid symbols
  and given version-appropriate fallbacks. All 74 symbols were checked against the system symbol list.
- iOS 17 and small screens (iPhone SE): disabled primary button text was nearly invisible on a light grey
  background (Sign, Continue, Change Password) and is now grey text, with the busy indicator handled the
  same way; the authorization sheet truncated its text at the medium detent and became scrollable content
  with a fixed Sign at the bottom; onboarding illustrations shrink on short screens so the points are no
  longer hidden behind the bar; the Activity title may wrap to two lines; and "Offline Setup Guide" and
  the legal links in Settings were tinted theme green and now match the body colour of adjacent rows.
- Pushed steps in the create flow crowded Back and Cancel together on the left; Cancel moved to the right
  on pushed steps.
- Visual issues: hyphenation when card button text wrapped; the import status hidden behind the bottom
  bar; candidate words obscured; the risk acknowledgement too far from Sign; empty-state icons too faint;
  inconsistent settings row styles. All corrected.
- The old screenshot flow used the wrong control type for the risk acknowledgement, so it had never
  actually signed anything. Rewritten along with the UI tests.

## Interface review

The screenshot tour (`BitToolSignerUITests/ScreenshotTour.swift`) covers welcome, onboarding, import,
password, create and backup (concealed), the wallet list and detail page, the change password / view
phrase / delete sheets, Pair for four chains, addresses and address details, Scan, paste, review (top,
middle, bottom and acknowledged), authorization, the signature result, Activity and its details,
Settings, Networks & Tokens (ETH, SOL, TRON), the compatibility page, the offline guide and App Lock.
Devices and environments: iPhone 17 Pro light and dark (iOS 26, Liquid Glass); iPhone SE 3rd generation
(iOS 17.2, the smallest screen and the older styling); iPad Air 11-inch (floating top tabs, form-style
sheets, readable width); and AccessibilityL type (badges stack vertically, button text wraps, card
buttons collapse to icons). Problems found during the tour were fixed and re-checked, as listed above.
The tour uses public test wallets only and contains no recovery phrase content.

## Still requiring external acceptance

- **Real devices**: the Keychain and the device passcode, Face ID success/failure/lockout, camera
  scanning, screenshot and recording concealment, file protection and backup exclusion, reinstalling,
  changing the password across a power loss, and the 119/120-second background boundary.
- **Third-party wallet round trips**: pairing → request → signing → scanning back for every wallet listed
  as "can sign by QR" (Sparrow, BlueWallet, Nunchuk, Bitcoin Keeper, BULL Bitcoin, Specter, Bitcoin Safe,
  ZEUS, MetaMask, Rabby, imToken, TokenPocket, Ambire, Solflare, Helium Wallet), plus address import for
  the watch-only wallets, each recorded with a version number. Official documentation and source evidence
  is not the same as completed real-device interoperability.
- **NFT marketplace signatures**: verify Seaport and LooksRare decoding on a real device using
  `eth_signTypedData_v4` requests actually exported by OpenSea and LooksRare.
- **An independent security audit**, a dependency review, and TestFlight / App Store signed distribution.
  Reproducible builds are now covered for the engine artifact — see
  [docs/Reproducible-Build.md](docs/Reproducible-Build.md) — but the App Store executable itself cannot be
  reproduced byte for byte, and that document explains why.
- Token rankings reflect a data snapshot and affect browsing order only, never signing or risk assessment.
