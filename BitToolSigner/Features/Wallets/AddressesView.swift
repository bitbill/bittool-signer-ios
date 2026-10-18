import SwiftUI

/// Receive addresses derived locally from cached public keys. No balances,
/// history or usage are looked up, and browsing never selects a signer.
struct AddressesView: View {
    let walletID: UUID
    @EnvironmentObject private var store: AppStore
    @State private var chain: Chain
    @State private var btcProfile = "native"
    @State private var accounts: [PublicAccount] = []
    @State private var loadedKey: String?
    @State private var loadingMore = false
    @State private var hasMore = true
    @State private var error: String?
    @State private var selected: PublicAccount?

    private let pageSize = 20

    init(walletID: UUID, initialChain: Chain = .bitcoin) {
        self.walletID = walletID
        _chain = State(initialValue: initialChain)
    }

    private var listKey: String { [chain.rawValue, btcProfile].joined(separator: "|") }
    private var limit: Int { chain == .solana ? 3 : 2_147_483_648 }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ChainPicker(selection: $chain)
                    if chain == .bitcoin {
                        ProfileMenu(title: "Address type", profiles: AccountProfile.bitcoinSingle, selection: $btcProfile)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                if loadedKey == listKey {
                    ForEach(accounts) { account in
                        Button { selected = account } label: { AddressRow(account: account, chain: chain) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("address.row.\(account.index)")
                            .contextMenu {
                                Button("Copy Address", systemImage: "doc.on.doc") { Clipboard.copy(account.address) }
                                Button("Show QR Code", systemImage: "qrcode") { selected = account }
                            }
                            .onAppear { if account.id == accounts.last?.id { Task { await loadMore() } } }
                    }
                    if loadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } else if let error {
                    Callout(verbatim: error, tone: .danger)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 20)
                }
            } header: {
                sectionTitle
            } footer: {
                footer
            }
        }
        .listStyle(.insetGrouped)
        .listBottomInset()
        .navigationTitle("Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: listKey) { await reload() }
        .sheet(item: $selected) { account in
            AddressDetailSheet(account: account, title: title(for: account))
                .presentationDetents([.large])
        }
    }

    private var sectionTitle: Text {
        switch chain {
        case .bitcoin: Text("Receive · \(AccountProfile.bitcoinSingle.first { $0.id == btcProfile }?.title ?? "")")
        case .evm: Text("Receive · All EVM networks")
        case .tron: Text("Receive · TRX and TRC-20 tokens")
        case .solana: Text("Accounts by derivation path")
        }
    }

    private var footer: Text {
        switch chain {
        case .bitcoin: Text("Showing receive addresses. Multisig addresses need every cosigner key and are created by your coordinator.")
        case .evm: Text("One address works on Ethereum, BNB Smart Chain, Arbitrum, Base and other EVM networks.")
        case .tron: Text("Every TRON receive index is available. To export a specific index, use Pair.")
        case .solana: Text("Solana wallets use different derivation paths. Pick the one your other wallet uses.")
        }
    }

    private func title(for account: PublicAccount) -> String {
        if chain == .solana {
            return String(localized: "\(solanaName(account.path)) account", bundle: AppText.bundle)
        }
        return String(localized: "\(chain.name) address #\(account.index)", bundle: AppText.bundle)
    }

    private func solanaName(_ path: String) -> String {
        AccountProfile.solana.first { $0.detail == path }?.title ?? "Solana"
    }

    private func reload() async {
        let key = listKey
        error = nil; hasMore = true
        do {
            let page = try await fetch(start: 0)
            try Task.checkCancellation()
            guard key == listKey else { return }
            accounts = page; loadedKey = key
            hasMore = page.count == pageSize && page.count < limit
        } catch {
            if !Task.isCancelled, key == listKey { self.error = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard hasMore, !loadingMore, loadedKey == listKey, chain != .solana else { return }
        let key = listKey, start = accounts.count
        guard start < limit else { hasMore = false; return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await fetch(start: start)
            guard key == listKey, accounts.count == start else { return }
            accounts += page
            hasMore = page.count == pageSize && accounts.count < limit
        } catch {
            if key == listKey { hasMore = false }
        }
    }

    private func fetch(start: Int) async throws -> [PublicAccount] {
        let count = chain == .solana ? 3 : min(pageSize, limit - start)
        let profile = chain == .bitcoin ? btcProfile : chain == .solana ? "" : "standard"
        return try await store.addresses(walletID: walletID, chain: chain, profile: profile, start: start, count: count)
    }
}

private struct AddressRow: View {
    let account: PublicAccount
    let chain: Chain

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .leading)
            AddressText(address: account.address, font: .footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "qrcode")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows QR code and derivation path")
    }

    private var label: String {
        chain == .solana ? (AccountProfile.solana.first { $0.detail == account.path }?.title ?? "") : "#\(account.index)"
    }
}

struct AddressDetailSheet: View {
    let account: PublicAccount
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    QRCodeView(frames: [account.address], maxSide: 280)
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 14) {
                        CopyableAddress(address: account.address, font: .body)
                        Divider()
                        DetailLine(label: "Derivation path", value: account.path)
                    }
                    .cardBackground()
                    Callout("Address only. No public key or derivation path is included in this QR code.")
                }
                .padding(Metrics.pagePadding)
                .readableWidth(520)
            }
            .background(Palette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
