# Direct signing and scanner feedback

Final 2026-09-21 result: **52/52 engine tests, 57 native tests, and three targeted UI flows passed**. The older 44-native/8-UI pass predates these changes; the full creation/restore UI suite was not rerun in the final run.

## User flow and authorization

1. Open Sign and scan, paste, or import a public request. Account viewing can remain locked, and a request can be reviewed even before a local vault exists.
2. Check the decoded transaction, warnings, and request commitment. Select the intended signing wallet from the review screen.
3. Acknowledge the warnings and enter that wallet's password once to authorize this signature.
4. Return the completed public response by QR or file to the originating wallet. BitSigner does not broadcast it.

Each signature opens the selected encrypted vault afresh. Wallet ID, canonical reviewed hash, request generation, and authorization generation remain checked across authentication, signing, and response encoding. Signing does not derive or open an account-viewing session as a prerequisite or side effect. Expected-signer and transaction-validation rules remain enforced by the engine.

Selecting a different signer retains the unsigned review and revokes previous authorization. Account viewing, pairing, and history still use a single-wallet unlock session. Its inactivity rule checks every 15 seconds for more than 120 seconds since the last recorded activity; it does not expire exactly two minutes after unlock.

The native privacy cover hides the app while inactive/backgrounded. On return, the retained unsigned review or completed response is available without account unlock, but the signature password and risk acknowledgement are empty. Suspension invalidates in-flight signing, so late results cannot publish. Explicit manual lock and general wallet navigation retain their hard-reset behavior. If manual lock leaves the signing view mounted, the view restarts sensitive-session tracking so newly entered credentials remain subject to inactivity clearing. Activity history stays hidden while locked; a successful signature appends to the existing bounded journal without revealing prior entries. An unreadable journal is reported instead of overwritten.

## imToken diagnosis and scanner feedback

The supplied imToken image was decoded locally without upload. It contains one textual `eth-sign-request` UR, 330 UTF-8 bytes. Its request-ID field is an opaque 36-byte value; the previous implementation rejected anything other than 16 bytes. The original image and transaction payload are not checked into the repository.

The ETH transport now accepts nonempty IDs up to 64 bytes and returns the exact received bytes in `eth-signature`. This is a bounded transport compatibility change, not a relaxation of address, transaction, or reviewed-hash validation. Concrete protocol errors are preserved through dispatch instead of being replaced by a generic decoding failure. [Compatibility.md](../Compatibility.md) owns the detailed transport rules.

The camera sheet now shows recognized/processing status, animated-frame progress, protocol errors, and Scan again. Camera errors are separate. Detected codes with no readable text, empty text, or oversized frames receive explicit messages. The metadata handler considers all detected QR codes and favors readable ones. Repeated identical frames are throttled for one second using monotonic uptime; a changed animated frame is delivered immediately, and a held frame can be retried after that interval.

The final bundled engine successfully decoded and reviewed this actual request locally. No signature or broadcast of the supplied request was performed. This does not establish physical-camera behavior or imToken accepting a returned signature; those remain separate acceptance steps.

## Final verification — passed

- Native session tests: locked import/scan/review and one-operation signing without account derivation; selected-wallet/request binding; wallet changes or background suspension during signing; private history append and unreadable-journal preservation. Controlled engine pauses exercise completion races; these tests do not simulate a third-party wallet.
- Six scanner-frame tests: explicit failures for unreadable/empty data, UTF-8 byte-size bounds, repeated-frame retry timing, distinct animated frames and byte preservation, recovery after an unreadable frame, and clock rollback handling.
- Three UI flows: `testLockedSigningCanScanAndReviewWithoutUnlock`, `testVaultNavigationAndRecoveryValidation`, and `testSettingsSheetsSurviveBackgroundAndUnlockPasswordClears`. The first opens scanning while locked, checks an unsupported pasted request's error, reviews a public transaction, selects its risk acknowledgement and enters a public test password, then backgrounds the app. On return, review remains available without an unlock gate, the password is empty, and risk acceptance is cleared. The other two cover navigation/invalid restore input and Settings/unlock-sheet retention. No full creation/restore UI rerun is claimed.
- Protocol regressions: bounded non-16-byte ETH request IDs, byte-preserving response correlation, and preservation of specific dispatch errors, using synthetic/public fixtures rather than the supplied transaction.

Xcode reported `TEST SUCCEEDED` on iPhone 16 Pro / iOS 18.6 for `/private/tmp/BitSignerDerived/Logs/Test/Test-BitSigner-2026.09.21_10-02-50-+1000.xcresult`. The 57 native tests comprise 54 Swift Testing tests and three hosted XCTest cases. The [exported summary](Direct-Signing-Results.json) records 60 unique native/UI tests and 67 device executions including parameterized instances, with zero failures and skips. Engine tests separately passed 52/52.

Final `BitToolSigner/Resources/signer.js`: **619,836 bytes**; SHA-256 `3e334507d2616af21b8fbb61e2309baac272035f250d9529ced925b0cdfc8c74`. The supplied imToken request's local decode/review check used this bundle. Physical-camera scanning and a real imToken signature round trip remain unverified.

## Remaining acceptance

Use a disposable wallet to test the exact installed imToken version: physical-camera scan, correct network and full transaction review, wrong-wallet rejection, fresh password authorization, and successful response collection by imToken. Separately test animated UR collection, denied/restored camera permission, retry after a protocol error, and background interruption on physical devices. Any broadcast or on-chain confirmation is a separate action and result; generating a signature alone does not prove either occurred.
