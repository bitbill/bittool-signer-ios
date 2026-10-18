import SwiftUI

struct WalletSetupFlow: View {
    let presentation: AppRouter.SetupPresentation
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingVersionCompleted") private var onboardingVersion = 0
    @StateObject private var model: WalletSetupModel
    @State private var introductionDone: Bool
    @State private var confirmDiscard = false

    init(presentation: AppRouter.SetupPresentation, existingWallets: Int = 0) {
        self.presentation = presentation
        _model = StateObject(wrappedValue: WalletSetupModel(intent: presentation.intent, existingWallets: existingWallets))
        _introductionDone = State(initialValue: !presentation.showsIntroduction)
    }

    var body: some View {
        Group {
            if introductionDone {
                NavigationStack(path: $model.path) {
                    Group {
                        switch model.intent {
                        case .create: CreateWalletStep(model: model)
                        case .restore: ImportWalletStep(model: model)
                        }
                    }
                    .toolbar { cancelItem() }
                    .navigationDestination(for: WalletSetupModel.Step.self) { step in
                        destination(step)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                OnboardingView(intent: presentation.intent) {
                    onboardingVersion = 1
                    withAnimation(.smooth) { introductionDone = true }
                } onCancel: {
                    dismiss()
                }
                .transition(.opacity)
            }
        }
        .interactiveDismissDisabled(model.hasDraftSecrets || model.busy || model.created != nil)
        .confirmationDialog("Discard this wallet?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.clearSecrets(); dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(model.intent == .create
                 ? "The recovery phrase shown here will be erased. If you already wrote it down, it will not be used."
                 : "The words you entered will be erased from this screen.")
        }
        .onAppear { store.beginSensitiveSession() }
        .onDisappear { model.clearSecrets(); store.endSensitiveSession() }
        .onChange(of: store.securityEpoch) { _, _ in model.suspend() }
        .onChange(of: store.navigationResetEpoch) { _, _ in if model.created == nil { model.clearSecrets() } }
    }

    /// The first step shows Cancel on the leading side. Pushed steps keep the
    /// back button there and show Cancel on the trailing side, as iOS does.
    @ToolbarContentBuilder private func cancelItem(pushed: Bool = false) -> some ToolbarContent {
        ToolbarItem(placement: pushed ? .topBarTrailing : .cancellationAction) {
            Button("Cancel") {
                if model.hasDraftSecrets { confirmDiscard = true } else { dismiss() }
            }
            .disabled(model.busy)
        }
    }

    @ViewBuilder private func destination(_ step: WalletSetupModel.Step) -> some View {
        switch step {
        case .backup: BackupPhraseStep(model: model).toolbar { cancelItem(pushed: true) }
        case .verify: VerifyBackupStep(model: model).toolbar { cancelItem(pushed: true) }
        case .password: SetPasswordStep(model: model).toolbar { cancelItem(pushed: true) }
        case .done:
            SetupCompleteStep(model: model) { route in
                router.finishSetup(opening: route)
            }
        }
    }
}

// MARK: - Steps

/// Shared scaffold: progress, title, explanation, content and a bottom action.
private struct SetupScaffold<Content: View, Footer: View>: View {
    let step: Int
    let total: Int
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    /// Scrolled into view whenever it changes.
    var focusID: String? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Step \(step) of \(total)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        Text(message).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    content
                }
                .padding(Metrics.pagePadding)
                .readableWidth()
            }
            .onChange(of: focusID) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background)
        .bottomActionBar { footer }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CreateWalletStep: View {
    @ObservedObject var model: WalletSetupModel
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SetupScaffold(step: 1, total: 4, title: "Create a Wallet",
                      message: "BitTool Signer creates a new recovery phrase on this device. It works for Bitcoin, EVM networks, TRON and Solana.") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wallet name").font(.subheadline.weight(.semibold))
                TextField("Wallet name", text: $model.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .padding(14)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onChange(of: model.name) { _, value in if value.count > 40 { model.name = String(value.prefix(40)) } }
                    .accessibilityIdentifier("setup.name")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Recovery phrase length").font(.subheadline.weight(.semibold))
                Picker("Recovery phrase length", selection: $model.wordCount) {
                    Text("24 words").tag(24)
                    Text("12 words").tag(12)
                }
                .pickerStyle(.segmented)
                Text("Both are secure. 24 words is common for long-term storage.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            PassphraseOptions(model: model)
        } footer: {
            if let error = model.error { Callout(verbatim: error, tone: .danger) }
            Button { model.startCreate(store: store) } label: {
                ActionLabel("Create Recovery Phrase", busy: model.busy)
            }
            .prominentAction()
            .disabled(model.busy || model.trimmedName.isEmpty || !model.passphraseValid)
            .accessibilityIdentifier("setup.create")
        }
        .navigationTitle("New Wallet")
    }
}

