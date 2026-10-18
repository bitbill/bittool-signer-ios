import SwiftUI

struct WalletsTab: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("onboardingVersionCompleted") private var onboardingVersion = 0

    var body: some View {
        NavigationStack(path: $router.walletPath) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(store.wallets) { wallet in
                        WalletCard(wallet: wallet)
                    }
                    Label("Keys and signing stay on this device.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 8)
                .readableWidth()
            }
            .background(Palette.background)
            .navigationTitle("Wallets")
            .toolbar {
                // Scanning is the thing this app is opened for, so it is one tap
                // from the wallet list as well as from the tab bar.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.startScanning() } label: {
                        Label("Scan", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("wallets.scan")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Create New Wallet", systemImage: "plus") { start(.create) }
                        Button("Import Recovery Phrase", systemImage: "square.and.arrow.down") { start(.restore) }
                    } label: {
                        Label("Add Wallet", systemImage: "plus")
                    }
                    .accessibilityIdentifier("wallets.add")
                }
            }
            .navigationDestination(for: WalletRoute.self) { route in
                switch route {
                case .detail(let id): WalletDetailView(walletID: id)
                // A route that names a chain was reached by picking that chain,
                // so it opens on Coin Level. The prefetched wallet-level QR is
                // still handed over, so switching to Wallet Level is instant.
                case .connect(let id, let chain):
                    ConnectView(walletID: id, initialChain: chain, initialLevel: .coin,
                                prefetched: store.preparedConnect(walletID: id))
                case .connectWallet(let id):
                    ConnectView(walletID: id, initialLevel: .wallet, prefetched: store.preparedConnect(walletID: id))
                case .addresses(let id, let chain): AddressesView(walletID: id, initialChain: chain)
                }
            }
        }
    }

    private func start(_ intent: SetupIntent) {
        router.startSetup(intent, firstWallet: store.wallets.isEmpty, introductionCompleted: onboardingVersion >= 1)
    }
}

/// One wallet: identity on top, quick public actions below. There is no
/// "current" or "default" wallet; every card is equal and self-contained.
struct WalletCard: View {
    let wallet: VaultMetadata
    @EnvironmentObject private var store: AppStore

    private var ready: Bool { store.metadataStatus(for: wallet.id) == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: WalletRoute.detail(wallet.id)) {
                HStack(spacing: 14) {
                    WalletAvatar(identity: store.avatarIdentity(for: wallet.id), name: wallet.name, size: 50)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(wallet.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text("Fingerprint \(store.fingerprint(for: wallet.id))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if ready {
                            NetworkLogoStack(size: 16)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wallet.card." + wallet.id.uuidString)
            .accessibilityHint("Shows wallet details")

            if store.duplicateWalletIDs.contains(wallet.id) {
                Callout("Another wallet has the same key identity. Requests it matches cannot be signed.", tone: .warning)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }

            Divider().padding(.leading, 16)

            if ready {
                HStack(spacing: 10) {
                    NavigationLink(value: WalletRoute.connectWallet(wallet.id)) {
                        Label("Pair", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("wallet.connect." + wallet.id.uuidString)
                    NavigationLink(value: WalletRoute.addresses(wallet.id, .bitcoin)) {
                        Label("Addresses", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("wallet.addresses." + wallet.id.uuidString)
                }
                .labelStyle(CompactActionLabelStyle())
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                NavigationLink(value: WalletRoute.detail(wallet.id)) {
                    Label("Repair wallet data", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// Icon + title that collapses to the icon at accessibility text sizes.
struct CompactActionLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if !dynamicTypeSize.isAccessibilitySize { configuration.title.lineLimit(1).minimumScaleFactor(0.85) }
        }
        .font(.subheadline.weight(.semibold))
    }
}
