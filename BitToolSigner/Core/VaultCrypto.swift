import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

/// Errors deliberately exclude passwords, phrases, key material and JavaScript input.
enum VaultError: LocalizedError, Equatable {
    case invalidPassword(String)
    case invalidSecret
    case invalidName
    case randomFailure
    case keyDerivationFailure
    case encryptionFailure
    case authenticationFailed
    case deviceKeyUnavailable
    case devicePasscodeRequired
    case storageFailure
    case malformedVault
    case unsupportedVersion
    case walletNotFound
    case temporarilyLocked(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPassword(let message): return message
        case .invalidSecret: return String(localized: "The recovery phrase is empty or too large.", bundle: AppText.bundle)
        case .invalidName: return String(localized: "Choose a wallet name of 1–40 characters.", bundle: AppText.bundle)
        case .randomFailure: return String(localized: "Secure randomness is unavailable. Try again after unlocking your device.", bundle: AppText.bundle)
        case .keyDerivationFailure: return String(localized: "The password key could not be created.", bundle: AppText.bundle)
        case .encryptionFailure: return String(localized: "The encrypted wallet could not be created.", bundle: AppText.bundle)
        case .authenticationFailed: return String(localized: "The password is incorrect or the encrypted wallet has been modified.", bundle: AppText.bundle)
        case .deviceKeyUnavailable: return String(localized: "This wallet’s device key is unavailable. Restore your recovery phrase on this device.", bundle: AppText.bundle)
        case .devicePasscodeRequired: return String(localized: "Set an iPhone passcode before creating a wallet. The device key requires passcode protection.", bundle: AppText.bundle)
        case .storageFailure: return String(localized: "The encrypted wallet could not be read or saved.", bundle: AppText.bundle)
        case .malformedVault: return String(localized: "The wallet file is damaged or has an invalid format.", bundle: AppText.bundle)
        case .unsupportedVersion: return String(localized: "This wallet format is not supported by this version of BitTool Signer.", bundle: AppText.bundle)
        case .walletNotFound: return String(localized: "This wallet could not be found.", bundle: AppText.bundle)
        case .temporarilyLocked(let seconds): return String(localized: "Too many unsuccessful attempts. Try again in \(seconds) seconds.", bundle: AppText.bundle)
        }
    }
}

enum SecureRandom {
    static func bytes(count: Int) throws -> Data {
        guard (1...65_536).contains(count) else { throw VaultError.randomFailure }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard status == errSecSuccess else { throw VaultError.randomFailure }
        return data
    }

    static func entropyHex(wordCount: Int = 24) throws -> String {
        guard [12, 15, 18, 21, 24].contains(wordCount) else { throw VaultError.invalidSecret }
        return try bytes(count: wordCount / 3 * 4).map { String(format: "%02x", $0) }.joined()
    }
}

struct VaultMetadata: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
}

/// Returned only after authentication. Callers must release it on lock/background.
/// Swift String and JavaScript garbage collectors do not guarantee memory zeroization.
struct VaultSecret: Codable, Equatable, Sendable {
    let mnemonic: String
    let passphrase: String
}

struct VaultHeader: Codable, Sendable {
    let version: Int
    let metadata: VaultMetadata
    let kdf: String
    let iterations: UInt32
    let salt: Data
}

/// Stored as `{format, header, ciphertext}` where `header` holds the exact JSON
/// bytes that both AES-GCM layers authenticate. Authenticating stored bytes (not a
/// re-encoding of the parsed header) keeps vaults valid across Foundation changes.
struct EncryptedVault: Codable, Sendable {
    let header: VaultHeader
    let headerBytes: Data
    /// An AES-GCM password ciphertext wrapped in a second AES-GCM device ciphertext.
    let ciphertext: Data

    private enum CodingKeys: String, CodingKey { case format, header, ciphertext }

    init(header: VaultHeader, ciphertext: Data) throws {
        self.header = header
        headerBytes = try VaultCrypto.encoder().encode(header)
        self.ciphertext = ciphertext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .format) == VaultCrypto.version else { throw VaultError.unsupportedVersion }
        headerBytes = try container.decode(Data.self, forKey: .header)
        guard headerBytes.count <= 4096 else { throw VaultError.malformedVault }
        header = try JSONDecoder().decode(VaultHeader.self, from: headerBytes)
        ciphertext = try container.decode(Data.self, forKey: .ciphertext)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(VaultCrypto.version, forKey: .format)
        try container.encode(headerBytes, forKey: .header)
        try container.encode(ciphertext, forKey: .ciphertext)
    }
}

