import SwiftUI
import UIKit

/// Shown in its own window above the app while App Lock is engaged. It only
/// restores access to the app; it never unlocks a wallet or authorizes signing.
struct AppLockView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var access: AppAccessController
    @State private var usePassword = false
    @State private var walletID: UUID?
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var operation = UUID()
    @FocusState private var passwordFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 60)
                VStack(spacing: 14) {
                    BrandTile(size: 84)
                    Text("BitTool Signer Is Locked").font(.title2.weight(.bold))
                    Text("Unlock to view your wallets and activity.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if usePassword { passwordForm } else { biometricActions }
                if let message = error ?? access.error {
                    Callout(verbatim: message, tone: .warning)
                }
                Text("Unlocking the app never authorizes a signature.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .readableWidth(440)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.background.ignoresSafeArea())
        .task { authenticateBiometrics() }
        .onChange(of: store.securityEpoch) { _, _ in operation = UUID(); password = ""; busy = false }
        .onDisappear { operation = UUID(); password = "" }
    }

    private var biometricActions: some View {
        VStack(spacing: 12) {
            Button { authenticateBiometrics() } label: {
                ActionLabel(verbatim: "Unlock with \(access.biometry.name)", systemImage: access.biometry.symbol, busy: access.isAuthenticating)
            }
            .prominentAction()
            .disabled(access.isAuthenticating)
            .accessibilityIdentifier("appLock.biometric")
            Button {
                withAnimation(.snappy) { usePassword = true; error = nil }
                if walletID == nil, store.wallets.count == 1 { walletID = store.wallets.first?.id }
            } label: {
                ActionLabel("Use a Wallet Password", systemImage: "key", prominent: false)
            }
            .secondaryAction()
            .accessibilityIdentifier("appLock.usePassword")
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the password of any wallet on this device.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Wallet", selection: $walletID) {
                Text("Choose a wallet").tag(nil as UUID?)
                ForEach(store.wallets) { wallet in
                    // Name only: the fingerprint also appears in exports, so it stays behind the lock.
                    Text(wallet.name).tag(Optional(wallet.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("appLock.wallet")
            PasswordField(.walletPassword, text: $password)
                .focused($passwordFocused)
                .submitLabel(.go)
                .onSubmit(authenticatePassword)
                .padding(14)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button(action: authenticatePassword) { ActionLabel("Unlock", systemImage: "lock.open", busy: busy) }
                .prominentAction()
                .disabled(walletID == nil || password.isEmpty || busy)
                .accessibilityIdentifier("appLock.unlock")
            if access.biometry.isAvailable {
                Button("Use \(access.biometry.name) Instead") {
                    withAnimation(.snappy) { password = ""; usePassword = false; error = nil }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
        }
        .cardBackground(padding: 18)
    }

    private func authenticateBiometrics() {
        guard access.biometry.isAvailable, !access.isAuthenticating else {
            if !access.biometry.isAvailable { usePassword = true }
            return
        }
        error = nil
        Task {
            do { try await access.authenticateBiometrics() }
            catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }

    private func authenticatePassword() {
        guard !busy, let id = walletID, !password.isEmpty else { return }
        let entered = password, current = operation
        password = ""; busy = true; error = nil
        Task {
            do { try await access.authenticate(walletID: id, password: entered) }
            catch {
                if current == operation, !(error is CancellationError) {
                    self.error = error.localizedDescription
                    passwordFocused = true
                }
            }
            if current == operation { busy = false }
        }
    }
}

/// A separate authentication window covers the existing navigation and every
/// presented sheet. It preserves their state without exposing them while locked.
/// The snapshot/recording shield sits above this window.
struct AppLockWindowPresenter: UIViewRepresentable {
    @ObservedObject var store: AppStore
    @ObservedObject var access: AppAccessController
    let appearance: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.onAttach = { [weak coordinator = context.coordinator] source in
            coordinator?.update(source: source, store: store, access: access, appearance: appearance)
        }
        return view
    }
    func updateUIView(_ view: WindowProbe, context: Context) {
        context.coordinator.update(source: view.window, store: store, access: access, appearance: appearance)
    }
    static func dismantleUIView(_ view: WindowProbe, coordinator: Coordinator) { coordinator.hide() }

    final class WindowProbe: UIView {
        var onAttach: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onAttach?(window) }
    }

    @MainActor final class Coordinator {
        private var lockWindow: UIWindow?
        private weak var previousWindow: UIWindow?

        func update(source: UIWindow?, store: AppStore, access: AppAccessController, appearance: String) {
            guard access.isLocked else { hide(); return }
            guard let source, let scene = source.windowScene else { return }
            if lockWindow == nil {
                source.endEditing(true)
                previousWindow = source
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                window.accessibilityViewIsModal = true
                let host = UIHostingController(rootView:
                    AppLockView().environmentObject(store).environmentObject(access))
                host.view.backgroundColor = .systemGroupedBackground
                window.rootViewController = host
                lockWindow = window
                window.makeKeyAndVisible()
            }
            lockWindow?.overrideUserInterfaceStyle = UIUserInterfaceStyle(appearance: appearance)
        }

        func hide() {
            guard let window = lockWindow else { return }
            window.endEditing(true); window.isHidden = true; window.rootViewController = nil
            lockWindow = nil
            previousWindow?.makeKey(); previousWindow = nil
        }
    }
}
