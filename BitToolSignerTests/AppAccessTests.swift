import Foundation
import Testing
@testable import BitToolSigner

@MainActor
struct AppAccessTests {
    @Test func appLockDefaultsOffAndEnablingRequiresSuccessfulFaceID() async throws {
        let fixture = try makeAccess()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        #expect(!fixture.access.isEnabled)
        #expect(!fixture.access.isLocked)
        #expect(fixture.biometric.calls == 0)
        fixture.access.updateWalletCount(1)
        fixture.biometric.shouldFail = true
        await #expect(throws: AppIssue.self) { try await fixture.access.setEnabled(true) }
        #expect(!fixture.access.isEnabled)
        #expect(!fixture.defaults.bool(forKey: AppAccessController.preferenceKey))
        fixture.biometric.shouldFail = false
        try await fixture.access.setEnabled(true)
        #expect(fixture.access.isEnabled)
        #expect(!fixture.access.isLocked)
        #expect(fixture.defaults.bool(forKey: AppAccessController.preferenceKey))
        let cold = AppAccessController(vault: fixture.vault, defaults: fixture.defaults, biometric: fixture.biometric)
        #expect(cold.isLocked)
        await #expect(throws: AppIssue.self) { try await cold.setEnabled(false) }
        #expect(cold.isEnabled)
    }

