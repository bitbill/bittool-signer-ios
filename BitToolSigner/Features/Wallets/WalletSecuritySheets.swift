import SwiftUI
import Combine

/// Runs one password-authorized wallet operation. Late results are dropped if
/// the sheet closed, the app was backgrounded or another attempt started.
@MainActor
final class WalletOperation: ObservableObject {
    @Published var busy = false
    @Published var error: String?
    private var token = UUID()
    private var task: Task<Void, Never>?

    func run(epoch: UUID, current: @escaping @MainActor () -> UUID,
             _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let id = UUID(); token = id; busy = true; error = nil
        task = Task { @MainActor in
            do { try await work() }
            catch {
                if token == id, epoch == current(), !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if token == id { busy = false }
        }
    }

    func cancel() {
        token = UUID(); task?.cancel(); task = nil; busy = false; error = nil
    }
}

/// Shows a saved wallet's recovery phrase after its password is entered.
///
/// Both states share one scroll container and one toolbar item. Swapping the
/// navigation root (for example Form ↔ ScrollView) while iOS snapshots the app
/// on its way to the background makes UIKit create a second navigation bar for
/// the same item and abort, and backgrounding is exactly when the phrase clears.
struct RecoveryPhraseSheet: View {
    let walletID: UUID
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var operation = WalletOperation()
    @State private var password = ""
    @State private var secret: VaultSecret?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WalletIdentityHeader(walletID: walletID, size: 44)
                    if let secret {
                        RecoveryBackupPanel(words: secret.mnemonic.split(separator: " ").map(String.init),
                                            displayedPassphrase: secret.passphrase,
                                            hasPassphrase: !secret.passphrase.isEmpty)
                        Callout("Anyone with these words can take your funds. Write them on paper and store them offline. Never type them into a website or share a photo.",
                                tone: .warning)
                    } else {
                        passwordForm
                    }
                }
                .padding(Metrics.pagePadding)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .navigationTitle("Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(secret == nil ? "Cancel" : "Done") { clear(); dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(operation.busy)
        .onAppear { store.beginSensitiveSession() }
        .onDisappear { clear(); store.endSensitiveSession() }
        .onChange(of: store.securityEpoch) { _, _ in
            // Backgrounding discards the decrypted phrase; the password is re-entered.
            clear()
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            PasswordField(.walletPassword, text: $password)
                .focused($passwordFocused)
                .submitLabel(.continue)
                .onSubmit(unlock)
                .padding(14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("The recovery phrase stays hidden until you choose to show it.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            if let error = operation.error { Callout(verbatim: error, tone: .danger) }
            Button(action: unlock) { ActionLabel("Continue", busy: operation.busy) }
                .prominentAction()
                .disabled(password.isEmpty || operation.busy)
                .padding(.top, 6)
                .accessibilityIdentifier("vaultManagement.submit")
        }
        .task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            passwordFocused = true
        }
    }

    private func unlock() {
        guard !password.isEmpty, !operation.busy else { return }
        let entered = password, epoch = store.securityEpoch
        password = ""
        operation.run(epoch: epoch, current: { store.securityEpoch }) {
            let revealed = try await store.reveal(walletID: walletID, password: entered)
            guard epoch == store.securityEpoch else { return }
            passwordFocused = false
            secret = revealed
        }
    }

    private func clear() {
        operation.cancel(); password = ""; secret = nil
    }
}

struct ChangePasswordSheet: View {
    private enum Field: Hashable { case current, new, confirmation }
    let walletID: UUID
    var onChanged: () -> Void = {}
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var operation = WalletOperation()
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @FocusState private var focus: Field?

    private var valid: Bool { !current.isEmpty && PasswordPolicy.evaluate(new).isValid && new == confirmation }

