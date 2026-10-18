import CryptoKit
import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var access: AppAccessController
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    @State private var changingLock = false
    @State private var lockError: String?

    private var biometry: BiometryKind { access.biometry }
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { access.isEnabled }, set: changeAppLock)) {
                        Label {
                            Text("\(biometry.name) Lock")
                        } icon: {
                            Image(systemName: biometry.symbol)
                        }
                    }
                    .disabled(changingLock || store.wallets.isEmpty || (!biometry.isAvailable && !access.isEnabled))
                    .accessibilityIdentifier("settings.appLock")
                    if let lockError {
                        Text(lockError).font(.footnote).foregroundStyle(Palette.danger)
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text(biometry.isAvailable
                         ? "Require \(biometry.name) to open BitTool Signer at launch and after 2 minutes in the background. Every signature still needs the wallet’s password."
                         : "Set up Face ID or Touch ID in iOS Settings to lock BitTool Signer. Every signature always needs the wallet’s password.")
                }

                Section {
                    Picker(selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                    }
                    .accessibilityIdentifier("settings.appearance")
                    Picker(selection: $language) {
                        ForEach(AppLanguage.selectable) { option in
                            Text(option == .system ? String(localized: "System") : option.endonym).tag(option.rawValue)
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                    .accessibilityIdentifier("settings.language")
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("The interface language. What a signing request itself says is decided by the request and stays as it is.")
                }

                Section("Reference") {
                    NavigationLink { TokenDirectoryView() } label: {
                        Label("Networks, Tokens & Contracts", systemImage: "circle.hexagongrid")
                    }
                    NavigationLink { CompatibilityView() } label: {
                        Label("Compatibility", systemImage: "checkmark.shield")
                    }
                }

                Section {
                    LabeledContent("Version", value: version)
                    LabeledContent("Publisher", value: "BITTOOL PTE. LTD.")
                    LabeledContent("Network connections", value: String(localized: "None", bundle: AppText.bundle))
                    NavigationLink("Fully Open Source") { OpenSourceView() }
                        .accessibilityIdentifier("settings.openSource")
                    NavigationLink("Terms of Use") { LegalDocumentView(document: .terms) }
                        .accessibilityIdentifier("settings.terms")
                    NavigationLink("Privacy Policy") { LegalDocumentView(document: .privacy) }
                        .accessibilityIdentifier("settings.privacy")
                } header: {
                    Text("About")
                } footer: {
                    VStack(spacing: 10) {
                        BrandTile(size: 44, shadow: false)
                        Text("Air-gapped signing. For everyone.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func changeAppLock(_ enabled: Bool) {
        guard !changingLock else { return }
        changingLock = true; lockError = nil
        Task {
            defer { changingLock = false }
            do { try await access.setEnabled(enabled) }
            catch { if !(error is CancellationError) { lockError = error.localizedDescription } }
        }
    }
}


struct CompatibilityView: View {
    private enum Tab: Hashable { case formats, wallets }
    @State private var tab: Tab = .formats

    var body: some View {
        Group {
            switch tab {
            case .formats: formats
            case .wallets: WalletDirectoryView()
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Compatibility", selection: $tab.animation(.snappy(duration: 0.2))) {
                Text("Formats").tag(Tab.formats)
                Text("Wallets").tag(Tab.wallets)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("compatibility.tab")
        }
        .navigationTitle("Compatibility")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var formats: some View {
        List {
            Section {
                Callout("BitTool Signer uses open QR standards. The wallets below support these formats according to their documentation, source code or official QR hardware-wallet guides (September 2026). Versions change, so always compare addresses in both apps before receiving funds.", tone: .info)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            item(.bitcoin, formats: "crypto-account (account xpub), crypto-psbt, BBQR, Base64 PSBT",
                 signing: "PSBT v0/v2: single-sig (Legacy, Nested, Native SegWit, Taproot) and multisig (P2SH, P2SH-P2WSH, P2WSH, Taproot script path). MuSig2 is not supported.")
            item(.evm, formats: "crypto-hdkey (EIP-4527), eth-sign-request / eth-signature",
                 signing: "Legacy, EIP-2930 and EIP-1559 transactions, personal messages and EIP-712 typed data, including Safe, Permit2 and NFT marketplace orders.")
            item(.tron, formats: "Address QR (any index), tron-sign-request / tron-signature",
                 signing: "TRX and TRC-20 transfers, contract calls, permission updates and Stake 2.0 resources. No mainstream wallet sends TRON transactions to a QR signer in this format yet.")
            item(.solana, formats: "crypto-multi-accounts, sol-sign-request / sol-signature",
                 signing: "Legacy and v0 transactions with static accounts, and messages. Address lookup tables are not supported offline.")
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.title3).foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    Text("Wallet Level · all chains").font(.headline)
                }
                DetailLine(label: "QR format", value: "bittool-signer-wallet v1 (ur:bytes, canonical CBOR): an account xpub for each Bitcoin address type, for EVM and for TRON, and all three Solana addresses, in one animated QR", monospaced: false)
                WalletGroup(title: "Works with", systemImage: "qrcode.viewfinder", wallets: CompatibleWallets.walletLevel)
                    .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func item(_ chain: Chain, formats: String, signing: LocalizedStringKey) -> some View {
        let wallets = CompatibleWallets.all(for: chain)
        let signers = wallets.filter { $0.support == .signing }, watchers = wallets.filter { $0.support == .watchOnly }
        return Section {
            HStack(spacing: 12) {
                ChainGlyph(chain: chain, size: 36)
                Text(chain.longName).font(.headline)
            }
            DetailLine(label: "QR formats", value: formats, monospaced: false)
            DetailLine(label: "Signing", prose: signing)
            if !signers.isEmpty {
                WalletGroup(title: "Watch and sign by QR", systemImage: "qrcode.viewfinder", wallets: signers)
                    .padding(.vertical, 4)
            }
            if !watchers.isEmpty {
                WalletGroup(title: "Watch only", systemImage: "eye", wallets: watchers)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// What the repository contains and how to check that this install matches it.
/// Nothing here opens a browser: the address is text you can copy.
struct OpenSourceView: View {
    @State private var engineDigest: String?
    @State private var engineBytes: Int?
    @State private var registryVersion: String?
    @State private var copied = false

    private static let repository = "https://github.com/bitbill/bittool-signer-ios"

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                Callout("BitTool Signer is open source, all of it. The app, the offline signing engine and the token data are published under one repository, so anyone can read what the signer does with a recovery phrase — and rebuild it and compare the result with the copy installed here.", tone: .info)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.repository)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("openSource.repository")
                    Button {
                        Clipboard.copy(Self.repository); copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Repository")
            } footer: {
                Text("The app never opens a browser. Copy the address and open it on another device.")
            }
            Section {
                DetailLine(label: "App version", value: version)
                DetailLine(label: "Signing engine", value: engineDigest ?? String(localized: "Reading…", bundle: AppText.bundle))
                DetailLine(label: "Engine size", value: engineBytes.map { "\($0.formatted()) bytes" } ?? String(localized: "Reading…", bundle: AppText.bundle))
                DetailLine(label: "Token registry", value: registryVersion ?? String(localized: "Reading…", bundle: AppText.bundle))
                DetailLine(label: "Networking code", value: String(localized: "None", bundle: AppText.bundle))
            } header: {
                Text("This build")
            } footer: {
                Text("The engine digest is the SHA-256 of signer.js as it is bundled in this app, computed on this device each time you open this page.")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Clone the repository and check out the tag for version \(version).")
                    step(2, "Run: cd engine && npm ci && npm run build")
                    step(3, "Compare the SHA-256 it prints, and engine/bundle-manifest.json, with the digest above.")
                }
                .padding(.vertical, 2)
            } header: {
                Text("Rebuild it yourself")
            } footer: {
                Text("The engine bundle is deterministic: the same sources produce the same bytes, so a digest that differs means the installed engine is not the published one.")
            }
            Section {
                NavigationLink("Third-Party Notices") { LicensesView() }
                    .accessibilityIdentifier("openSource.notices")
            } footer: {
                Text("The engine bundles open-source libraries for cryptography and encoding. Their licences and copyright notices are reproduced in full.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Open Source")
        .navigationBarTitleDisplayMode(.inline)
        .task { await readBuild() }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").font(.footnote.monospaced()).foregroundStyle(.secondary)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reads the two bundled files off the main thread; neither holds anything secret.
    private func readBuild() async {
        guard engineDigest == nil else { return }
        let measured = await Task.detached { () -> (String, Int)? in
            guard let url = Bundle.main.url(forResource: "signer", withExtension: "js"),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (digest, data.count)
        }.value
        let registry = await Task.detached { () -> String? in
            guard let url = Bundle.main.url(forResource: "token-registry", withExtension: "json"),
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            // The version sits in the first bytes of the file; the rest is megabytes of tokens.
            guard let head = try? handle.read(upToCount: 512), let text = String(data: head, encoding: .utf8),
                  let match = text.firstMatch(of: /"registryVersion":"([^"]+)"/) else { return nil }
            return String(match.output.1)
        }.value
        engineDigest = measured?.0 ?? String(localized: "Unavailable", bundle: AppText.bundle)
        engineBytes = measured?.1
        registryVersion = registry ?? String(localized: "Unavailable", bundle: AppText.bundle)
    }
}

struct LicensesView: View {
    @State private var paragraphs: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Metrics.pagePadding)
        }
        .background(Palette.background)
        .navigationTitle("Third-Party Notices")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard paragraphs.isEmpty else { return }
            let text = await Task.detached {
                guard let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "txt"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return String(localized: "Third-party notices are included with the source distribution.", bundle: AppText.bundle)
                }
                return text
            }.value
            paragraphs = text.components(separatedBy: "\n\n")
        }
    }
}
