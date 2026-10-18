import SwiftUI
import Combine

/// In-memory draft for one create/import flow. Secrets live only here, only
/// until the flow closes. Backgrounding clears passwords and backup answers;
/// the phrase draft itself is kept so the person can continue.
@MainActor
final class WalletSetupModel: ObservableObject {
    enum Step: Hashable { case backup, verify, password, done }

    let intent: SetupIntent
    @Published var path: [Step] = []
    @Published var name: String
    @Published var wordCount = 24
    @Published var usePassphrase = false
    @Published var passphrase = ""
    @Published var passphraseConfirmation = ""
    @Published var phraseInput = ""
    @Published private(set) var mnemonic = ""
    /// Language of an imported phrase; generated phrases are English.
    @Published private(set) var importedLanguage: BIP39Language?
    /// Readings to choose from when typed words fit more than one language.
    @Published var languageChoices: [BIP39Mnemonic.Canonical] = []
    /// A phrase read from a QR code, taken with its exact spelling while unedited.
    private var scannedPhrase: String?
    @Published var hasRevealedBackup = false
    @Published var verification: BackupVerification?
    @Published var password = ""
    @Published var confirmation = ""
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var created: VaultMetadata?
    private var operation = UUID()

    init(intent: SetupIntent, existingWallets: Int) {
        self.intent = intent
        name = existingWallets == 0 ? String(localized: "My Wallet", bundle: AppText.bundle)
                                    : String(localized: "Wallet \(existingWallets + 1)", bundle: AppText.bundle)
    }

    var words: [String] { mnemonic.split(separator: " ").map(String.init) }
    var hasDraftSecrets: Bool {
        created == nil && (!mnemonic.isEmpty || !phraseInput.isEmpty || !passphrase.isEmpty || !password.isEmpty)
    }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var passwordValid: Bool { PasswordPolicy.evaluate(password).isValid && password == confirmation }
    var passphraseValid: Bool { !usePassphrase || (!passphrase.isEmpty && passphrase == passphraseConfirmation) }

    // MARK: Steps

    func startCreate(store: AppStore) {
        guard validateOptions() else { return }
        perform(store: store) { [self] token in
            if mnemonic.isEmpty || words.count != wordCount {
                let generated = try await store.generateMnemonic(wordCount: wordCount)
                guard operation == token else { return }
                mnemonic = generated
                hasRevealedBackup = false; verification = nil
            }
            path = [.backup]
        }
    }

    func startImport(store: AppStore) {
        guard validateOptions() else { return }
        // Any of the ten BIP39 languages. Words typed without accents, or Chinese
        // typed without spaces, become the canonical words the seed is derived
        // from. When that fits more than one language, the person chooses.
        // A scanned QR code carries the exact words, so an exact-spelling
        // reading wins without asking (for example an Italian phrase whose
        // unaccented words would also read as Spanish).
        if let scannedPhrase, scannedPhrase == phraseInput,
           let canonical = try? BIP39Mnemonic.validatedCanonical(scannedPhrase) {
            acceptImport(canonical)
            return
        }
        do {
            let readings = try BIP39Mnemonic.interpretations(phraseInput)
            if readings.count == 1 { acceptImport(readings[0]) } else { languageChoices = readings }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func acceptImport(_ reading: BIP39Mnemonic.Canonical) {
        languageChoices = []
        mnemonic = reading.phrase
        importedLanguage = reading.language
        error = nil
        path = [.password]
    }

    /// Fills the import form from a scanned QR code (words or SeedQR).
    func applyScanned(phrase: String) {
        scannedPhrase = phrase
        phraseInput = phrase
        error = nil
    }

    /// "I've written down the words in order": starts the fill-in check.
    func confirmBackup() {
        guard hasRevealedBackup, !words.isEmpty else { return }
        do {
            verification = try BackupVerification(words: words)
            error = nil
            path.append(.verify)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func place(chipID: Int) {
        _ = verification?.place(chipID: chipID)
        error = nil
    }

    func clear(position: Int) {
        verification?.clear(position: position)
        error = nil
    }

    func select(position: Int) {
        verification?.select(position: position)
    }

    func finishVerification() {
        guard verification?.isCorrect == true else {
            error = String(localized: "Some words don't match. Check your written backup and try again.", bundle: AppText.bundle)
            verification?.resetPlacements()
            return
        }
        error = nil
        path.append(.password)
    }

    func reviewPhraseAgain() {
        verification = nil; error = nil
        path = [.backup]
    }

    func createWallet(store: AppStore) {
        guard passwordValid, !mnemonic.isEmpty else { return }
        let name = trimmedName, mnemonic = mnemonic, password = password
        let passphrase = usePassphrase ? passphrase : ""
        perform(store: store) { [self] _ in
            // A committed wallet is the success boundary, even if the app was
            // backgrounded while saving: never invite a duplicate import.
            let wallet = try await store.createWallet(name: name, mnemonic: mnemonic, passphrase: passphrase, password: password)
            created = wallet
            clearSecrets()
            path.append(.done)
        }
    }

    // MARK: Lifecycle

    func suspend() {
        operation = UUID(); busy = false
        password = ""; confirmation = ""; error = nil
        verification?.resetPlacements()
    }

    func clearSecrets() {
        operation = UUID(); busy = false
        mnemonic = ""; importedLanguage = nil; languageChoices = []; scannedPhrase = nil; phraseInput = ""; passphrase = ""; passphraseConfirmation = ""
        password = ""; confirmation = ""; verification = nil
        hasRevealedBackup = false
    }

    private func validateOptions() -> Bool {
        guard !trimmedName.isEmpty else { error = String(localized: "Enter a wallet name.", bundle: AppText.bundle); return false }
        guard trimmedName.count <= 40 else { error = String(localized: "Use a wallet name of 40 characters or fewer.", bundle: AppText.bundle); return false }
        guard passphraseValid else { error = String(localized: "The BIP39 passphrases must match and cannot be empty.", bundle: AppText.bundle); return false }
        error = nil
        return true
    }

    private func perform(store: AppStore, _ work: @escaping @MainActor (UUID) async throws -> Void) {
        guard !busy else { return }
        let id = UUID(), epoch = store.securityEpoch
        operation = id; busy = true; error = nil
        Task { @MainActor in
            do {
                guard epoch == store.securityEpoch else { throw CancellationError() }
                try await work(id)
            } catch {
                if operation == id, epoch == store.securityEpoch, !(error is CancellationError) {
                    self.error = error.localizedDescription
                }
            }
            if operation == id { busy = false }
        }
    }
}