    var body: some View {
        NavigationStack {
            Form {
                Section { WalletIdentityHeader(walletID: walletID) }
                Section {
                    PasswordField(.currentWalletPassword, text: $current)
                        .focused($focus, equals: .current).submitLabel(.next).onSubmit { focus = .new }
                }
                Section {
                    PasswordField(.newPassword, text: $new, isNew: true)
                        .focused($focus, equals: .new).submitLabel(.next).onSubmit { focus = .confirmation }
                    PasswordField(.confirmNewPassword, text: $confirmation, isNew: true)
                        .focused($focus, equals: .confirmation).submitLabel(.done).onSubmit { focus = nil }
                } footer: {
                    PasswordRequirementsView(password: new, confirmation: confirmation).padding(.top, 6)
                }
                if let error = operation.error {
                    Section { Callout(verbatim: error, tone: .danger).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                Section {
                    Button(action: submit) { ActionLabel("Change Password", busy: operation.busy) }
                        .prominentAction()
                        .disabled(!valid || operation.busy)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        .accessibilityIdentifier("vaultManagement.submit")
                } footer: {
                    Text("Your recovery phrase, fingerprint and addresses stay the same.")
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { clear(); dismiss() } } }
        }
        .interactiveDismissDisabled(operation.busy)
        .onDisappear(perform: clear)
        .onChange(of: store.securityEpoch) { _, _ in
            if !operation.busy { current = ""; new = ""; confirmation = "" }
        }
    }

    private func submit() {
        guard valid, !operation.busy else { return }
        focus = nil
        let old = current, replacement = new, epoch = store.securityEpoch
        operation.run(epoch: epoch, current: { store.securityEpoch }) {
            try await store.changePassword(walletID: walletID, current: old, new: replacement)
            clear(); dismiss(); onChanged()
        }
    }

    private func clear() {
        operation.cancel(); current = ""; new = ""; confirmation = ""
    }
}

struct DeleteWalletSheet: View {
    let walletID: UUID
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var access: AppAccessController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var operation = WalletOperation()
    @State private var password = ""
    @State private var backedUp = false
    @State private var askingPassword = false
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section { WalletIdentityHeader(walletID: walletID) }
                Section {
                    Callout("This removes the encrypted wallet and its public data from this device. Funds are not affected, but you can only recover them with the recovery phrase and any BIP39 passphrase.",
                            title: "Delete this wallet?", tone: .danger)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Toggle("I confirm I want to delete this wallet", isOn: $backedUp)
                        .accessibilityIdentifier("delete.backupConfirmed")
                } footer: {
                    // Face ID is asked for only where App Lock already uses it.
                    Text(asksForBiometrics
                         ? "Deleting asks for \(access.biometry.name), then for this wallet’s password."
                         : "Deleting asks for this wallet’s password.")
                }
                if let error = operation.error {
                    Section { Callout(verbatim: error, tone: .danger).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                Section {
                    Button(role: .destructive, action: confirm) {
                        ZStack {
                            if operation.busy || confirming { ProgressView().tint(.white) }
                            Label("Delete Wallet", systemImage: "trash")
                                .opacity(operation.busy || confirming ? 0 : 1)
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Palette.danger)
                    .disabled(!backedUp || operation.busy || confirming)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    .accessibilityIdentifier("vaultManagement.submit")
                }
            }
            .navigationTitle("Delete Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { clear(); dismiss() } } }
            .alert("Wallet Password", isPresented: $askingPassword) {
                SecureField("Wallet password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("delete.password")
                Button("Cancel", role: .cancel) { password = "" }
                Button("Delete", role: .destructive, action: submit)
            } message: {
                Text("Enter this wallet’s password to delete it. Without the recovery phrase this cannot be undone.")
            }
        }
        .interactiveDismissDisabled(operation.busy || confirming)
        .onDisappear(perform: clear)
        .onChange(of: store.securityEpoch) { _, _ in if !operation.busy { password = ""; askingPassword = false } }
    }

    /// Whether this delete will ask for biometrics first. App Lock being on is
    /// what decides: with it off, the app uses no biometrics at all and the
    /// password is the only thing asked for.
    private var asksForBiometrics: Bool { access.isEnabled && access.biometry.isAvailable }

    /// Biometrics first for someone who turned App Lock on, then the password:
    /// the password is what actually authorizes the deletion.
    private func confirm() {
        guard backedUp, !operation.busy, !confirming else { return }
        operation.error = nil
        confirming = true
        Task {
            defer { confirming = false }
            do { try await access.confirmSensitiveAction(reason: String(localized: "Confirm before deleting this wallet.", bundle: AppText.bundle)) }
            catch is CancellationError { return }
            catch { /* Biometrics unavailable or failed: the password still decides. */ }
            password = ""
            askingPassword = true
        }
    }

    private func submit() {
        guard backedUp, !operation.busy else { return }
        let entered = password, epoch = store.securityEpoch
        password = ""
        guard !entered.isEmpty else { operation.error = String(localized: "Enter this wallet’s password.", bundle: AppText.bundle); return }
        operation.run(epoch: epoch, current: { store.securityEpoch }) {
            try await store.deleteWallet(walletID: walletID, password: entered)
            clear(); dismiss()
        }
    }

    private func clear() { operation.cancel(); password = ""; backedUp = false; askingPassword = false }
}

struct RepairWalletSheet: View {
    let walletID: UUID
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var operation = WalletOperation()
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { WalletIdentityHeader(walletID: walletID) }
                Section {
                    PasswordField(.walletPassword, text: $password).onSubmit(submit)
                } footer: {
                    Text("BitTool Signer decrypts the wallet once to rebuild its public keys and addresses. Your recovery phrase and password do not change.")
                }
                if let error = operation.error {
                    Section { Callout(verbatim: error, tone: .danger).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                Section {
                    Button(action: submit) { ActionLabel("Repair Wallet", busy: operation.busy) }
                        .prominentAction()
                        .disabled(password.isEmpty || operation.busy)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Repair Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .interactiveDismissDisabled(operation.busy)
        // A typed password is dropped the moment the app is suspended, not
        // held until this sheet happens to go away.
        .onChange(of: store.securityEpoch) { _, _ in if !operation.busy { password = "" } }
        .onDisappear { operation.cancel(); password = "" }
    }

    private func submit() {
        guard !password.isEmpty, !operation.busy else { return }
        let entered = password, epoch = store.securityEpoch
        password = ""
        operation.run(epoch: epoch, current: { store.securityEpoch }) {
            try await store.completeSetup(walletID: walletID, password: entered)
            dismiss()
        }
    }
}
