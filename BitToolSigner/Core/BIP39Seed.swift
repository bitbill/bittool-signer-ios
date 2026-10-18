import Foundation
import CommonCrypto
import Darwin

/// BIP39 seed stretching (PBKDF2-HMAC-SHA512, 2048 rounds) in native code. The
/// JavaScript engine runs without JIT on iOS, where the same work takes most of
/// a second. The engine still validates the phrase at import and re-derives and
/// checks every signing key against the fixed plan.
enum BIP39Seed {
    /// The longest a valid phrase can be after NFKD: 24 words from the
    /// bundled wordlist with the longest words (Korean, 33 bytes each) plus
    /// the 23 separating spaces, rounded up for headroom. A tighter bound
    /// rejects real Japanese and Korean backups — the words are long, and the
    /// byte count says nothing about how much entropy they carry. The phrase
    /// itself is validated against the wordlists and its checksum elsewhere;
    /// this is only a guard against unbounded input.
    static let maximumPhraseBytes = 1024

    /// Returns the 64-byte seed as lowercase hex. `mnemonic` must already be a
    /// validated phrase; both inputs are NFKD-normalized as BIP39 specifies.
    static func hex(mnemonic: String, passphrase: String) throws -> String {
        let normalizedPhrase = mnemonic
            .decomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedPhrase.isEmpty, normalizedPhrase.utf8.count <= Self.maximumPhraseBytes,
              passphrase.utf8.count <= 1024 else {
            throw VaultError.invalidSecret
        }
        var password = Array(normalizedPhrase.utf8)
        var salt = Array(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        var seed = [UInt8](repeating: 0, count: 64)
        defer { wipe(&password); wipe(&salt); wipe(&seed) }
        let status = password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                seed.withUnsafeMutableBufferPointer { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBuffer.count,
                                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBuffer.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 2048,
                                        output.baseAddress, output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.keyDerivationFailure }
        return seed.map { String(format: "%02x", $0) }.joined()
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } }
    }
}
