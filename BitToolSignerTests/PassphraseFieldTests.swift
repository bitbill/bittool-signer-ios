import SwiftUI
import Testing
@testable import BitToolSigner

/// The BIP39 passphrase can be read back: a mistyped one opens a different
/// wallet with no error at all, so it must be possible to check it.
@MainActor
struct PassphraseFieldTests {
    @Test func onlyPassphraseFieldsOfferTheEyeButton() throws {
        let passphrase = PasswordField(.passphrase, text: .constant(""), isNew: true, revealable: true)
        #expect(passphrase.revealable)
        let password = PasswordField(.walletPassword, text: .constant(""))
        #expect(!password.revealable, "Wallet passwords stay concealed.")
    }

    @Test func setupShowsTheEyeOnBothPassphraseFields() throws {
        let source = try String(contentsOf: #require(URL(string: "file://" + #filePath))
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BitToolSigner/Features/Setup/WalletSetupFlow.swift"), encoding: .utf8)
        #expect(source.contains(#"PasswordField(.passphrase, text: $model.passphrase, isNew: true, revealable: true)"#))
        #expect(source.contains(#"PasswordField(.confirmPassphrase, text: $model.passphraseConfirmation, isNew: true, revealable: true)"#))
    }

    /// The field is addressed by its English source text whatever the
    /// interface language is, so the UI tests keep working when it is
    /// translated.
    @Test func theAccessibilityIdentifierStaysTheEnglishSourceText() {
        for kind in [PasswordField.Kind.walletPassword, .confirmPassword, .currentWalletPassword,
                     .newPassword, .confirmNewPassword, .passphrase, .confirmPassphrase] {
            let field = PasswordField(kind, text: .constant(""))
            #expect(field.identifier == kind.rawValue)
            #expect(!field.placeholder.isEmpty, "\(kind.rawValue) resolves a placeholder")
        }
        #expect(PasswordField.Kind.walletPassword.rawValue == "Wallet password")
        #expect(PasswordField.Kind.confirmPassphrase.rawValue == "Confirm passphrase")
    }
}
