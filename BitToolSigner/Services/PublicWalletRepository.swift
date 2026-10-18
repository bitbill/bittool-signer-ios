import Foundation
import CryptoKit
import Darwin

struct PublicWalletSnapshot: Sendable {
    let displayName: String?
    let metadata: WalletPublicMetadata?
    let status: PublicMetadataStatus
}

/// Public keys, addresses and display names for each wallet. They cannot spend
/// funds but reveal account relationships and drive the receive addresses people
/// share, so each file is device-protected, excluded from backup and
/// authenticated with an HMAC key kept in the Keychain. A missing, damaged or
/// modified file never triggers seed decryption; the wallet shows "Repair".
///
/// File format: `{"schemaVersion":2,"body":<base64 JSON>,"mac":<hex>}` where the
/// MAC covers a domain label, the wallet ID and the exact body bytes.
actor PublicWalletRepository {
    private let directory: URL
    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.directory = directory ?? support.appendingPathComponent("BitToolSigner/PublicWallets", isDirectory: true)
    }

    func snapshot(walletID: UUID, key: SymmetricKey?) -> PublicWalletSnapshot {
        guard FileManager.default.fileExists(atPath: file(walletID).path) else {
            return PublicWalletSnapshot(displayName: nil, metadata: nil, status: .needsCompletion)
        }
        guard let key else { return PublicWalletSnapshot(displayName: nil, metadata: nil, status: .invalid) }
        do {
            let body = try read(walletID, key: key)
            let name = body["displayName"] as? String
            if let name, !Self.validName(name) { throw VaultError.invalidName }
            guard let index = body["publicIndex"] as? [String: Any] else {
                return PublicWalletSnapshot(displayName: name, metadata: nil, status: .needsCompletion)
            }
            return PublicWalletSnapshot(displayName: name, metadata: try WalletPublicMetadata(index), status: .ready)
        } catch { return PublicWalletSnapshot(displayName: nil, metadata: nil, status: .invalid) }
    }

    func save(_ metadata: WalletPublicMetadata, walletID: UUID, displayName: String? = nil, key: SymmetricKey) throws {
        var body: [String: Any] = ["localWalletId": walletID.uuidString, "publicIndex": metadata.raw]
        let name = displayName ?? (try? read(walletID, key: key)["displayName"] as? String)
        if let name {
            guard Self.validName(name) else { throw VaultError.invalidName }
            body["displayName"] = name
        }
        try write(body, id: walletID, key: key)
    }

    func rename(walletID: UUID, name: String, key: SymmetricKey) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { throw VaultError.invalidName }
        var body = (try? read(walletID, key: key)) ?? ["localWalletId": walletID.uuidString]
        body["displayName"] = name
        try write(body, id: walletID, key: key)
    }

    func remove(walletID: UUID) throws {
        guard FileManager.default.fileExists(atPath: file(walletID).path) else { return }
        try FileManager.default.removeItem(at: file(walletID))
    }

    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 40
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json") }

    private static func mac(_ body: Data, id: UUID, key: SymmetricKey) -> Data {
        var authenticated = Data("com.bittool.signer.public-wallet.v2\0".utf8)
        authenticated.append(Data(id.uuidString.lowercased().utf8))
        authenticated.append(0)
        authenticated.append(body)
        return Data(HMAC<SHA256>.authenticationCode(for: authenticated, using: key))
    }

    private func read(_ id: UUID, key: SymmetricKey) throws -> [String: Any] {
        let url = file(id)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 600_000,
              let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              envelope["schemaVersion"] as? Int == 2,
              let encoded = envelope["body"] as? String, let body = Data(base64Encoded: encoded),
              let tag = envelope["mac"] as? String, tag.count == 64,
              let expected = Data(hexString: tag),
              // Constant-time comparison of the authentication tag.
              expected.count == 32, Self.mac(body, id: id, key: key).withUnsafeBytes({ lhs in
                  expected.withUnsafeBytes { rhs in timingsafe_bcmp(lhs.baseAddress, rhs.baseAddress, 32) == 0 }
              }),
              let raw = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              UUID(uuidString: raw["localWalletId"] as? String ?? "") == id else {
            throw AppIssue.message(String(localized: "Invalid public wallet data.", bundle: AppText.bundle))
        }
        return raw
    }

    private func write(_ body: [String: Any], id: UUID, key: SymmetricKey) throws {
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard bodyData.count <= 300_000 else { throw AppIssue.message(String(localized: "Public wallet data is too large.", bundle: AppText.bundle)) }
        let envelope: [String: Any] = ["schemaVersion": 2, "body": bodyData.base64EncodedString(),
                                       "mac": Self.mac(bodyData, id: id, key: key).map { String(format: "%02x", $0) }.joined()]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        var folder = directory, resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try folder.setResourceValues(resourceValues)
        var staged = directory.appendingPathComponent(".pending-\(UUID())")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete], ofItemAtPath: staged.path)
        try staged.setResourceValues(resourceValues)
        guard Darwin.rename(staged.path, file(id).path) == 0 else { throw VaultError.storageFailure }
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
}
