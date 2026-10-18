import SwiftUI
import UIKit

/// Secure text entry for wallet passwords. `isNew` avoids iOS strong-password
/// suggestions that would store the wallet password in a synced keychain.
/// `revealable` adds an eye button: a BIP39 passphrase that is mistyped opens a
/// different wallet without any error, so it has to be possible to read it back.
/// Revealed text is hidden again as soon as the app leaves the foreground.
struct PasswordField: View {
    /// Shown as the placeholder, and translated.
    let title: LocalizedStringKey
    /// The English source text, kept as the accessibility identifier so the
    /// field is addressable whatever the interface language is.
    let identifier: String
    /// The resolved placeholder, for the UIKit-backed field.
    let placeholder: String
    @Binding var text: String
    /// A secret being set for the first time. iOS AutoFill is kept away from
    /// these: its strong-password flow replaces what is typed, which for a BIP39
    /// passphrase silently produces a different wallet.
    var isNew = false
    /// Adds an eye button. Used for the passphrase, where a typo cannot be
    /// noticed any other way.
    var revealable = false

    @State private var revealed = false
    @Environment(\.scenePhase) private var scenePhase

    init(_ kind: Kind, text: Binding<String>, isNew: Bool = false, revealable: Bool = false) {
        title = kind.title; identifier = kind.rawValue; placeholder = kind.placeholder
        _text = text; self.isNew = isNew; self.revealable = revealable
    }

    /// Which secret the field asks for. The raw value is the English source
    /// text and doubles as the accessibility identifier, so the field is
    /// addressable the same way in every language.
    enum Kind: String {
        case walletPassword = "Wallet password"
        case confirmPassword = "Confirm password"
        case currentWalletPassword = "Current wallet password"
        case newPassword = "New password"
        case confirmNewPassword = "Confirm new password"
        case passphrase = "BIP39 passphrase"
        case confirmPassphrase = "Confirm passphrase"

        var title: LocalizedStringKey {
            switch self {
            case .walletPassword: "Wallet password"
            case .confirmPassword: "Confirm password"
            case .currentWalletPassword: "Current wallet password"
            case .newPassword: "New password"
            case .confirmNewPassword: "Confirm new password"
            case .passphrase: "BIP39 passphrase"
            case .confirmPassphrase: "Confirm passphrase"
            }
        }

        /// The placeholder for the UIKit-backed field, which needs a resolved
        /// string rather than a key.
        var placeholder: String { NSLocalizedString(rawValue, bundle: AppText.bundle, comment: "") }
    }

    var body: some View {
        // Only the revealable (passphrase) field is backed by UIKit: every other
        // password field here is plain SwiftUI and stays that way.
        if !revealable {
            SecureField(title, text: $text)
                .textContentType(isNew ? nil : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier(identifier)
        } else {
            revealableField
        }
    }

    private var revealableField: some View {
        HStack(spacing: 10) {
            MaskedTextField(placeholder: placeholder, identifier: identifier, text: $text, secure: !revealed, isNew: isNew)
                .frame(maxWidth: .infinity)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide secret" : "Show secret")
            .accessibilityIdentifier(identifier + ".reveal")
        }
        // Leaving the foreground conceals it again, like every other secret here.
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
    }
}

/// One UITextField, kept alive across reveals: secure entry is a property on it
/// rather than a different view, so nothing typed is lost when it is switched.
private struct MaskedTextField: UIViewRepresentable {
    let placeholder: String
    let identifier: String
    @Binding var text: String
    let secure: Bool
    let isNew: Bool

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .never
        // No AutoFill on a secret being set here: iOS would offer (and insert) a
        // generated strong password, and a BIP39 passphrase that iOS invented is
        // a different wallet. An empty content type turns the heuristics off;
        // passwordRules keeps the generator from being offered at all.
        field.textContentType = isNew ? UITextContentType(rawValue: "") : .password
        if isNew { field.passwordRules = UITextInputPasswordRules(descriptor: "") }
        field.isSecureTextEntry = secure
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        // Nothing else on this screen dismisses the keyboard, and the field sits
        // right above the action bar, so it carries its own Done button.
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        bar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                     UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator,
                                     action: #selector(Coordinator.done(_:)))]
        bar.sizeToFit()
        field.inputAccessoryView = bar
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        // Never write into a field someone is typing in: a stale value from an
        // update that happens between keystrokes would wipe what they just typed.
        if !field.isFirstResponder, field.text != text { field.text = text }
        if field.isSecureTextEntry != secure {
            // iOS clears a focused field when secure entry flips; put it back.
            let current = field.text
            field.isSecureTextEntry = secure
            field.text = current
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        @objc func done(_ sender: UIBarButtonItem) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

/// Live checklist for the wallet password policy.
struct PasswordRequirementsView: View {
    let password: String
    let confirmation: String

    var body: some View {
        let evaluation = PasswordPolicy.evaluate(password)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < strength(evaluation) ? color(evaluation) : Color(uiColor: .systemFill))
                        .frame(height: 4)
                }
            }
            .animation(.smooth(duration: 0.2), value: strength(evaluation))
            .accessibilityHidden(true)
            requirement("8 to 64 characters", met: evaluation.hasValidLength)
            requirement("3 of: uppercase, lowercase, number, symbol", met: evaluation.categories >= 3)
            requirement("Passwords match", met: !confirmation.isEmpty && password == confirmation)
        }
        .font(.footnote)
    }

    private func strength(_ evaluation: PasswordPolicy.Evaluation) -> Int {
        guard !password.isEmpty else { return 0 }
        guard evaluation.isValid else { return 1 }
        return password.count >= 16 && evaluation.categories == 4 ? 4 : password.count >= 12 ? 3 : 2
    }

    private func color(_ evaluation: PasswordPolicy.Evaluation) -> Color {
        switch strength(evaluation) {
        case 1: Palette.warning
        case 2: Color(uiColor: .systemYellow)
        default: Palette.success
        }
    }

    private func requirement(_ text: LocalizedStringKey, met: Bool) -> some View {
        Label {
            Text(text).foregroundStyle(met ? .primary : .secondary)
        } icon: {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? Palette.success : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(met ? "Met" : "Not met")
    }
}

/// Wallet name, identity color and ID; used wherever a wallet must be recognised
/// before entering its password.
struct WalletIdentityHeader: View {
    let walletID: UUID
    var size: CGFloat = 56
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 14) {
            WalletAvatar(identity: store.avatarIdentity(for: walletID), name: store.walletLabel(for: walletID), size: size)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.walletLabel(for: walletID)).font(.headline)
                Text("Fingerprint \(store.fingerprint(for: walletID))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
