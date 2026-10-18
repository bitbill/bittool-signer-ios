import Foundation
import CryptoKit
import Testing
@testable import BitToolSigner

struct SecurityTests {
    private let password = "Strong-Password1"
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    @Test func passwordRulesAndBoundaries() {
        #expect(PasswordPolicy.evaluate("Abcdefg1").isValid)
        #expect(PasswordPolicy.evaluate("abcdef1!").isValid)
        #expect(!PasswordPolicy.evaluate("Abcde1!").isValid)
        #expect(!PasswordPolicy.evaluate("alllowercase").isValid)
        #expect(!PasswordPolicy.evaluate("ABCDEFG1").isValid)
        #expect(!PasswordPolicy.evaluate("Abcdefg\n1").isValid)
        #expect(PasswordPolicy.evaluate("Aa1" + String(repeating: "x", count: 61)).isValid)
        #expect(!PasswordPolicy.evaluate("Aa1" + String(repeating: "x", count: 62)).isValid)
        #expect(PasswordPolicy.evaluate("Spaces are Allowed1!").isValid)
    }

    @Test func nativeEntropyIsBoundedAndUnique() throws {
        let first = try SecureRandom.bytes(count: 32)
        let second = try SecureRandom.bytes(count: 32)
        #expect(first.count == 32)
        #expect(first != second)
        #expect(try SecureRandom.entropyHex(wordCount: 12).count == 32)
        #expect(try SecureRandom.entropyHex(wordCount: 24).count == 64)
        #expect(throws: VaultError.randomFailure) { try SecureRandom.bytes(count: 65_537) }
        #expect(throws: VaultError.invalidSecret) { try SecureRandom.entropyHex(wordCount: 13) }
    }

