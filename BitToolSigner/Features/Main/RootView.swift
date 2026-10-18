import SwiftUI

/// Chooses between launch, welcome and the main tabs. App Lock, the privacy
/// cover and wallet setup are hosted here so they survive those transitions.
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var access: AppAccessController
    @StateObject private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSceneCaptured) private var isSceneCaptured
    @AppStorage("appearance") private var appearance = "system"

    private enum Stage: Equatable { case loading, failed, welcome, main }
    private var stage: Stage {
        if store.isLoading { return .loading }
        if !store.walletLoadSucceeded { return .failed }
        return store.wallets.isEmpty ? .welcome : .main
    }
    /// Connect's opening QRs are prepared only while wallets are visible.
    private var canPrefetch: Bool { scenePhase == .active && !access.isLocked && !isSceneCaptured && stage == .main }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            switch stage {
            case .loading: LaunchView()
            case .failed: LoadFailureView()
            case .welcome: WelcomeView().transition(.opacity)
            case .main: MainTabView().transition(.opacity)
            }
            if isSceneCaptured || scenePhase != .active {
                PrivacyShieldView(captured: isSceneCaptured).transition(.identity)
            }
        }
        .animation(.smooth(duration: 0.35), value: stage)
        .environmentObject(router)
        .opacity(access.isLocked ? 0 : 1)
        .allowsHitTesting(!access.isLocked)
        .accessibilityHidden(access.isLocked)
        .background(AppLockWindowPresenter(store: store, access: access, appearance: appearance))
        .sheet(item: $router.setup, onDismiss: { router.setupDidDismiss() }) { presentation in
            WalletSetupFlow(presentation: presentation, existingWallets: store.wallets.count)
                .environmentObject(store)
                .environmentObject(access)
                .environmentObject(router)
        }
        .onChange(of: store.isLoading) { _, loading in
            if !loading && store.walletLoadSucceeded { access.updateWalletCount(store.wallets.count) }
        }
        .onChange(of: store.walletLoadSucceeded) { _, succeeded in
            if succeeded { access.updateWalletCount(store.wallets.count) }
        }
        .onChange(of: store.wallets.count) { _, count in
            guard !store.isLoading, store.walletLoadSucceeded else { return }
            access.updateWalletCount(count)
            if count == 0 { router.tab = .wallets; router.resetNavigation() }
        }
        .onChange(of: store.navigationResetEpoch) { _, _ in router.resetNavigation() }
        .onChange(of: canPrefetch, initial: true) { _, allowed in store.setConnectPrefetch(allowed: allowed) }
        .onChange(of: access.isLocked) { _, locked in if locked { store.suspend() } }
        .onChange(of: isSceneCaptured) { _, captured in if captured { store.suspend() } }
        .onChange(of: store.review?.requestHash) { _, hash in if hash != nil { router.tab = .scan } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            access.willEnterForeground()
        }
        .alert("Unable to Continue", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

/// Matches LaunchScreen.storyboard exactly, so loading never flashes a new layout.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")
            VStack(spacing: 18) {
                BrandTile(size: 96, shadow: false)
                Text("BitTool Signer").font(.system(size: 22, weight: .semibold))
                Text("Air-gapped signing. For everyone.")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
        }
        // The storyboard centers on the full screen, not the safe area.
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}

private struct LoadFailureView: View {
    @EnvironmentObject private var store: AppStore
    @State private var retrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Wallets Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Your encrypted wallet files are unchanged. Unlock this device, then try again.")
        } actions: {
            Button {
                retrying = true
                Task { await store.reload(); retrying = false }
            } label: {
                ActionLabel("Try Again", systemImage: "arrow.clockwise", busy: retrying)
            }
            .prominentAction()
            .frame(maxWidth: 280)
            .disabled(retrying)
        }
    }
}
