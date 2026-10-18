import Foundation
import CryptoKit
import Testing
@testable import BitToolSigner

/// Native pieces added in the 2026-09-21 redesign. Public fixtures only.
struct HardeningTests {
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let password = "Hardening-Password1"

    // MARK: Native BIP39 seed

    @Test func nativeSeedMatchesPublishedBIP39Vectors() throws {
        // Trezor BIP39 test vectors (passphrase "TREZOR").
        #expect(try BIP39Seed.hex(mnemonic: phrase, passphrase: "TREZOR")
                == "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
        #expect(try BIP39Seed.hex(mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow", passphrase: "TREZOR")
                == "2e8905819b8723fe2c1d161860e5ee1830318dbf49a83bd451cfb8440c28bd6fa457fe1296106559a3c80937a1c1069be3a3a5bd381ee6260e8d9739fce1f607")
        // Whitespace and case are normalized exactly as the engine does.
        #expect(try BIP39Seed.hex(mnemonic: "  ABANDON abandon\tabandon abandon abandon abandon abandon abandon abandon abandon abandon about ", passphrase: "TREZOR")
                == BIP39Seed.hex(mnemonic: phrase, passphrase: "TREZOR"))
        // NFKD: precomposed and decomposed passphrases are the same wallet.
        #expect(try BIP39Seed.hex(mnemonic: phrase, passphrase: "é") == BIP39Seed.hex(mnemonic: phrase, passphrase: "e\u{301}"))
        #expect(throws: VaultError.self) { try BIP39Seed.hex(mnemonic: "   ", passphrase: "") }
    }

    @Test func nativeSeedDerivesTheSameWalletAsTheEngine() async throws {
        let engine = SigningEngine()
        for passphrase in ["", "Public passphrase ✓"] {
            let fromPhrase = try await engine.run(operation: "derivePublicIndex", parameters: ["mnemonic": phrase, "passphrase": passphrase])
            let fromSeed = try await engine.run(operation: "derivePublicIndex", parameters: ["seed": try BIP39Seed.hex(mnemonic: phrase, passphrase: passphrase)])
            #expect(try WalletPublicMetadata(fromPhrase).jsonData == WalletPublicMetadata(fromSeed).jsonData)
        }
    }

    // MARK: Wordlist and phrase input

    @Test func bundledWordlistIsCanonicalAndMatchesTheEngine() async throws {
        let list = BIP39Wordlist(bundle: .main)
        #expect(list.isAvailable)
        #expect(list.words.first == "abandon" && list.words.last == "zoo")
        let engine = try await SigningEngine().run(operation: "wordlist", parameters: [:])
        #expect(engine["words"] as? [String] == list.words)
        #expect(list.suggestions(for: "aba") == ["abandon"])
        #expect(list.suggestions(for: "zz").isEmpty)
        #expect(list.suggestions(for: "ab", limit: 3) == ["abandon", "ability", "able"])
    }

    @Test func standardSeedQRDecodesAndRejectsMalformedDigits() {
        let list = BIP39Wordlist(bundle: .main)
        // Index 0 ("abandon") ×11 and 3 ("about").
        let digits = String(repeating: "0000", count: 11) + "0003"
        #expect(list.words(fromSeedQR: digits)?.joined(separator: " ") == phrase)
        #expect(list.words(fromSeedQR: digits.dropLast().description) == nil)
        #expect(list.words(fromSeedQR: String(repeating: "2048", count: 12)) == nil)
        #expect(list.words(fromSeedQR: "abandon " + digits) == nil)
    }

    @Test func phraseDraftReportsUnknownWordsButNotTheWordBeingTyped() {
        let typing = RecoveryPhraseDraft("abandon abandon ab")
        #expect(typing.partialWord == "ab")
        #expect(typing.unknownWords.isEmpty)
        let wrong = RecoveryPhraseDraft("abandon xyzzy abandon ")
        #expect(wrong.partialWord == nil)
        #expect(wrong.unknownWords == ["xyzzy"])
        #expect(RecoveryPhraseDraft(phrase).hasSupportedLength)
        #expect(!RecoveryPhraseDraft("abandon abandon").hasSupportedLength)
        // Twelve words whose last one is still a fragment are not shown as complete.
        let words = phrase.split(separator: " ")
        let unfinished = words.dropLast().joined(separator: " ") + " ab"
        #expect(RecoveryPhraseDraft(unfinished).hasSupportedLength)
        #expect(!RecoveryPhraseDraft(unfinished).looksComplete)
        #expect(RecoveryPhraseDraft(phrase).looksComplete)
        #expect(RecoveryPhraseDraft(phrase + " ").looksComplete)
    }

    // MARK: Storage integrity

    @Test func publicWalletFilesAreAuthenticated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-public-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = PublicWalletRepository(directory: directory)
        let index = try WalletPublicMetadata(await SigningEngine().run(operation: "derivePublicIndex", parameters: ["mnemonic": phrase]))
        let id = UUID(), key = SymmetricKey(size: .bits256)
        try await repository.save(index, walletID: id, displayName: "Public", key: key)
        let good = await repository.snapshot(walletID: id, key: key)
        #expect(good.status == .ready && good.displayName == "Public")
        #expect(await repository.snapshot(walletID: id, key: SymmetricKey(size: .bits256)).status == .invalid)
        #expect(await repository.snapshot(walletID: id, key: nil).status == .invalid)
        // Swap a displayed address inside the body: the MAC no longer verifies.
        let file = directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let encodedBody = try #require(envelope["body"] as? String)
        let body = try #require(Data(base64Encoded: encodedBody))
        let tampered = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\"displayName\":\"Public\"", with: "\"displayName\":\"Pwned\"")
        envelope["body"] = Data(tampered.utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        #expect(await repository.snapshot(walletID: id, key: key).status == .invalid)
        #expect(await repository.snapshot(walletID: UUID(), key: key).status == .needsCompletion)
    }

    @Test func vaultAuthenticatesTheExactStoredHeaderBytes() throws {
        let metadata = VaultMetadata(id: UUID(), name: "Header", createdAt: Date(timeIntervalSince1970: 1_700_000_000.123))
        let deviceKey = try SecureRandom.bytes(count: 32)
        let vault = try VaultCrypto.encrypt(secret: VaultSecret(mnemonic: phrase, passphrase: ""), metadata: metadata, password: password, deviceKey: deviceKey)
        let stored = try VaultCrypto.encoder().encode(vault)
        let restored = try JSONDecoder().decode(EncryptedVault.self, from: stored)
        #expect(restored.headerBytes == vault.headerBytes)
        #expect(try VaultCrypto.decrypt(restored, password: password, deviceKey: deviceKey).mnemonic == phrase)
        // Semantically identical but differently encoded header bytes are rejected.
        var object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let header = try #require(JSONSerialization.jsonObject(with: vault.headerBytes) as? [String: Any])
        object["header"] = try JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted]).base64EncodedString()
        let reencoded = try JSONDecoder().decode(EncryptedVault.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: VaultError.authenticationFailed) { try VaultCrypto.decrypt(reencoded, password: password, deviceKey: deviceKey) }
        object["format"] = 1
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EncryptedVault.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func appLockClockKeepsCountingAcrossSleepableIntervals() {
        let first = AppAccessController.monotonicSeconds()
        let second = AppAccessController.monotonicSeconds()
        #expect(second >= first)
        #expect(first > 0)
    }

    // MARK: Engine bridge

    @Test func incrementalScanSessionAssemblesAnimatedRequests() async throws {
        let engine = SigningEngine()
        let index = try await engine.run(operation: "derivePublicIndex", parameters: ["mnemonic": phrase])
        let pairing = try await engine.run(operation: "createPublicPairing", parameters: [
            "publicIndex": index, "chain": "bitcoin", "profile": "native", "outputMode": "accountXpub", "fragmentLength": 40])
        let frames = try #require(pairing["frames"] as? [String])
        #expect(frames.count > 1)
        // Pairing exports are not signing requests: the session must reject them clearly.
        try await engine.beginScanSession()
        await #expect(throws: SigningEngineError.self) { _ = try await engine.scan(frame: frames[0]) }
        await engine.endScanSession()
        await #expect(throws: SigningEngineError.self) { _ = try await engine.scan(frame: frames[0]) }

        // A real PSBT split into a fountain-coded animated QR is reassembled frame by frame.
        let fixtureURL = try #require(Bundle(for: HardeningFixtureBundle.self).url(forResource: "PublicPlanVectors", withExtension: "json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let vector = try #require((fixture["vectors"] as? [[String: Any]])?.first { ($0["request"] as? [String: Any])?["chain"] as? String == "bitcoin" })
        let psbt = try #require((vector["request"] as? [String: Any])?["psbt"] as? String)
        let animated = try await engine.run(operation: "encodeQR", parameters: ["type": "crypto-psbt", "payload": psbt, "encoding": "base64", "fragmentLength": 60])
        let parts = try #require(animated["frames"] as? [String])
        #expect(parts.count > 3)
        try await engine.beginScanSession()
        var result: [String: Any] = [:]
        for part in parts + parts {
            result = try await engine.scan(frame: part)
            if result["complete"] as? Bool == true { break }
        }
        #expect(result["complete"] as? Bool == true)
        #expect((result["request"] as? [String: Any])?["psbt"] as? String == psbt)
        await engine.endScanSession()
    }

    @Test func warmPublicContextReturnsStableResults() async throws {
        let engine = SigningEngine()
        let index = try await engine.run(operation: "derivePublicIndex", parameters: ["mnemonic": phrase])
        let first = try await engine.run(operation: "derivePublicAddresses", parameters: ["publicIndex": index, "chain": "evm", "start": 0, "count": 3])
        let second = try await engine.run(operation: "derivePublicAddresses", parameters: ["publicIndex": index, "chain": "evm", "start": 0, "count": 3])
        let addresses = (first["addresses"] as? [[String: Any]])?.compactMap { $0["address"] as? String }
        #expect(addresses?.first == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        #expect(addresses == (second["addresses"] as? [[String: Any]])?.compactMap { $0["address"] as? String })
        #if !DEBUG
        await #expect(throws: SigningEngineError.self) { _ = try await engine.run(operation: "sign", parameters: [:]) }
        #endif
    }

    // MARK: Presentation helpers

    @Test func addressGroupingPreservesEveryCharacter() {
        let evm = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
        let groups = AddressFormatter.groups(evm)
        #expect(groups.first == "0x9858")
        #expect(groups.joined() == evm)
        #expect(AddressFormatter.groups("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu").joined() == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        #expect(AddressFormatter.short(evm) == "0x9858Ef…da94")
        #expect(AddressFormatter.looksLikeAddress(evm))
        #expect(!AddressFormatter.looksLikeAddress("Personal signature (EIP-191)"))
    }

    @Test func reviewDecodesEngineDisplayAndNetwork() {
        let review = TransactionReview([
            "chain": "evm", "title": "Native transfer", "summary": "1 ETH", "requestHash": String(repeating: "a", count: 64),
            "fields": [["label": "Network", "value": "Base"]], "warnings": [], "decodeStatus": "fullyDecoded", "riskLevel": "normal",
            "network": ["chainId": "8453", "name": "Base", "symbol": "ETH"],
            "display": ["action": "Send", "amount": "1", "symbol": "ETH", "counterpartyLabel": "To", "counterparty": "0x0000000000000000000000000000000000000001", "fee": "0.0001 ETH"],
        ])
        #expect(review.network?.brand == .base)
        #expect(review.display?.fee == "0.0001 ETH")
        #expect(!review.requiresAcknowledgement)
        let risky = TransactionReview(["chain": "evm", "decodeStatus": "partiallyDecoded", "riskLevel": "warning", "requestHash": ""])
        #expect(risky.requiresAcknowledgement)
        let unknown = TransactionReview(["chain": "evm", "requestHash": ""])
        #expect(unknown.decodeStatus == .opaque && unknown.requiresAcknowledgement)
    }
}

private final class HardeningFixtureBundle: NSObject {}
