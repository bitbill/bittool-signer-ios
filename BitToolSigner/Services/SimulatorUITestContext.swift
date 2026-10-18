#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Simulator-only, opt-in fixtures. No part of this implementation is compiled
/// into device or Release builds. It never accesses production vaults/Keychain.
@MainActor
struct SimulatorUITestContext {
    let store: AppStore
    let access: AppAccessController
    let defaults: UserDefaults

    static func requested() -> Self? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--bittool-signer-ui-tests"),
              let run = process.environment["BITTOOL_SIGNER_UI_TEST_RUN"], let id = UUID(uuidString: run) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BitToolSignerUITests/" + id.uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "com.bittool.signer.ui-tests." + id.uuidString)!
        if process.arguments.contains("--reset-ui-fixtures") {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: "com.bittool.signer.ui-tests." + id.uuidString)
        }
        let keys = SimulatorFixtureDeviceKeys(directory: directory.appendingPathComponent("FixtureKeys"))
        let vault = WalletVault(directory: directory.appendingPathComponent("Vaults"), deviceKeys: keys)
        let store = AppStore(vault: vault, storageDirectory: directory)
        if process.arguments.contains("--app-lock-enabled") { defaults.set(true, forKey: AppAccessController.preferenceKey) }
        if process.arguments.contains("--dark-appearance") { defaults.set("dark", forKey: "appearance") }
        if process.arguments.contains("--light-appearance") { defaults.set("light", forKey: "appearance") }
        let access = AppAccessController(vault: vault, defaults: defaults, biometric: SimulatorFixtureBiometrics())
        let count = min(8, max(0, Int(process.environment["BITTOOL_SIGNER_UI_FIXTURE_COUNT"] ?? "0") ?? 0))
        if count > 0 {
            defaults.set(1, forKey: "onboardingVersionCompleted")
            Task {
                while store.isLoading { await Task.yield() }
                guard store.wallets.isEmpty else { return }
                do {
                    for index in 0..<count {
                        _ = try await store.createWallet(name: "Public fixture \(index + 1)",
                            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
                            passphrase: index == 0 ? "" : "Public fixture \(index + 1)", password: "Public-Test-Password1!")
                    }
                } catch { store.error = "UI fixture setup failed: " + error.localizedDescription }
            }
        }
        return Self(store: store, access: access, defaults: defaults)
    }
}

private struct SimulatorFixtureDeviceKeys: DeviceKeyStore {
    let directory: URL
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }
    func create(id: UUID, key: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try key.write(to: file(id), options: .atomic)
    }
    func read(id: UUID) throws -> Data { try Data(contentsOf: file(id)) }
    func delete(id: UUID) throws { try FileManager.default.removeItem(at: file(id)) }
}

@MainActor private final class SimulatorFixtureBiometrics: AppBiometricAuthenticating {
    func authenticate(reason: String) async throws { throw AppIssue.message(String(localized: "Face ID was cancelled. Use a wallet password to continue.", bundle: AppText.bundle)) }
    func cancel() {}
}
#endif
