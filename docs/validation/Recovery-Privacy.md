# Recovery phrase display protection

> **Historical record (2026-09-20).** Later revisions changed this behavior: Revision 2.1 added multi-language import and a new backup screen, and Revision 3 (2026-09-22) made “Tap to Reveal” show the phrase with a single tap (no confirmation alert), replaced the encrypted QR with a plain-text phrase QR and Word Cards with 2-of-3 Recovery Cards. The current behavior is described in [docs/Security.md](../Security.md).

The simplified create/restore flow passed simulator regression on 2026-09-20 using iPhone 16 Pro, iOS 18.6. Earlier results remain separately labeled as historical.

## Behavior

- Creation Step 2 and Settings recovery displays start concealed. Revealing requires an explicit risk confirmation every time the user hides or revisits the display.
- A concealed display contains no word-grid or passphrase accessibility elements. Settings protects the BIP39 passphrase together with the mnemonic.
- Restore input is always a visible multiline `TextEditor`, without a reveal control. Autocorrection, autocapitalization, and content-type autofill semantics are disabled; Writing Tools are disabled on iOS 18 and later. The app separately rejects third-party keyboard extensions. Restoring has two steps: local English BIP39 word-count/dictionary/checksum validation, then wallet-password setup. It skips the creation-only backup display and verification questions. The password page can return to edit the phrase, preserving the draft while clearing passwords; its final action is labeled Restore encrypted vault.
- Creation still has four steps. Step 3 directly shows four random positions with three choices each; it has no hide/reveal control or consent prompt. Backgrounding and screenshot notifications clear selections but retain the same questions and option order.
- Screenshot notifications still warn on every active recovery screen. They also conceal explicitly revealed full-phrase backups and invalidate outstanding reveal consent. Restore input and verification choices remain directly visible after the warning is dismissed.
- Creation's backup acknowledgement is unavailable until its full phrase has been viewed at least once. Restore has no backup acknowledgement requirement.
- Background return preserves the current page and step. Creation's full-phrase backup is concealed again; restore text and verification candidates return visibly, with wallet passwords and question selections cleared. See [background-resume validation](Background-Resume.md).
- The device-passcode explanation card is removed from creation and restore. The underlying device-only Keychain requirement remains unchanged.
- See [four-question verification](Backup-Choices.md) for candidate generation, answer handling, and the new validation scope.

## Current simulator regression — passed

The unified run passed **44 native tests (41 Swift Testing + 3 hosted XCTest) and 8 UI tests**, with no failures or skips. Result: `Test-BitSigner-2026.09.20_20-57-32-+1000.xcresult`, `TEST SUCCEEDED`; log: `/private/tmp/bitsigner-restore-flow-tests.log`. The exported [result summary](Restore-Flow-Results.json) reports 52 tests and 59 executed instances when parameterized cases are included.

`RecoveryInputViewTests` inspected the actual hosted `UITextView`: editable, nonsecure, no password/new-password content type, ASCII-capable keyboard, no autocorrection or autocapitalization, and Writing Tools disabled on iOS 18. `RecoveryScreenshotTests` passed five tests for repeated notifications, old-alert acknowledgements, inactive/background presentation suppression, unmounting/remounting, and callback cleanup. The two hosted screenshot-alert cases exercise the full-phrase consent display; they are not physical screenshot tests of the new visible editor.

The eight UI flows passed: main navigation and invalid restore word count; creation reveal/cancel/hide/revisit and re-concealment after backgrounding; hidden generated 12/24-word backups; visible 12-word public-vector restore through both steps, background retention, empty password fields and editing the phrase again; directly visible creation choices with unchanged questions and cleared selections after backgrounding; wrong-answer rejection and correction without rerandomizing; creation password-step retention with passwords cleared; and Settings compatibility/unlock-sheet retention with the unlock password cleared. The tests do not save a vault. Generated creation drafts are read only in test-process memory, never intentionally logged or attached as screenshots; restore attachments use a public, unfunded BIP39 vector.

The exported light-mode restore screenshot was visually checked: the full-page editor, `STEP 1 / 2`, and main action are readable; no passcode card or hide control appears. [Restore input — public fixture](../../design/Restore-Input-Light.png).

## Remaining checks

Physical-button screenshots, recording/mirroring and system AutoFill presentation on real devices remain unverified. Input-trait inspection does not prove every system suggestion UI is suppressed. The current UI run does not individually cover every supported restore length, unknown-word/checksum-error paths, optional BIP39 passphrase retention, scanner/share-provider transitions, extreme Dynamic Type, or VoiceOver. Real-device Keychain/passcode failure and full encrypted-vault creation/restoration still require acceptance. Screenshot attachments must use only disposable/public fixtures, never user recovery material.

## Historical automated coverage

The previous consent-based flow passed 24 Swift Testing tests (including 9 recovery-privacy tests), 2 hosted screenshot-alert XCTest cases, and 4 UI/launch tests. After correcting its alert presentation binding, the 11 privacy tests and the reveal/cancel/hide/revisit UI flow were rerun successfully. That run contained no SwiftUI publishing-during-update or unbalanced-presentation warnings. Light/dark concealed views and reveal confirmation were inspected visually. These results predate the current restore and verification changes.

`RecoveryPrivacyTests` checks consent, cancellation, screenshot notifications while hidden/visible/pending, stale confirmation, lifecycle/capture events, environment checks, remounting, and observer cleanup.

`RecoveryPrivacyViewTests` hosts SwiftUI content in a temporary window to verify that a screenshot notification presents an actual warning and replaces an open reveal confirmation. It uses a non-sensitive label and does not capture screenshots.

The earlier `BitToolSignerUITests` flow checked default concealment for 12/24 words, masked restore input, reveal/cancel/hide, revisiting the backup page, backgrounding, and recovery validation. Its masked-restore expectations do not describe the current product. Current results are recorded separately above; this historical record is retained unchanged in scope.

Run from the repository root with a suitable simulator destination:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project BitToolSigner.xcodeproj -scheme BitSigner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

## Platform boundary

Screenshot tests inject the documented notification; they do not claim physical-device button testing. A simulator screenshot export does not reliably exercise that notification. Before distribution, repeat the screenshot, recording, app-switcher, and return-to-page checks on a real device using a disposable test phrase.

[Apple documents](https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification) that screenshot notifications arrive after capture. BitSigner cannot retract the captured image. Its warning explains possible photo-library access/cloud synchronization and asks the user to delete captured and synced copies.

Historical full-phrase backup previews: [light](../../design/Recovery-Hidden-Light.png), [dark](../../design/Recovery-Hidden-Dark.png), [reveal confirmation](../../design/Recovery-Reveal-Confirmation.png). These concealed previews do not represent the directly visible restore editor or verification screen.
