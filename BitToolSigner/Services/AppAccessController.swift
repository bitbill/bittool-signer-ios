import Foundation
import Combine
import LocalAuthentication
import Darwin

@MainActor
protocol AppBiometricAuthenticating: AnyObject {
    func authenticate(reason: String) async throws
    func cancel()
}

/// The device's enrolled biometric method, used only for App Lock wording.
enum BiometryKind: Equatable, Sendable {
    case faceID, touchID, opticID, none

    static func current() -> BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Report the hardware type even when not enrolled, so wording stays accurate.
            return kind(context.biometryType, available: false)
        }
        return kind(context.biometryType, available: true)
    }

    private static func kind(_ type: LABiometryType, available: Bool) -> BiometryKind {
        guard available else { return .none }
        switch type {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    var isAvailable: Bool { self != .none }
    var name: String {
        switch self {
        case .faceID, .none: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        }
    }
    var symbol: String {
        switch self {
        case .faceID, .none: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        }
    }
}

@MainActor
final class BiometricAuthentication: AppBiometricAuthenticating {
    private var context: LAContext?
    func authenticate(reason: String) async throws {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil }; context.invalidate() }
        // No device-passcode fallback: the only alternative is a wallet password.
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              [.faceID, .touchID, .opticID].contains(context.biometryType) else {
            throw AppIssue.message(String(localized: "Biometric authentication is unavailable. Check Face ID or Touch ID in iOS Settings, or use a wallet password.", bundle: AppText.bundle))
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            guard success else { throw AppIssue.message(String(localized: "Authentication failed. Try again or use a wallet password.", bundle: AppText.bundle)) }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel: throw CancellationError()
            case .biometryLockout: throw AppIssue.message(String(localized: "Biometrics are locked after too many attempts. Use a wallet password, or unlock your iPhone with its passcode first.", bundle: AppText.bundle))
            default: throw AppIssue.message(String(localized: "Authentication failed. Try again or use a wallet password.", bundle: AppText.bundle))
            }
        }
    }
    func cancel() { context?.invalidate(); context = nil }
}

/// This controller authenticates access to public app pages only. It never
/// derives accounts, returns a secret, chooses a signer, or authorizes signing.
@MainActor
final class AppAccessController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var biometry: BiometryKind
    @Published var error: String?
    private let vault: WalletVault
    private let defaults: UserDefaults
    private let biometric: any AppBiometricAuthenticating
    private let uptime: @MainActor () -> TimeInterval
    private var walletCount: Int?
    private var backgroundTime: TimeInterval?
    private var isInBackground = false
    private var authenticationEpoch = UUID()
    static let preferenceKey = "appLockEnabled.v1"
    static let backgroundGrace: TimeInterval = 120

    /// Monotonic time that keeps counting while the device sleeps. `systemUptime`
    /// pauses during sleep, which would let a phone asleep for hours reopen unlocked.
    nonisolated static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    init(vault: WalletVault, defaults: UserDefaults = .standard,
         biometric: (any AppBiometricAuthenticating)? = nil,
         uptime: @escaping @MainActor () -> TimeInterval = AppAccessController.monotonicSeconds) {
        self.vault = vault; self.defaults = defaults
        self.biometric = biometric ?? BiometricAuthentication(); self.uptime = uptime
        biometry = biometric == nil ? BiometryKind.current() : .faceID
        let enabled = defaults.bool(forKey: Self.preferenceKey)
        isEnabled = enabled
        // No authenticated state is persisted: enabled cold launches start locked.
        isLocked = enabled
    }

    /// Call after the repository has finished loading, not for a loading placeholder.
    func updateWalletCount(_ count: Int) {
        walletCount = max(0, count)
        if count == 0 {
            cancelAuthentication()
            isEnabled = false; isLocked = false; backgroundTime = nil
            defaults.set(false, forKey: Self.preferenceKey)
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        guard enabled != isEnabled else { return }
        guard !isLocked, !isInBackground else { throw AppIssue.message(String(localized: "Authenticate app access before changing App Lock.", bundle: AppText.bundle)) }
        if enabled {
            guard let count = walletCount, count > 0 else { throw AppIssue.message(String(localized: "Create a wallet before enabling App Lock.", bundle: AppText.bundle)) }
            let epoch = try await performAuthentication { try await self.biometric.authenticate(reason: "Lock BitTool Signer with \(self.biometry.name).") }
            try requireAuthentication(epoch)
            guard (walletCount ?? 0) > 0 else { throw CancellationError() }
        }
        isEnabled = enabled; isLocked = false
        defaults.set(enabled, forKey: Self.preferenceKey)
    }

    func authenticateBiometrics() async throws {
        guard isEnabled, isLocked else { return }
        let epoch = try await performAuthentication { try await self.biometric.authenticate(reason: "Unlock BitTool Signer. Signing still requires the wallet password.") }
        try requireAuthentication(epoch)
        isLocked = false
    }

    /// A one-off check before a destructive action, independent of App Lock.
    /// Throws `CancellationError` when the person dismisses it; any other error
    /// means biometrics could not run, and the wallet password still decides.
    func confirmSensitiveAction(reason: String) async throws {
        guard biometry.isAvailable else { return }
        try await biometric.authenticate(reason: reason)
    }

    func authenticate(walletID: UUID, password: String) async throws {
        guard isEnabled, isLocked else { return }
        let epoch = try await performAuthentication { try await self.vault.verifyPassword(id: walletID, password: password) }
        try requireAuthentication(epoch)
        isLocked = false
    }

    func didEnterBackground() {
        // A true background transition counts; Face ID's temporary inactive
        // phase does not call this method and cannot cause an authentication loop.
        guard !isInBackground else { return }
        isInBackground = true; backgroundTime = uptime()
        cancelAuthentication()
    }

    func willEnterForeground() {
        guard isInBackground else { return }
        isInBackground = false
        if biometric is BiometricAuthentication { biometry = BiometryKind.current() }
        defer { backgroundTime = nil }
        guard isEnabled else { return }
        let now = uptime()
        guard let since = backgroundTime, now.isFinite, since.isFinite,
              now >= since, now - since < Self.backgroundGrace else {
            isLocked = true; return
        }
        // Preserve an already locked state even during a short background visit.
    }

    private func cancelAuthentication() {
        authenticationEpoch = UUID(); biometric.cancel(); isAuthenticating = false
    }

    private func requireAuthentication(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard epoch == authenticationEpoch, !isInBackground else { throw CancellationError() }
    }

    private func performAuthentication(_ operation: () async throws -> Void) async throws -> UUID {
        guard !isInBackground, !isAuthenticating else { throw AppIssue.message(String(localized: "App authentication is unavailable right now.", bundle: AppText.bundle)) }
        let epoch = UUID(); authenticationEpoch = epoch; isAuthenticating = true; error = nil
        defer { if epoch == authenticationEpoch { isAuthenticating = false } }
        do {
            try await operation()
            try requireAuthentication(epoch)
            return epoch
        } catch {
            if epoch == authenticationEpoch, !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }
}
