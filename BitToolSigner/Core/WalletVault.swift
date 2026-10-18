import Foundation
import Security
import LocalAuthentication
import Darwin
import CryptoKit

protocol DeviceKeyStore: Sendable {
    func create(id: UUID, key: Data) throws
    func read(id: UUID) throws -> Data
    func delete(id: UUID) throws
}

/// Device keys never synchronize or migrate to another device. Removing the device
/// passcode invalidates the item. No weaker accessibility fallback is permitted.
struct KeychainDeviceKeyStore: DeviceKeyStore {
    private let service = "com.bittool.signer.vault.device-key.v1"

    func create(id: UUID, key: Data) throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw VaultError.devicePasscodeRequired
        }
        var attributes = query(id)
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == errSecNotAvailable || status == errSecInteractionNotAllowed {
                throw VaultError.devicePasscodeRequired
            }
            throw VaultError.deviceKeyUnavailable
        }
    }

    func read(id: UUID) throws -> Data {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let key = result as? Data, key.count == 32 else {
            throw VaultError.deviceKeyUnavailable
        }
        return key
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.deviceKeyUnavailable }
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString.lowercased()]
    }
}

/// Serializes filesystem mutations and performs password work away from the UI.
/// No password, clear recovery phrase, or derived key is retained between calls.
actor WalletVault {
    private let directory: URL
    private let deviceKeys: any DeviceKeyStore
    private struct AuthenticationState: Codable {
        let count: Int
        let retryAfter: Date
    }

    init(directory: URL? = nil, deviceKeys: any DeviceKeyStore = KeychainDeviceKeyStore()) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        self.directory = directory ?? applicationSupport.appendingPathComponent("BitToolSigner/Vaults", isDirectory: true)
        self.deviceKeys = deviceKeys
    }

    func list() throws -> [VaultMetadata] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            return try files.filter { $0.pathExtension == "bsvault" }.map { file in
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                    throw VaultError.malformedVault
                }
                return try load(id: id).header.metadata
            }.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                // Directory enumeration must not reorder wallets with equal timestamps.
                return $0.id.uuidString < $1.id.uuidString
            }
        } catch let error as VaultError { throw error }
        catch { throw VaultError.storageFailure }
    }

    func create(name: String, mnemonic: String, passphrase: String = "", password: String, id: UUID = UUID()) throws -> VaultMetadata {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw VaultError.invalidName }
        guard !FileManager.default.fileExists(atPath: fileURL(id).path) else { throw VaultError.storageFailure }
        // Millisecond precision keeps creation order stable for wallets added in quick succession.
        let metadata = VaultMetadata(id: id, name: name, createdAt: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded(.down) / 1000))
        let secret = VaultSecret(mnemonic: mnemonic, passphrase: passphrase)
        var key = try SecureRandom.bytes(count: 32)
        defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
        let encrypted = try VaultCrypto.encrypt(secret: secret, metadata: metadata, password: password, deviceKey: key)
        try deviceKeys.create(id: metadata.id, key: key)
        do {
            try save(encrypted)
        } catch {
            // The key is new and not shared with any previously saved wallet.
            try? deviceKeys.delete(id: metadata.id)
            throw error
        }
        return metadata
    }

    /// Fixed Keychain identity for the app-wide key that authenticates public
    /// wallet files. It never collides with random wallet UUIDs.
    static let publicDataKeyID = UUID(uuidString: "0B175160-9A7E-4C1D-8000-00000000C0DE")!

    /// Returns the public-data HMAC key, creating it only when asked (creation needs
    /// a device passcode, like any wallet). Missing keys make public files invalid.
    func publicDataKey(createIfMissing: Bool) throws -> SymmetricKey? {
        if var key = try? deviceKeys.read(id: Self.publicDataKeyID) {
            defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
            return SymmetricKey(data: key)
        }
        guard createIfMissing else { return nil }
        var key = try SecureRandom.bytes(count: 32)
        defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
        try deviceKeys.create(id: Self.publicDataKeyID, key: key)
        return SymmetricKey(data: key)
    }

    func unlock(id: UUID, password: String) throws -> VaultSecret {
        let encrypted = try load(id: id)
        var key = try deviceKeys.read(id: id)
        defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
        let previous = try authenticationState(id: id, deviceKey: key)
        if previous.retryAfter > Date() {
            throw VaultError.temporarilyLocked(max(1, Int(ceil(previous.retryAfter.timeIntervalSinceNow))))
        }
        let count = min(previous.count + 1, 16)
        let delay = count >= 5 ? min(300.0, pow(2.0, Double(count - 4))) : 0
        // Persist the attempt before costly decryption. Killing and relaunching
        // the process cannot reset the counter or interrupt its persistence.
        try saveAuthenticationState(AuthenticationState(count: count, retryAfter: Date().addingTimeInterval(delay)), id: id, deviceKey: key)
        guard !password.isEmpty, password.utf8.count <= 1024 else { throw VaultError.authenticationFailed }
        let secret = try VaultCrypto.decrypt(encrypted, password: password, deviceKey: key)
        try saveAuthenticationState(AuthenticationState(count: 0, retryAfter: .distantPast), id: id, deviceKey: key)
        return secret
    }

    func changePassword(id: UUID, currentPassword: String, newPassword: String) throws {
        let validation = PasswordPolicy.evaluate(newPassword)
        guard validation.isValid else { throw VaultError.invalidPassword(validation.message) }
        let secret = try unlock(id: id, password: currentPassword)
        let metadata = try load(id: id).header.metadata
        var key = try deviceKeys.read(id: id)
        defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
        let encrypted = try VaultCrypto.encrypt(secret: secret, metadata: metadata, password: newPassword, deviceKey: key)
        try save(encrypted)
    }

    /// App access authentication has no secret-returning API. Verification may
    /// decrypt the existing authenticated format, but its result dies here.
    func verifyPassword(id: UUID, password: String) throws {
        _ = try unlock(id: id, password: password)
    }

    func delete(id: UUID, password: String) throws {
        // Authentication is required even if a UI session is already unlocked.
        _ = try unlock(id: id, password: password)
        do { try FileManager.default.removeItem(at: fileURL(id)) }
        catch { throw VaultError.storageFailure }
        try? FileManager.default.removeItem(at: authenticationURL(id))
        // If the OS refuses Keychain deletion after file removal, report the failure.
        // A remaining random key alone contains no wallet secret.
        try deviceKeys.delete(id: id)
    }

    private func load(id: UUID) throws -> EncryptedVault {
        let file = fileURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw VaultError.walletNotFound }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw VaultError.malformedVault }
            let data = try Data(contentsOf: file, options: [])
            let encrypted = try JSONDecoder().decode(EncryptedVault.self, from: data)
            try VaultCrypto.validate(encrypted)
            guard encrypted.header.metadata.id == id else { throw VaultError.malformedVault }
            return encrypted
        } catch let error as VaultError { throw error }
        catch { throw VaultError.malformedVault }
    }

    private func authenticationURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(".\(id.uuidString.lowercased()).attempts")
    }

    private func authenticationState(id: UUID, deviceKey: Data) throws -> AuthenticationState {
        let file = authenticationURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return AuthenticationState(count: 0, retryAfter: .distantPast)
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 1024,
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw VaultError.malformedVault }
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: deviceKey),
                                            authenticating: Data("com.bittool.signer.auth.v1/\(id.uuidString)".utf8))
            let state = try JSONDecoder().decode(AuthenticationState.self, from: plaintext)
            guard (0...16).contains(state.count) else { throw VaultError.malformedVault }
            return state
        } catch { throw VaultError.malformedVault }
    }

    private func saveAuthenticationState(_ state: AuthenticationState, id: UUID, deviceKey: Data) throws {
        do {
            let box = try AES.GCM.seal(JSONEncoder().encode(state), using: SymmetricKey(data: deviceKey),
                                       authenticating: Data("com.bittool.signer.auth.v1/\(id.uuidString)".utf8))
            guard let ciphertext = box.combined else { throw VaultError.encryptionFailure }
            try writeProtected(ciphertext, to: authenticationURL(id))
        } catch { throw VaultError.storageFailure }
    }

    private func save(_ vault: EncryptedVault) throws {
        try writeProtected(VaultCrypto.encoder().encode(vault), to: fileURL(vault.header.metadata.id))
    }

    private func writeProtected(_ data: Data, to file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            var staged = directory.appendingPathComponent(".pending-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            try data.write(to: staged, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete], ofItemAtPath: staged.path)
            try staged.setResourceValues(values)
            // All protection attributes exist before atomic replacement. A failed
            // preparation leaves the previous vault/password intact.
            guard rename(staged.path, file.path) == 0 else { throw VaultError.storageFailure }
        } catch { throw VaultError.storageFailure }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("bsvault")
    }
}