private struct ImportWalletStep: View {
    @ObservedObject var model: WalletSetupModel
    @EnvironmentObject private var store: AppStore
    @State private var scanning = false
    @State private var scanError: String?
    @FocusState private var phraseFocused: Bool

    var body: some View {
        SetupScaffold(step: 1, total: 2, title: "Import a Wallet",
                      message: "Enter the 12, 15, 18, 21 or 24 words of an existing BIP39 recovery phrase, in any of the ten BIP39 languages.") {
            VStack(alignment: .leading, spacing: 10) {
                RecoveryPhraseStatus(text: model.phraseInput)
                RecoveryPhraseInput(text: $model.phraseInput)
                    .focused($phraseFocused)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Wallet name").font(.subheadline.weight(.semibold))
                TextField("Wallet name", text: $model.name)
                    .textInputAutocapitalization(.words)
                    .padding(14)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onChange(of: model.name) { _, value in if value.count > 40 { model.name = String(value.prefix(40)) } }
                    .accessibilityIdentifier("setup.name")
            }
            PassphraseOptions(model: model)
        } footer: {
            if let error = model.error { Callout(verbatim: error, tone: .danger) }
            Button { model.startImport(store: store) } label: {
                ActionLabel("Continue", busy: model.busy)
            }
            .prominentAction()
            .disabled(model.busy || model.phraseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("setup.import")
        }
        .navigationTitle("Import Wallet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { scanError = nil; scanning = true } label: {
                    Label("Scan Recovery QR", systemImage: "qrcode.viewfinder")
                }
            }
            // Word completions sit directly above the keyboard, like QuickType.
            ToolbarItemGroup(placement: .keyboard) {
                if phraseFocused {
                    RecoveryPhraseAssistant(text: $model.phraseInput)
                    Spacer(minLength: 0)
                    Button("Done") { phraseFocused = false }.fontWeight(.semibold)
                }
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerView(title: "Scan Recovery QR", hint: "Scan a QR code containing the words (such as BitTool Signer’s recovery phrase QR code) or a Standard SeedQR.",
                          purpose: .recoveryPhrase,
                          error: scanError, onReset: { scanError = nil }) { text in
                if let words = BIP39Wordlist.shared.words(fromSeedQR: text) {
                    model.applyScanned(phrase: words.joined(separator: " ")); scanning = false
                } else if (try? BIP39Mnemonic.interpretations(text))?.isEmpty == false {
                    model.applyScanned(phrase: text.trimmingCharacters(in: .whitespacesAndNewlines)); scanning = false
                } else {
                    scanError = "This QR code does not contain a recovery phrase."
                }
            }
        }
        .confirmationDialog("Which language is your backup in?",
                            isPresented: Binding(get: { !model.languageChoices.isEmpty },
                                                 set: { if !$0 { model.languageChoices = [] } }),
                            titleVisibility: .visible) {
            ForEach(model.languageChoices, id: \.phrase) { reading in
                Button("\(reading.language.displayName): \(reading.words.prefix(3).joined(separator: " "))…") {
                    model.acceptImport(reading)
                }
            }
        } message: {
            Text("These words are valid in more than one language, and each language gives a different wallet. Choose the language your backup is written in.")
        }
    }
}

private struct PassphraseOptions: View {
    private enum Field { case passphrase, confirmation }

    @ObservedObject var model: WalletSetupModel
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $model.usePassphrase.animation(.snappy)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BIP39 passphrase").font(.subheadline.weight(.semibold))
                    Text("Advanced. Adds a “25th word”.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("setup.usePassphrase")
            if model.usePassphrase {
                VStack(spacing: 0) {
                    PasswordField(.passphrase, text: $model.passphrase, isNew: true, revealable: true)
                        .focused($focus, equals: .passphrase).submitLabel(.next).onSubmit { focus = .confirmation }
                        .padding(14)
                    Divider().padding(.leading, 14)
                    PasswordField(.confirmPassphrase, text: $model.passphraseConfirmation, isNew: true, revealable: true)
                        .focused($focus, equals: .confirmation).submitLabel(.done).onSubmit { focus = nil }
                        .padding(14)
                }
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Callout("Each passphrase opens a different wallet. Back it up separately: the recovery phrase alone cannot restore this wallet. It is not your wallet password.",
                        tone: .warning)
            }
        }
        .cardBackground()
    }
}

private struct BackupPhraseStep: View {
    @ObservedObject var model: WalletSetupModel
    @EnvironmentObject private var store: AppStore
    @State private var showingTips = false