    @Test func passwordDerivationMatchesIndependentVector() throws {
        let key = try VaultCrypto.deriveKey(password: "Test-Password1", salt: Data(0..<32))
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "05b079f15d09a3589c02ca352a3dd38ad23daf4663a59d6072c2333ddb4901d9")
    }

    @Test func encryptionRoundTripAndDistinctSaltAndNonce() throws {
        let metadata = VaultMetadata(id: UUID(), name: "Offline wallet", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let secret = VaultSecret(mnemonic: phrase, passphrase: "a separate BIP39 passphrase")
        let deviceKey = try SecureRandom.bytes(count: 32)
        let first = try VaultCrypto.encrypt(secret: secret, metadata: metadata, password: password, deviceKey: deviceKey)
        let second = try VaultCrypto.encrypt(secret: secret, metadata: metadata, password: password, deviceKey: deviceKey)
        #expect(first.header.salt != second.header.salt)
        #expect(first.ciphertext != second.ciphertext)
        #expect(try VaultCrypto.decrypt(first, password: password, deviceKey: deviceKey) == secret)
        let serialized = try VaultCrypto.encoder().encode(first)
        let restored = try JSONDecoder().decode(EncryptedVault.self, from: serialized)
        #expect(try VaultCrypto.decrypt(restored, password: password, deviceKey: deviceKey) == secret)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(!text.contains(phrase))
        #expect(!text.contains(password))
        #expect(!text.contains(secret.passphrase))
    }

    @Test func authenticationRejectsWrongPasswordDeviceAndTampering() throws {
        let metadata = VaultMetadata(id: UUID(), name: "Original", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let key = try SecureRandom.bytes(count: 32)
        let vault = try VaultCrypto.encrypt(secret: VaultSecret(mnemonic: phrase, passphrase: ""),
                                           metadata: metadata, password: password, deviceKey: key)
        #expect(throws: VaultError.authenticationFailed) {
            try VaultCrypto.decrypt(vault, password: "Wrong-Password1", deviceKey: key)
        }
        #expect(throws: VaultError.authenticationFailed) {
            try VaultCrypto.decrypt(vault, password: password, deviceKey: Data(repeating: 0, count: 32))
        }
        var damaged = vault.ciphertext
        damaged[damaged.count - 1] ^= 0x01
        #expect(throws: VaultError.authenticationFailed) {
            try VaultCrypto.decrypt(EncryptedVault(header: vault.header, ciphertext: damaged), password: password, deviceKey: key)
        }
        let changedHeader = VaultHeader(version: vault.header.version,
            metadata: VaultMetadata(id: metadata.id, name: "Attacker renamed", createdAt: metadata.createdAt),
            kdf: vault.header.kdf, iterations: vault.header.iterations, salt: vault.header.salt)
        #expect(throws: VaultError.authenticationFailed) {
            try VaultCrypto.decrypt(EncryptedVault(header: changedHeader, ciphertext: vault.ciphertext), password: password, deviceKey: key)
        }
        let unreasonableKDF = VaultHeader(version: VaultCrypto.version, metadata: metadata, kdf: VaultCrypto.kdf,
                                           iterations: UInt32.max, salt: vault.header.salt)
        #expect(throws: VaultError.malformedVault) {
            try VaultCrypto.decrypt(EncryptedVault(header: unreasonableKDF, ciphertext: vault.ciphertext), password: password, deviceKey: key)
        }
    }

    @Test func throttlingSurvivesANewVaultServiceInstance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-throttle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MemoryDeviceKeys()
        let store = WalletVault(directory: directory, deviceKeys: keys)
        let wallet = try await store.create(name: "Throttle test", mnemonic: phrase, password: password)
        for _ in 0..<5 {
            await #expect(throws: VaultError.authenticationFailed) {
                try await store.unlock(id: wallet.id, password: "Wrong-Password1")
            }
        }
        let restarted = WalletVault(directory: directory, deviceKeys: keys)
        do {
            _ = try await restarted.unlock(id: wallet.id, password: password)
            Issue.record("A newly created service must retain the previous authentication delay.")
        } catch VaultError.temporarilyLocked(let seconds) {
            #expect(seconds > 0)
        }
    }

    #if DEBUG
    @Test func javascriptBridgeHasFreshScopeNativeEntropyAndNoNetwork() async throws {
        let source = """
        var BitToolSignerEngine = {dispatch: function (json) {
            var request = JSON.parse(json);
            globalThis.invocations = (globalThis.invocations || 0) + 1;
            var bytes = new Uint8Array(32); crypto.getRandomValues(bytes);
            return JSON.stringify({ok: true, result: {
                invocations: globalThis.invocations,
                random: Array.from(bytes).join(','),
                hasNetwork: typeof fetch !== 'undefined' || typeof XMLHttpRequest !== 'undefined',
                echo: request.text
            }});
        }};
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-bridge-\(UUID()).js")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let bridge = SigningEngine(sourceURL: url)
        let dangerousText = "\"; globalThis.invocations = 99; //"
        let first = try await bridge.run(operation: "review", parameters: ["text": dangerousText])
        let second = try await bridge.run(operation: "review", parameters: ["text": dangerousText])
        #expect(first["invocations"] as? Int == 1)
        #expect(second["invocations"] as? Int == 1)
        #expect(first["random"] as? String != second["random"] as? String)
        #expect(first["hasNetwork"] as? Bool == false)
        #expect(first["echo"] as? String == dangerousText)
    }

    #endif

    @Test func bundledEngineProducesBIP39AndAccountKnownVectors() async throws {
        let engine = SigningEngine()
        let result = try await engine.run(operation: "mnemonic", parameters: ["entropy": String(repeating: "0", count: 32)])
        #expect(result["mnemonic"] as? String == phrase)
        let derived = try await engine.run(operation: "deriveAccounts", parameters: ["mnemonic": phrase])
        let accounts = try #require(derived["accounts"] as? [[String: Any]])
        #expect(accounts.count == 4)
        let evm = accounts.first { $0["chain"] as? String == "evm" }
        #expect(evm?["address"] as? String == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
    }

    @Test func multipleWalletsPasswordRotationAndReauthenticatedDelete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalletVault(directory: directory, deviceKeys: MemoryDeviceKeys())
        #expect(try await store.list().isEmpty)
        let first = try await store.create(name: "First", mnemonic: phrase, password: password)
        let second = try await store.create(name: "Second", mnemonic: phrase, passphrase: "different account", password: "Another-Password2")
        #expect(try await store.list().count == 2)
        #expect(try await store.unlock(id: first.id, password: password).mnemonic == phrase)
        #expect(try await store.unlock(id: second.id, password: "Another-Password2").passphrase == "different account")
        try await store.changePassword(id: first.id, currentPassword: password, newPassword: "Replacement-Password2")
        await #expect(throws: VaultError.authenticationFailed) { try await store.unlock(id: first.id, password: password) }
        #expect(try await store.unlock(id: first.id, password: "Replacement-Password2").mnemonic == phrase)
        await #expect(throws: VaultError.authenticationFailed) { try await store.delete(id: first.id, password: "Wrong-Password1") }
        #expect(try await store.list().count == 2)
        try await store.delete(id: first.id, password: "Replacement-Password2")
        #expect(try await store.list().map(\.id) == [second.id])
    }

    /// Forgetting the password is recoverable with the recovery phrase, which
    /// is what the password screen now says. The wallet keeps its identity:
    /// re-importing into a new record would lose its name, date and pairings.
    @Test func aForgottenPasswordIsResetFromTheRecoveryPhrase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalletVault(directory: directory, deviceKeys: MemoryDeviceKeys())
        let wallet = try await store.create(name: "Mine", mnemonic: phrase, passphrase: "account two", password: password)

        try await store.resetPassword(id: wallet.id, mnemonic: phrase, passphrase: "account two", newPassword: "Replacement-Password2")
        await #expect(throws: VaultError.authenticationFailed) { try await store.unlock(id: wallet.id, password: password) }
        let reopened = try await store.unlock(id: wallet.id, password: "Replacement-Password2")
        #expect(reopened.mnemonic == phrase)
        #expect(reopened.passphrase == "account two")

        let listed = try await store.list()
        #expect(listed.count == 1, "the wallet is reset in place, never duplicated")
        #expect(listed.first?.id == wallet.id)
        #expect(listed.first?.name == "Mine")
        #expect(listed.first?.createdAt == wallet.createdAt)
    }

    @Test func aResetStillHasToOfferAnAcceptablePasswordAndAnExistingWallet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalletVault(directory: directory, deviceKeys: MemoryDeviceKeys())
        let wallet = try await store.create(name: "Mine", mnemonic: phrase, password: password)

        await #expect(throws: VaultError.self) {
            try await store.resetPassword(id: wallet.id, mnemonic: phrase, passphrase: "", newPassword: "weak")
        }
        #expect(try await store.unlock(id: wallet.id, password: password).mnemonic == phrase, "a refused reset changes nothing")

        await #expect(throws: VaultError.walletNotFound) {
            try await store.resetPassword(id: UUID(), mnemonic: phrase, passphrase: "", newPassword: "Replacement-Password2")
        }
    }

    /// Five wrong guesses start a delay before each further attempt. Proving
    /// the recovery phrase is not a wrong guess, and the person who just did it
    /// is not left waiting on the counter their forgotten password built up.
    @Test func aResetClearsTheFailedAttemptDelay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WalletVault(directory: directory, deviceKeys: MemoryDeviceKeys())
        let wallet = try await store.create(name: "Mine", mnemonic: phrase, password: password)
        for _ in 0..<5 { try? await store.unlock(id: wallet.id, password: "Wrong-Password1") }
        await #expect(throws: VaultError.self) { try await store.unlock(id: wallet.id, password: password) }

        try await store.resetPassword(id: wallet.id, mnemonic: phrase, passphrase: "", newPassword: "Replacement-Password2")
        #expect(try await store.unlock(id: wallet.id, password: "Replacement-Password2").mnemonic == phrase)
    }
}

private final class MemoryDeviceKeys: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]

    func create(id: UUID, key: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[id] = key
    }

    func read(id: UUID) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let key = keys[id] else { throw VaultError.deviceKeyUnavailable }
        return key
    }

    func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[id] = nil
    }
}
