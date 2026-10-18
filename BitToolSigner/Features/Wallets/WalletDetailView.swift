import SwiftUI

enum WalletSheet: String, Identifiable {
    case recoveryPhrase, changePassword, delete, repair
    var id: String { rawValue }
}

struct WalletDetailView: View {
    let walletID: UUID
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: WalletSheet?
    @State private var renaming = false
    @State private var newName = ""
    @State private var error: String?
    @State private var copied = false
    @State private var passwordChanged = false

    private var wallet: VaultMetadata? { store.wallet(walletID) }
    private var ready: Bool { store.metadataStatus(for: walletID) == .ready }

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            if store.duplicateWalletIDs.contains(walletID) {
                Section {
                    Callout("Another saved wallet uses the same recovery phrase and passphrase. Both are kept. Requests that match both cannot be signed until you delete one copy.",
                            title: "Duplicate wallet", tone: .warning)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }

            if !ready {
                Section {
                    Callout("This wallet's public data is missing or damaged. Your encrypted recovery phrase is safe. Enter the wallet password once to rebuild it.",
                            title: "Repair needed", tone: .warning)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    Button { sheet = .repair } label: {
                        Label("Repair Wallet Data", systemImage: "wrench.and.screwdriver")
                    }
                }
            } else {
                Section {
                    ForEach(Chain.allCases) { chain in
                        NavigationLink(value: WalletRoute.connect(walletID, chain)) {
                            ChainRow(chain: chain)
                        }
                        .accessibilityIdentifier("detail.connect." + chain.rawValue)
                    }
                    NavigationLink(value: WalletRoute.connectWallet(walletID)) {
                        WalletLevelRow()
                    }
                    .accessibilityIdentifier("detail.connect.wallet")
                } header: {
                    Text("Pair")
                } footer: {
                    Text("Export public keys to a watch-only wallet such as Sparrow or MetaMask. Private keys never leave this device.")
                }

                Section {
                    NavigationLink(value: WalletRoute.addresses(walletID, .bitcoin)) {
                        Label("Receive Addresses", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("detail.addresses")
                } footer: {
                    Text("Derived on this device from public keys. Balances are never checked.")
                }
            }

            Section("Security") {
                Button { sheet = .recoveryPhrase } label: {
                    Label("Show Recovery Phrase", systemImage: "key.viewfinder")
                }
                .accessibilityIdentifier("detail.recoveryPhrase")
                Button { sheet = .changePassword } label: {
                    Label("Change Password", systemImage: "lock.rotation")
                }
                .accessibilityIdentifier("detail.changePassword")
            }

            Section {
                Button {
                    newName = wallet?.name ?? ""; renaming = true
                } label: {
                    Label("Rename Wallet", systemImage: "pencil")
                }
                .accessibilityIdentifier("detail.rename")
            }

            Section {
                Button(role: .destructive) { sheet = .delete } label: {
                    Label("Delete Wallet", systemImage: "trash")
                        .foregroundStyle(Palette.danger)
                }
                .accessibilityIdentifier("detail.delete")
            } footer: {
                Text("Deleting removes this wallet from BitTool Signer only. Funds stay on the blockchain and can be restored with the recovery phrase.")
            }
        }
        .listStyle(.insetGrouped)
        .listBottomInset()
        .navigationTitle(wallet?.name ?? "Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { item in
            switch item {
            case .recoveryPhrase: RecoveryPhraseSheet(walletID: walletID)
            case .changePassword: ChangePasswordSheet(walletID: walletID) { passwordChanged = true }
            case .delete: DeleteWalletSheet(walletID: walletID)
            case .repair: RepairWalletSheet(walletID: walletID)
            }
        }
        .alert("Rename Wallet", isPresented: $renaming) {
            TextField("Wallet name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename() }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The fingerprint and addresses stay the same.")
        }
        .alert("Unable to Rename", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onChange(of: store.wallets) { _, _ in if wallet == nil { dismiss() } }
        .copiedToast($copied)
        .statusToast("Password Changed", announcement: "Password changed", isPresented: $passwordChanged)
    }

    private var header: some View {
        VStack(spacing: 12) {
            WalletAvatar(identity: store.avatarIdentity(for: walletID), name: wallet?.name ?? "", size: 76)
            VStack(spacing: 4) {
                Text(wallet?.name ?? "Wallet")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Button {
                    guard let fingerprint = store.publicMetadata(for: walletID)?.masterFingerprint else { return }
                    Clipboard.copy(fingerprint.uppercased()); copied = true
                } label: {
                    Text("Fingerprint \(store.fingerprint(for: walletID))")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(store.publicMetadata(for: walletID) == nil)
                .accessibilityHint("Copies the master fingerprint")
                if let created = wallet?.createdAt {
                    Text("Added \(created.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func rename() {
        let name = newName
        Task {
            do { try await store.renameWallet(walletID: walletID, name: name) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Chain family row with its networks and export formats.
/// One QR code carrying every chain, for wallets that read BitTool Signer's
/// wallet-level pairing.
struct WalletLevelRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow { ChainLogo(chain: .bitcoin, size: 15); ChainLogo(chain: .evm, size: 15) }
                GridRow { ChainLogo(chain: .tron, size: 15); ChainLogo(chain: .solana, size: 15) }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallet Level").font(.body)
                Text("One QR code for all four chains").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ChainRow: View {
    let chain: Chain

    private var subtitle: LocalizedStringKey {
        switch chain {
        case .bitcoin: "Single-sig and multisig accounts"
        case .evm: "Ethereum, BNB Chain, Arbitrum, Base and more"
        case .tron: "Any address index"
        case .solana: "Standard, Trust and Legacy paths"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ChainGlyph(chain: chain, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(chain.longName).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
