import Foundation
import Testing
@testable import BitToolSigner

/// Multi-language BIP39 import, including phrases scanned from a QR code. Vectors come from the
/// @scure/bip39 reference implementation and the official Japanese vectors
/// (bip32JP); all are public, unfunded test phrases.
struct BIP39LanguageTests {
    private struct Vector: Decodable {
        let language: String, entropy: String, mnemonic: String, passphrase: String, seed: String
        let source: String?
    }
    private struct Invalid: Decodable { let language: String, mnemonic: String }
    private struct Fixture: Decodable { let vectors: [Vector], invalid: [Invalid] }

    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for: LanguageFixtureBundle.self).url(forResource: "BIP39LanguageVectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    // MARK: Wordlists

    @Test func allTenOfficialWordlistsLoadWithTheirPinnedHashes() {
        for language in BIP39Language.allCases {
            let list = BIP39.wordlist(language)
            #expect(list.isAvailable, "\(language.rawValue) must load and match its pinned SHA-256")
        }
        #expect(BIP39.wordlist(.english).words.first == "abandon")
        #expect(BIP39.wordlist(.japanese).words.first == "あいこくしん")
        #expect(BIP39.wordlist(.korean).words.first == "가격")
        #expect(BIP39.wordlist(.spanish).words.first == "ábaco")
        #expect(BIP39.wordlist(.chineseSimplified).words.first == "的")
        #expect(BIP39.wordlist(.chineseTraditional).words.last == "歇")
    }

    // MARK: Validation and seeds

    @Test func referenceVectorsCanonicalizeAndDeriveTheExpectedSeed() throws {
        let fixture = try fixture()
        #expect(fixture.vectors.count >= 44)
        for vector in fixture.vectors {
            let canonical = try BIP39Mnemonic.canonicalize(vector.mnemonic)
            // Simplified and Traditional Chinese share many characters; the seed
            // depends only on the words, so either detection is correct.
            if vector.language.hasPrefix("chinese") {
                #expect(canonical.language.isChinese)
            } else {
                #expect(canonical.language.rawValue == vector.language)
            }
            #expect(try BIP39Seed.hex(mnemonic: canonical.phrase, passphrase: vector.passphrase) == vector.seed,
                    "\(vector.language) \(vector.entropy)")
        }
        #expect(fixture.vectors.contains { $0.source == "bip32JP" })
    }

    @Test func inputIsForgivingButTheSeedUsesTheCanonicalWords() throws {
        for vector in try fixture().vectors {
            let canonical = try BIP39Mnemonic.canonicalize(vector.mnemonic)
            let nfc = vector.mnemonic.precomposedStringWithCanonicalMapping
            // Japanese backups use ideographic spaces; NFC input from a keyboard.
            #expect(try BIP39Mnemonic.canonicalize(nfc.replacingOccurrences(of: "\u{3000}", with: " ")) == canonical)
            // Latin scripts: no accents, capital letters, commas and numbering.
            if BIP39Language(rawValue: vector.language)?.matchesWithoutAccents == true {
                let plain = String(String.UnicodeScalarView(
                    vector.mnemonic.decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }))
                #expect(try BIP39Mnemonic.canonicalize(plain.uppercased()) == canonical)
                let numbered = plain.split(separator: " ").enumerated().map { "\($0.offset + 1). \($0.element)," }.joined(separator: " ")
                #expect(try BIP39Mnemonic.canonicalize(numbered) == canonical)
            }
            // Chinese typed without spaces.
            if vector.language.hasPrefix("chinese") {
                #expect(try BIP39Mnemonic.canonicalize(vector.mnemonic.replacingOccurrences(of: " ", with: "")) == canonical)
            }
            // The stored phrase is NFC words joined by single spaces.
            #expect(canonical.phrase == canonical.phrase.precomposedStringWithCanonicalMapping)
            #expect(canonical.words.count == vector.mnemonic.split { $0.isWhitespace }.count)
        }
    }

    @Test func checksumLengthAndUnknownWordsFailClosed() throws {
        for invalid in try fixture().invalid {
            #expect(throws: BIP39Mnemonic.ValidationError.checksum) { try BIP39Mnemonic.canonicalize(invalid.mnemonic) }
        }
        #expect(throws: BIP39Mnemonic.ValidationError.empty) { try BIP39Mnemonic.canonicalize("  \n ") }
        #expect(throws: BIP39Mnemonic.ValidationError.unsupportedLength(3)) {
            try BIP39Mnemonic.canonicalize("abandon abandon abandon")
        }
        let unknown = Array(repeating: "abandon", count: 11) + ["xyzzy"]
        #expect(throws: BIP39Mnemonic.ValidationError.unknownWords(["xyzzy"])) {
            try BIP39Mnemonic.canonicalize(unknown.joined(separator: " "))
        }
        // Mixing languages never validates, even when every word exists somewhere.
        let mixed = Array(repeating: "abandon", count: 11) + ["ábaco"]
        #expect(throws: (any Error).self) { try BIP39Mnemonic.canonicalize(mixed.joined(separator: " ")) }
    }

    @Test func phrasesValidInTwoLanguagesAskInsteadOfGuessing() throws {
        // Valid Italian, and valid Spanish once accents are added: two different wallets.
        let italian = "nomina solido comodo nucleo pagina armonia nucleo liquido pagina logica nucleo nucleo"
        let spanish = "nómina sólido cómodo núcleo página armonía núcleo líquido página lógica núcleo núcleo"
        let readings = try BIP39Mnemonic.interpretations(italian)
        #expect(readings.map(\.language) == [.italian, .spanish])
        #expect(throws: BIP39Mnemonic.ValidationError.ambiguous(readings)) { try BIP39Mnemonic.canonicalize(italian) }
        #expect(try BIP39Seed.hex(mnemonic: readings[0].phrase, passphrase: "")
                == "ff24afd428aa5040062bdaa2f41b8397b21ac04fef76fff7bc27e6ecf0ba349243005a33f5e1486d9e0ea54fafbba9ae4dc1c54779ab2f3ed1963f872b0e4a78")
        #expect(try BIP39Seed.hex(mnemonic: readings[1].phrase, passphrase: "")
                == "dc1bb7e8db68b6484ac3fe00d0f356a10f4e33deb6efed27cbff7df2daedded3e8d05053605876bdb87bdd8373d35e4cf6ada4a2a114d08d69b3597a5e2b01d0")
        // Typed accents are deliberate; stored phrases are never reinterpreted.
        #expect(try BIP39Mnemonic.canonicalize(spanish).language == .spanish)
        #expect(try BIP39Mnemonic.validatedCanonical(readings[0].phrase).language == .italian)
        #expect(try BIP39Mnemonic.validatedCanonical(readings[1].phrase).language == .spanish)
    }

    @MainActor
    @Test func scannedPhrasesKeepTheirExactLanguageWithoutAsking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(vault: WalletVault(directory: directory.appendingPathComponent("Vaults"), deviceKeys: LanguageTestKeys()),
                             storageDirectory: directory)
        let italian = try #require(try BIP39Mnemonic.interpretations(
            "nomina solido comodo nucleo pagina armonia nucleo liquido pagina logica nucleo nucleo").first)
        #expect(italian.language == .italian)

        // A QR code (such as BitTool Signer's recovery phrase QR) carries the exact words.
        let scanned = WalletSetupModel(intent: .restore, existingWallets: 0)
        scanned.applyScanned(phrase: italian.phrase)
        #expect(scanned.phraseInput == italian.phrase)
        scanned.startImport(store: store)
        #expect(scanned.languageChoices.isEmpty)
        #expect(scanned.importedLanguage == .italian)
        #expect(scanned.path == [.password])

        // Editing the scanned words drops that shortcut.
        let edited = WalletSetupModel(intent: .restore, existingWallets: 0)
        edited.applyScanned(phrase: italian.phrase)
        edited.phraseInput = italian.phrase + " "
        edited.startImport(store: store)
        #expect(edited.languageChoices.map(\.language) == [.italian, .spanish])

        // The same unaccented words typed by hand are ambiguous, so the person chooses.
        let typed = WalletSetupModel(intent: .restore, existingWallets: 0)
        typed.phraseInput = italian.phrase
        typed.startImport(store: store)
        #expect(typed.languageChoices.map(\.language) == [.italian, .spanish])
        #expect(typed.path.isEmpty)
    }

    /// BTS-04 (audit BTS-SEC-2026-1017): seed derivation rejected valid long
    /// Japanese and Korean backups because its byte limit was below what those
    /// wordlists can produce. A phrase is bounded by its word count and its
    /// checksum, not by how many bytes the words happen to take.
    @Test func everyValidPhraseLengthDerivesASeedInEveryWordlist() throws {
        for language in BIP39Language.allCases {
            let words = BIP39.wordlist(language).words
            #expect(words.count == 2048, "\(language.rawValue)")
            // The worst case this wordlist can produce: its longest word, 24 times.
            let longest = try #require(words.max { $0.utf8.count < $1.utf8.count })
            for count in [12, 15, 18, 21, 24] {
                let phrase = Array(repeating: longest, count: count).joined(separator: " ")
                let seed = try BIP39Seed.hex(mnemonic: phrase, passphrase: "")
                #expect(seed.count == 128, "\(language.rawValue) \(count) words")
            }
            let worst = Array(repeating: longest, count: 24).joined(separator: " ")
                .decomposedStringWithCompatibilityMapping.utf8.count
            #expect(worst <= BIP39Seed.maximumPhraseBytes,
                    "\(language.rawValue) worst case is \(worst) bytes, limit is \(BIP39Seed.maximumPhraseBytes)")
        }
    }

    /// The limit still exists: it bounds input, it just no longer cuts below
    /// what a real backup can be.
    @Test func thePhraseLimitStillRejectsUnboundedInput() {
        let tooLong = String(repeating: "a", count: BIP39Seed.maximumPhraseBytes + 1)
        #expect(throws: VaultError.invalidSecret) { try BIP39Seed.hex(mnemonic: tooLong, passphrase: "") }
        #expect(throws: VaultError.invalidSecret) { try BIP39Seed.hex(mnemonic: "", passphrase: "") }
        #expect(throws: VaultError.invalidSecret) {
            try BIP39Seed.hex(mnemonic: "abandon", passphrase: String(repeating: "p", count: 1025))
        }
    }

    @Test func draftDetectsTheLanguageAndSuggestsCanonicalWords() {
        let spanish = RecoveryPhraseDraft("abaco abdomen abe")
        #expect(spanish.language == .spanish)
        #expect(spanish.unknownWords.isEmpty)
        #expect(spanish.partialWord == "abe")
        #expect(BIP39.wordlist(.spanish).suggestions(for: "abaco") == ["ábaco"])

        let japanese = RecoveryPhraseDraft("あいこくしん　あいこ")
        #expect(japanese.language == .japanese)
        #expect(japanese.words == ["あいこくしん", "あいこ"])
        #expect(japanese.trailingWordIncomplete)

        let chinese = RecoveryPhraseDraft("的一是在")
        #expect(chinese.language?.isChinese == true)
        #expect(chinese.words.count == 4)

        let english = RecoveryPhraseDraft("abandon abandon ab")
        #expect(english.language == .english)
        #expect(english.unknownWords.isEmpty)

        let unknown = RecoveryPhraseDraft("abandon xyzzy ")
        #expect(unknown.unknownWords == ["xyzzy"])
    }
}

private final class LanguageFixtureBundle: NSObject {}

private final class LanguageTestKeys: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    func create(id: UUID, key: Data) throws { lock.lock(); defer { lock.unlock() }; keys[id] = key }
    func read(id: UUID) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[id] else { throw VaultError.deviceKeyUnavailable }
        return key
    }
    func delete(id: UUID) throws { lock.lock(); defer { lock.unlock() }; keys[id] = nil }
}