    var body: some View {
        SetupScaffold(step: 2, total: 4, title: "Back Up Your Phrase",
                      message: "Write these \(model.words.count) words on paper, in order, and keep them safe. You’ll confirm them on the next screen.") {
            RecoveryBackupPanel(words: model.words,
                                hasPassphrase: model.usePassphrase && !model.passphrase.isEmpty,
                                showsTipsLink: false,
                                isCovered: showingTips) {
                model.hasRevealedBackup = true
            }
            // Backgrounding conceals the phrase and closes the recovery cards.
            .id(store.securityEpoch)
        } footer: {
            if let error = model.error { Callout(verbatim: error, tone: .danger) }
            SecurityTipsButton { showingTips = true }
            Button { model.confirmBackup() } label: {
                ActionLabel("I’ve Written Them Down in Order")
            }
            .prominentAction()
            .disabled(!model.hasRevealedBackup)
            .accessibilityIdentifier("backup.continue")
            if !model.hasRevealedBackup {
                Text("Reveal the words first.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Recovery Phrase")
        .sheet(isPresented: $showingTips) { SecurityTipsSheet() }
    }
}

private struct VerifyBackupStep: View {
    @ObservedObject var model: WalletSetupModel

    var body: some View {
        SetupScaffold(step: 3, total: 4, title: "Check Your Backup",
                      message: "Using your written copy, tap the missing words in order. Tap a blank to choose it, or a filled blank to change it.",
                      focusID: model.verification?.activePosition.map(BackupVerificationGrid.scrollID)) {
            if let verification = model.verification {
                BackupVerificationGrid(verification: verification,
                                       onSelect: { model.select(position: $0) },
                                       onClear: { model.clear(position: $0) })
            }
        } footer: {
            if let error = model.error { Callout(verbatim: error, tone: .danger) }
            if let verification = model.verification {
                BackupVerificationChips(verification: verification) { model.place(chipID: $0) }
                    .padding(.bottom, 4)
            }
            Button { model.finishVerification() } label: { ActionLabel("Confirm") }
                .prominentAction()
                .disabled(model.verification?.isComplete != true)
                .accessibilityIdentifier("verification.continue")
            Button("Show the Phrase Again") { model.reviewPhraseAgain() }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 36)
                .accessibilityIdentifier("verification.showPhrase")
        }
        .navigationTitle("Verify")
        .recoveryScreenshotWarning { model.verification?.resetPlacements(); model.error = nil }
    }
}

private struct SetPasswordStep: View {
    private enum Field: Hashable { case password, confirmation }
    @ObservedObject var model: WalletSetupModel
    @EnvironmentObject private var store: AppStore
    @FocusState private var focus: Field?

    var body: some View {
        SetupScaffold(step: model.intent == .create ? 4 : 2, total: model.intent == .create ? 4 : 2,
                      title: "Set a Password",
                      message: "The password encrypts this wallet on this device and authorizes every signature. It is not part of your recovery phrase.") {
            VStack(spacing: 0) {
                PasswordField(.walletPassword, text: $model.password, isNew: true)
                    .focused($focus, equals: .password).submitLabel(.next).onSubmit { focus = .confirmation }
                    .padding(14)
                Divider().padding(.leading, 14)
                PasswordField(.confirmPassword, text: $model.confirmation, isNew: true)
                    .focused($focus, equals: .confirmation).submitLabel(.done).onSubmit { focus = nil }
                    .padding(14)
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            PasswordRequirementsView(password: model.password, confirmation: model.confirmation)
                .padding(.horizontal, 4)
            Callout("If you forget this password, delete the wallet and import it again with the recovery phrase.")
        } footer: {
            if let error = model.error { Callout(verbatim: error, tone: .danger) }
            Button {
                focus = nil
                model.createWallet(store: store)
            } label: {
                ActionLabel(model.intent == .create ? "Create Wallet" : "Import Wallet", busy: model.busy)
            }
            .prominentAction()
            .disabled(!model.passwordValid || model.busy)
            .accessibilityIdentifier("setup.finish")
        }
        .navigationTitle("Password")
        .navigationBarBackButtonHidden(model.busy)
    }
}

private struct SetupCompleteStep: View {
    @ObservedObject var model: WalletSetupModel
    let finish: (WalletRoute?) -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SymbolHero(systemImage: "checkmark.seal.fill", color: Palette.success, size: 64)
                    .padding(.top, 24)
                VStack(spacing: 8) {
                    Text(model.intent == .create ? "Wallet Created" : "Wallet Imported")
                        .font(.largeTitle.weight(.bold))
                    Text("Your keys are encrypted on this device. Next, pair a watch-only wallet to receive funds and prepare transactions.")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let wallet = model.created {
                    WalletIdentityHeader(walletID: wallet.id).cardBackground()
                }
            }
            .padding(Metrics.pagePadding)
            .readableWidth(520)
        }
        .background(Palette.background)
        .bottomActionBar(maxWidth: 520) {
                if let wallet = model.created {
                    Button { finish(.connectWallet(wallet.id)) } label: {
                        ActionLabel("Pair a Wallet", systemImage: "qrcode")
                    }
                    .prominentAction()
                    .accessibilityIdentifier("setup.connect")
                }
                Button { finish(nil) } label: { ActionLabel("Done", prominent: false) }
                    .secondaryAction()
                    .accessibilityIdentifier("setup.done")
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .sensoryFeedback(.success, trigger: model.created != nil)
    }
}