    @Test func backgroundGraceUsesTheExactMonotonic120SecondBoundary() async throws {
        let fixture = try makeAccess(enabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.access.updateWalletCount(1)
        try await fixture.access.authenticateBiometrics()
        fixture.clock.value = 100
        fixture.access.didEnterBackground()
        fixture.clock.value = 219
        fixture.access.willEnterForeground()
        #expect(!fixture.access.isLocked)
        fixture.access.didEnterBackground()
        fixture.clock.value = 339
        fixture.access.willEnterForeground()
        #expect(fixture.access.isLocked)
        try await fixture.access.authenticateBiometrics()
        fixture.clock.value = 400
        fixture.access.didEnterBackground()
        fixture.clock.value = 399
        fixture.access.willEnterForeground()
        #expect(fixture.access.isLocked)
    }

    @Test func alreadyLockedAppStaysLockedAcrossShortBackgroundAndRepeatedForeground() async throws {
        let fixture = try makeAccess(enabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.access.updateWalletCount(1)
        fixture.access.didEnterBackground()
        fixture.clock.value += 1
        fixture.access.willEnterForeground()
        fixture.access.willEnterForeground()
        #expect(fixture.access.isLocked)
        #expect(fixture.biometric.calls == 0)
        try await fixture.access.authenticateBiometrics()
        #expect(!fixture.access.isLocked)
        // A Face ID inactive phase never calls didEnterBackground; repeated
        // foreground notifications alone cannot re-lock or start authentication.
        fixture.access.willEnterForeground()
        #expect(!fixture.access.isLocked)
        #expect(fixture.biometric.calls == 1)
    }

    @Test func backgroundRejectsAnInFlightBiometricCompletion() async throws {
        let fixture = try makeAccess(enabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.access.updateWalletCount(1)
        fixture.biometric.blockNext = true
        let authentication = Task { try await fixture.access.authenticateBiometrics() }
        await fixture.biometric.waitUntilStarted()
        fixture.access.didEnterBackground()
        fixture.biometric.complete()
        do { try await authentication.value; Issue.record("Backgrounded Face ID must not publish app access.") }
        catch is CancellationError {}
        #expect(fixture.access.isLocked)
        #expect(!fixture.access.isAuthenticating)
    }

    @Test func anyWalletPasswordCanOpenOnlyTheAppAccessState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-access-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WalletVault(directory: directory, deviceKeys: SessionDeviceKeys())
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        _ = try await vault.create(name: "First credential", mnemonic: phrase, password: "First-Password1")
        let second = try await vault.create(name: "Second credential", mnemonic: phrase, passphrase: "Public different wallet", password: "Second-Password2")
        let fixture = try makeAccess(enabled: true, vault: vault)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.access.updateWalletCount(2)
        await #expect(throws: VaultError.authenticationFailed) {
            try await fixture.access.authenticate(walletID: second.id, password: "First-Password1")
        }
        #expect(fixture.access.isLocked)
        try await fixture.access.authenticate(walletID: second.id, password: "Second-Password2")
        #expect(!fixture.access.isLocked)
        #expect(fixture.biometric.calls == 0)
        // Authentication returns no secret and does not change any vault. A
        // later sensitive operation must independently supply the correct password.
        await #expect(throws: VaultError.authenticationFailed) { try await vault.verifyPassword(id: second.id, password: "") }
        try await fixture.access.setEnabled(false)
        #expect(!fixture.access.isEnabled)
    }

    @Test func deletingTheLastWalletClearsThePreferenceAndCannotDeadlockWelcome() async throws {
        let fixture = try makeAccess(enabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        #expect(fixture.access.isLocked)
        fixture.access.updateWalletCount(0)
        #expect(!fixture.access.isLocked)
        #expect(!fixture.access.isEnabled)
        #expect(!fixture.defaults.bool(forKey: AppAccessController.preferenceKey))
        await #expect(throws: AppIssue.self) { try await fixture.access.setEnabled(true) }
        #expect(fixture.biometric.calls == 0)
    }

    /// Deleting a wallet asks for biometrics only where the person already
    /// chose to use them for this app. Turning App Lock off says "this app does
    /// not use Face ID", and a delete must not reintroduce the prompt. The
    /// wallet password authorizes the deletion either way.
    @Test func aSensitiveActionAsksForBiometricsOnlyWhileAppLockIsOn() async throws {
        let off = try makeAccess()
        defer { off.defaults.removePersistentDomain(forName: off.suite) }
        #expect(!off.access.isEnabled)
        try await off.access.confirmSensitiveAction(reason: "Delete")
        #expect(off.biometric.calls == 0, "App Lock is off, so nothing is asked")

        let on = try makeAccess(enabled: true)
        defer { on.defaults.removePersistentDomain(forName: on.suite) }
        on.access.updateWalletCount(1)
        try await on.access.authenticateBiometrics()
        let unlocking = on.biometric.calls
        try await on.access.confirmSensitiveAction(reason: "Delete")
        #expect(on.biometric.calls == unlocking + 1, "App Lock is on, so the check runs")
    }

    @Test func turningAppLockOffStopsTheDeleteCheckWithIt() async throws {
        let fixture = try makeAccess(enabled: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.access.updateWalletCount(1)
        try await fixture.access.authenticateBiometrics()
        try await fixture.access.setEnabled(false)
        #expect(!fixture.access.isEnabled)
        let before = fixture.biometric.calls
        try await fixture.access.confirmSensitiveAction(reason: "Delete")
        #expect(fixture.biometric.calls == before)
    }

    private func makeAccess(enabled: Bool = false, vault: WalletVault = WalletVault()) throws -> AccessFixture {
        let suite = "BitTool Signer.AppAccessTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(enabled, forKey: AppAccessController.preferenceKey)
        let biometric = TestBiometric(), clock = TestUptime()
        let access = AppAccessController(vault: vault, defaults: defaults, biometric: biometric, uptime: { clock.value })
        return AccessFixture(access: access, biometric: biometric, clock: clock, defaults: defaults, suite: suite, vault: vault)
    }
}

@MainActor
private struct AccessFixture {
    let access: AppAccessController
    let biometric: TestBiometric
    let clock: TestUptime
    let defaults: UserDefaults
    let suite: String
    let vault: WalletVault
}
@MainActor private final class TestUptime { var value: TimeInterval = 100 }
@MainActor
private final class TestBiometric: AppBiometricAuthenticating {
    var calls = 0
    var shouldFail = false
    var blockNext = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func authenticate(reason: String) async throws {
        calls += 1
        if shouldFail { throw AppIssue.message("Public biometric failure fixture.") }
        if blockNext {
            blockNext = false
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                startWaiters.forEach { $0.resume() }; startWaiters = []
            }
        }
    }
    func waitUntilStarted() async {
        if continuation == nil { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func complete() { continuation?.resume(); continuation = nil }
    func cancel() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