enum VaultCrypto {
    static let iterations: UInt32 = 600_000
    static let version = 2
    static let kdf = "PBKDF2-HMAC-SHA256"

    static func deriveKey(password: String, salt: Data, iterations: UInt32 = iterations) throws -> SymmetricKey {
        guard !password.isEmpty, password.utf8.count <= 1024,
              salt.count == 32, (600_000...2_000_000).contains(iterations) else {
            throw VaultError.malformedVault
        }
        var passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer {
            passwordBytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } }
            derived.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } }
        }
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                derived.withUnsafeMutableBufferPointer { keyBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBuffer.count,
                                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBuffer.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                        keyBuffer.baseAddress, keyBuffer.count)
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.keyDerivationFailure }
        return SymmetricKey(data: derived)
    }

    static func encrypt(secret: VaultSecret, metadata: VaultMetadata, password: String, deviceKey: Data) throws -> EncryptedVault {
        let evaluation = PasswordPolicy.evaluate(password)
        guard evaluation.isValid else { throw VaultError.invalidPassword(evaluation.message) }
        guard !secret.mnemonic.isEmpty, secret.mnemonic.utf8.count <= 8192,
              secret.passphrase.utf8.count <= 1024 else { throw VaultError.invalidSecret }
        guard deviceKey.count == 32 else { throw VaultError.deviceKeyUnavailable }
        let header = VaultHeader(version: version, metadata: metadata, kdf: kdf,
                                 iterations: iterations, salt: try SecureRandom.bytes(count: 32))
        let headerBytes = try encoder().encode(header)
        let passwordKey = try deriveKey(password: password, salt: header.salt)
        var cleartext = try encoder().encode(secret)
        defer { cleartext.resetBytes(in: cleartext.startIndex..<cleartext.endIndex) }
        do {
            let passwordBox = try AES.GCM.seal(cleartext, using: passwordKey,
                                               authenticating: aad(headerBytes, layer: "password"))
            guard let passwordCiphertext = passwordBox.combined else { throw VaultError.encryptionFailure }
            let deviceBox = try AES.GCM.seal(passwordCiphertext, using: SymmetricKey(data: deviceKey),
                                             authenticating: aad(headerBytes, layer: "device"))
            guard let ciphertext = deviceBox.combined else { throw VaultError.encryptionFailure }
            return try EncryptedVault(header: header, ciphertext: ciphertext)
        } catch {
            throw VaultError.encryptionFailure
        }
    }

    static func decrypt(_ vault: EncryptedVault, password: String, deviceKey: Data) throws -> VaultSecret {
        try validate(vault)
        guard deviceKey.count == 32 else { throw VaultError.deviceKeyUnavailable }
        // Bound imported parameters before performing costly password derivation.
        let passwordKey = try deriveKey(password: password, salt: vault.header.salt, iterations: vault.header.iterations)
        do {
            let deviceBox = try AES.GCM.SealedBox(combined: vault.ciphertext)
            let passwordCiphertext = try AES.GCM.open(deviceBox, using: SymmetricKey(data: deviceKey),
                                                    authenticating: aad(vault.headerBytes, layer: "device"))
            let passwordBox = try AES.GCM.SealedBox(combined: passwordCiphertext)
            var cleartext = try AES.GCM.open(passwordBox, using: passwordKey,
                                            authenticating: aad(vault.headerBytes, layer: "password"))
            defer { cleartext.resetBytes(in: cleartext.startIndex..<cleartext.endIndex) }
            return try JSONDecoder().decode(VaultSecret.self, from: cleartext)
        } catch {
            throw VaultError.authenticationFailed
        }
    }

    static func validate(_ vault: EncryptedVault) throws {
        guard vault.header.version == version, vault.header.kdf == kdf else { throw VaultError.unsupportedVersion }
        guard vault.header.salt.count == 32,
              (600_000...2_000_000).contains(vault.header.iterations),
              (56...32_768).contains(vault.ciphertext.count),
              !vault.header.metadata.name.isEmpty, vault.header.metadata.name.count <= 40 else {
            throw VaultError.malformedVault
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func aad(_ headerBytes: Data, layer: String) -> Data {
        var data = Data("com.bittool.signer.vault.v2/\(layer)\0".utf8)
        data.append(headerBytes)
        return data
    }
}
