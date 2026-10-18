import SwiftUI
import Combine

enum SetupIntent: String, Identifiable, Hashable {
    case create, restore
    var id: String { rawValue }
}

enum WalletRoute: Hashable {
    case detail(UUID)
    case connect(UUID, Chain)
    /// Connect opened on its wallet-level QR (every chain in one code).
    case connectWallet(UUID)
    case addresses(UUID, Chain)
}

/// UI navigation only. Nothing here selects a signer or grants authorization:
/// routes carry an explicit wallet ID solely to show that wallet's public data.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable { case wallets, scan, activity, settings }

    struct SetupPresentation: Identifiable, Equatable {
        let id = UUID()
        let intent: SetupIntent
        let showsIntroduction: Bool
    }

    @Published var tab: Tab = .wallets
    @Published var walletPath: [WalletRoute] = []
    /// Bumped to ask the Scan tab to open the camera as soon as it appears.
    /// A token rather than a flag, so asking twice in a row still works and
    /// nothing has to be reset afterwards.
    @Published private(set) var scanRequest = 0
    @Published var setup: SetupPresentation?
    /// Opened once the setup sheet has fully dismissed. Pushing while the sheet
    /// is still animating away can leave the push transition stuck mid-way.
    private var routeAfterSetup: WalletRoute?

    func startSetup(_ intent: SetupIntent, firstWallet: Bool, introductionCompleted: Bool) {
        setup = SetupPresentation(intent: intent, showsIntroduction: firstWallet && !introductionCompleted)
    }

    /// Closes setup, then opens `route` after the sheet's dismissal completes.
    func finishSetup(opening route: WalletRoute?) {
        routeAfterSetup = route
        setup = nil
    }

    func setupDidDismiss() {
        guard let route = routeAfterSetup else { return }
        routeAfterSetup = nil
        open(route)
    }

    /// Opens the camera, wherever the person asked from. The decoded request
    /// is reviewed in the Scan tab, so that is where the scanner belongs.
    func startScanning() {
        tab = .scan
        scanRequest += 1
    }

    func open(_ route: WalletRoute) {
        tab = .wallets
        walletPath = [route]
    }

    func resetNavigation() {
        walletPath = []
    }
}
