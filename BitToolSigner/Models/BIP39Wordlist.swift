import Foundation
import CryptoKit
import Darwin

/// The ten official BIP39 wordlists, bundled byte-for-byte from bitcoin/bips
/// (bip-0039/*.txt) and pinned by SHA-256.
enum BIP39Language: String, CaseIterable, Identifiable, Sendable {
    case english
    case chineseSimplified = "chinese_simplified"
    case chineseTraditional = "chinese_traditional"
    case japanese, korean, spanish, french, italian, czech, portuguese

    var id: String { rawValue }

    /// The language's own name, as people recognise it on their written backup.
    var displayName: String {
        switch self {
        case .english: "English"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .czech: "Čeština"
        case .portuguese: "Português"
        }
    }

    /// SHA-256 of the official file.
    var expectedSHA256: String {
        switch self {
        case .english: "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"
        case .chineseSimplified: "5c5942792bd8340cb8b27cd592f1015edf56a8c5b26276ee18a482428e7c5726"
        case .chineseTraditional: "417b26b3d8500a4ae3d59717d7011952db6fc2fb84b807f3f94ac734e89c1b5f"
        case .japanese: "2eed0aef492291e061633d7ad8117f1a2b03eb80a29d0e4e3117ac2528d05ffd"
        case .korean: "9e95f86c167de88f450f0aaf89e87f6624a57f973c67b516e338e8e8b8897f60"
        case .spanish: "46846a5a0139d1e3cb77293e521c2865f7bcdb82c44e8d0a06a2cd0ecba48c0b"
        case .french: "ebc3959ab7801a1df6bac4fa7d970652f1df76b683cd2f4003c941c63d517e59"
        case .italian: "d392c49fdb700a24cd1fceb237c1f65dcc128f6b34a8aacb58b59384b5c648c2"
        case .czech: "7e80e161c3e93d9554c2efb78d4e3cebf8fc727e9c52e03b83b94406bdcc95fc"
        case .portuguese: "2685e9c194c82ae67e10ba59d9ea5345a23dc093e92276fc5361f6667d79cd3f"
        }
    }

    /// Latin-script lists are unique without accents, and BIP39 lets people
    /// type them without accents. The canonical (accented) word is what counts
    /// for the seed, so input is mapped back to it.
    var matchesWithoutAccents: Bool {
        switch self {
        case .english, .spanish, .french, .italian, .czech, .portuguese: true
        default: false
        }
    }

    /// Every Chinese BIP39 word is exactly one character.
    var isChinese: Bool { self == .chineseSimplified || self == .chineseTraditional }
}

/// One official BIP39 wordlist with accent- and normalization-insensitive lookup.
final class BIP39Wordlist: Sendable {
    static var shared: BIP39Wordlist { BIP39.wordlist(.english) }

    let language: BIP39Language
    /// Words in index order, NFC for display. The official files are NFKD;
    /// the seed is computed from NFKD either way.
    let words: [String]
    private let keys: [String]
    /// NFKD, lowercase: the word exactly as listed.
    private let exactLookup: [String: Int]
    /// Also without accents for Latin-script lists.
    private let lookup: [String: Int]

    convenience init(bundle: Bundle) { self.init(language: .english, bundle: bundle) }

    init(language: BIP39Language, bundle: Bundle = .main) {
        self.language = language
        guard let url = bundle.url(forResource: "bip39-" + language.rawValue, withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == language.expectedSHA256,
              let text = String(data: data, encoding: .utf8) else {
            words = []; keys = []; exactLookup = [:]; lookup = [:]; return
        }
        let list = text.split(separator: "\n").map(String.init)
        let keys = list.map { Self.key($0, language: language) }
        let lookup = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let exactLookup = Dictionary(list.enumerated().map { (Self.exactKey($1), $0) }, uniquingKeysWith: { first, _ in first })
        guard list.count == 2048, lookup.count == 2048, exactLookup.count == 2048 else {
            words = []; self.keys = []; self.exactLookup = [:]; self.lookup = [:]; return
        }
        words = list.map(\.precomposedStringWithCanonicalMapping)
        self.keys = keys
        self.exactLookup = exactLookup
        self.lookup = lookup
    }

    var isAvailable: Bool { words.count == 2048 }

    static func exactKey(_ text: String) -> String { text.decomposedStringWithCompatibilityMapping.lowercased() }

    /// Lookup form: NFKD, lowercase, and without accents for Latin-script lists.
    static func key(_ text: String, language: BIP39Language) -> String {
        let decomposed = text.decomposedStringWithCompatibilityMapping.lowercased()
        guard language.matchesWithoutAccents else { return decomposed }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: decomposed.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark })
        return String(scalars)
    }

    /// `exact` requires the listed spelling (accents included); otherwise
    /// Latin-script words also match without accents.
    func index(of token: String, exact: Bool = false) -> Int? {
        exact ? exactLookup[Self.exactKey(token)] : lookup[Self.key(token, language: language)]
    }
    func contains(_ token: String, exact: Bool = false) -> Bool { index(of: token, exact: exact) != nil }

    /// Canonical words that begin with `prefix`, in dictionary order.
    func suggestions(for prefix: String, limit: Int = 6) -> [String] {
        let key = Self.key(prefix, language: language)
        guard !key.isEmpty, isAvailable else { return [] }
        var result: [String] = []
        for (offset, candidate) in keys.enumerated() where candidate.hasPrefix(key) {
            result.append(words[offset])
            if result.count == limit { break }
        }
        return result
    }

    func isPrefix(_ token: String) -> Bool { !suggestions(for: token, limit: 1).isEmpty }

    /// Decodes a Standard SeedQR (four decimal digits per word index). SeedQR
    /// is defined for the English list only.
    func words(fromSeedQR text: String) -> [String]? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language == .english, isAvailable, [48, 60, 72, 84, 96].contains(digits.count),
              digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        var result: [String] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 4)
            guard let value = Int(digits[index..<next]), value < 2048 else { return nil }
            result.append(words[value])
            index = next
        }
        return result
    }
}

/// Lazily loaded, shared wordlists.
enum BIP39 {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var lists: [BIP39Language: BIP39Wordlist] = [:]
        func get(_ language: BIP39Language) -> BIP39Wordlist {
            lock.lock(); defer { lock.unlock() }
            if let list = lists[language] { return list }
            let list = BIP39Wordlist(language: language)
            lists[language] = list
            return list
        }
    }
    private static let cache = Cache()

    static func wordlist(_ language: BIP39Language) -> BIP39Wordlist { cache.get(language) }

    static let supportedLengths: Set<Int> = [12, 15, 18, 21, 24]
}

/// Validation and canonical form of a recovery phrase in any BIP39 language.
enum BIP39Mnemonic {
    struct Canonical: Equatable, Sendable {
        /// Canonical words (NFC) joined by single spaces. Stored in the vault.
        let phrase: String
        let language: BIP39Language
        var words: [String] { phrase.split(separator: " ").map(String.init) }
    }

    enum ValidationError: LocalizedError, Equatable {
        case empty
        case unsupportedLength(Int)
        case unknownWords([String])
        case checksum
        /// Valid in more than one language once accents are ignored; the person chooses.
        case ambiguous([Canonical])

        var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "Enter your recovery phrase.", bundle: AppText.bundle)
            case .unsupportedLength(let count):
                // Singular and plural are separate sentences: a language that
                // counts differently cannot be served by splicing in a word.
                return count == 1
                    ? String(localized: "Invalid recovery phrase: it has 1 word. Recovery phrases have 12, 15, 18, 21 or 24 words.", bundle: AppText.bundle)
                    : String(localized: "Invalid recovery phrase: it has \(count) words. Recovery phrases have 12, 15, 18, 21 or 24 words.", bundle: AppText.bundle)
            case .unknownWords(let words):
                let list = words.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
                return words.count == 1
                    ? String(localized: "Invalid recovery phrase: \(list) is not in the BIP39 word list.", bundle: AppText.bundle)
                    : String(localized: "Invalid recovery phrase: \(list) are not in the BIP39 word list.", bundle: AppText.bundle)
            case .checksum:
                return String(localized: "Invalid recovery phrase. Check the words and their order.", bundle: AppText.bundle)
            case .ambiguous:
                return String(localized: "These words are a valid recovery phrase in more than one language. Choose the language of your written backup.", bundle: AppText.bundle)
            }
        }
    }

    /// Splits typed or pasted text into words. Separators are any whitespace
    /// (including the ideographic space used in Japanese backups) and commas.
    /// Pure numbering such as "1." is ignored, and Chinese typed without spaces
    /// is split into its single-character words.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        let pieces = text.split { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == "、" }
        for piece in pieces {
            // "1." or "１)" numbering. Only ASCII digits (after width folding):
            // Chinese numerals such as 一 and 十 are real BIP39 words.
            if String(piece).decomposedStringWithCompatibilityMapping
                .allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." || $0 == ")" }) { continue }
            let token = String(piece)
            if token.count > 1, token.unicodeScalars.allSatisfy(isHan) {
                result.append(contentsOf: token.map(String.init))
            } else {
                result.append(token)
            }
        }
        return result
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    /// Languages to try, most common first. English is checked on its own
    /// first, so the usual case never loads the other nine lists.
    static let detectionOrder: [BIP39Language] = [.english, .chineseSimplified, .chineseTraditional, .japanese, .korean,
                                                  .spanish, .french, .italian, .czech, .portuguese]

    /// The one reading of typed or pasted words, or `.ambiguous` when several
    /// languages fit (see `interpretations`).
    static func canonicalize(_ text: String) throws -> Canonical {
        let options = try interpretations(text)
        guard options.count == 1, let only = options.first else { throw ValidationError.ambiguous(options) }
        return only
    }

    /// Every valid reading of typed or pasted words, exact spellings first.
    ///
    /// Words spelled exactly as listed are the same string in any list that has
    /// them, so they give the same seed. Latin-script words typed without
    /// accents are also matched without accents, as BIP39 allows; that can make
    /// a phrase valid in two languages with different seeds (an unaccented
    /// "nomina solido comodo …" is Italian, or Spanish "nómina sólido cómodo …").
    /// Then every reading is returned so the person can choose. Typed accents
    /// are taken as deliberate and never matched away.
    static func interpretations(_ text: String) throws -> [Canonical] {
        let tokens = tokens(text)
        guard !tokens.isEmpty else { throw ValidationError.empty }
        guard BIP39.supportedLengths.contains(tokens.count) else { throw ValidationError.unsupportedLength(tokens.count) }
        let exact = readings(of: tokens, exact: true)
        var results = exact.valid
        if results.isEmpty || !hasTypedAccents(tokens) {
            for reading in readings(of: tokens, exact: false).valid where !results.contains(reading) {
                results.append(reading)
            }
        }
        if !results.isEmpty { return results }
        if exact.anyMapped || readings(of: tokens, exact: false).anyMapped { throw ValidationError.checksum }
        let best = detectionOrder.max { a, b in
            tokens.filter { BIP39.wordlist(a).contains($0) }.count < tokens.filter { BIP39.wordlist(b).contains($0) }.count
        } ?? .english
        throw ValidationError.unknownWords(tokens.filter { !BIP39.wordlist(best).contains($0) })
    }

    /// For phrases BitTool Signer produced or stored: exact spellings only, so the
    /// stored canonical form is never reinterpreted.
    static func validatedCanonical(_ phrase: String) throws -> Canonical {
        let tokens = tokens(phrase)
        guard BIP39.supportedLengths.contains(tokens.count) else { throw ValidationError.unsupportedLength(tokens.count) }
        guard let reading = readings(of: tokens, exact: true).valid.first else { throw ValidationError.checksum }
        return reading
    }

    private static func readings(of tokens: [String], exact: Bool) -> (valid: [Canonical], anyMapped: Bool) {
        var valid: [Canonical] = [], anyMapped = false
        for language in detectionOrder where exact || language.matchesWithoutAccents {
            let list = BIP39.wordlist(language)
            guard list.isAvailable else { continue }
            let resolved = tokens.compactMap { list.index(of: $0, exact: exact) }
            guard resolved.count == tokens.count else { continue }
            anyMapped = true
            guard checksumIsValid(resolved) else { continue }
            let reading = Canonical(phrase: resolved.map { list.words[$0] }.joined(separator: " "), language: language)
            if !valid.contains(where: { $0.phrase == reading.phrase }) { valid.append(reading) }
        }
        return (valid, anyMapped)
    }

    private static func hasTypedAccents(_ tokens: [String]) -> Bool {
        tokens.contains { token in
            token.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value < 0x0250 }
                && token.decomposedStringWithCanonicalMapping.unicodeScalars.contains { $0.properties.generalCategory == .nonspacingMark }
        }
    }

    /// Checks the BIP39 checksum of 11-bit word indices.
    static func checksumIsValid(_ indices: [Int]) -> Bool {
        let count = indices.count
        guard BIP39.supportedLengths.contains(count), indices.allSatisfy({ (0..<2048).contains($0) }) else { return false }
        var bits = [Bool](); bits.reserveCapacity(count * 11)
        for index in indices { for shift in stride(from: 10, through: 0, by: -1) { bits.append((index >> shift) & 1 == 1) } }
        let checksumBits = count / 3, entropyBits = bits.count - checksumBits
        var entropy = [UInt8](repeating: 0, count: entropyBits / 8)
        defer {
            entropy.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } }
            for i in bits.indices { bits[i] = false }
        }
        for i in 0..<entropyBits where bits[i] { entropy[i / 8] |= 0x80 >> UInt8(i % 8) }
        let hash = Array(SHA256.hash(data: entropy))
        for i in 0..<checksumBits where ((hash[i / 8] & (0x80 >> UInt8(i % 8))) != 0) != bits[entropyBits + i] {
            return false
        }
        return true
    }
}

/// Word-by-word analysis of a recovery phrase while it is being typed.
struct RecoveryPhraseDraft {
    let words: [String]
    /// The detected language, or the closest match while words are unknown.
    let language: BIP39Language?
    let unknownWords: [String]
    /// The partially typed trailing word, if the cursor is still inside it.
    let partialWord: String?
    /// True while the trailing word is still being typed and is not yet a dictionary word.
    let trailingWordIncomplete: Bool

    init(_ text: String) {
        let tokens = BIP39Mnemonic.tokens(text)
        words = tokens
        let endsInWord = text.last.map { !$0.isWhitespace && $0 != "," && $0 != "，" && $0 != "、" } ?? false
        let partial = endsInWord ? tokens.last : nil
        partialWord = partial
        guard !tokens.isEmpty else {
            language = nil; unknownWords = []; trailingWordIncomplete = false; return
        }
        // A token is acceptable when it is a word, or the trailing word being typed is a valid prefix.
        func unknown(in list: BIP39Wordlist) -> [String] {
            tokens.enumerated().filter { offset, token in
                if list.contains(token) { return false }
                return !(offset == tokens.count - 1 && endsInWord && list.isPrefix(token))
            }.map(\.element)
        }
        var chosen: (list: BIP39Wordlist, missing: [String])?
        // Prefer a language whose listed spellings match exactly (see canonicalize).
        for language in BIP39Mnemonic.detectionOrder {
            let list = BIP39.wordlist(language)
            guard list.isAvailable else { continue }
            let exactMissing = tokens.enumerated().filter { offset, token in
                !list.contains(token, exact: true) && !(offset == tokens.count - 1 && endsInWord && list.isPrefix(token))
            }
            if exactMissing.isEmpty { chosen = (list, []); break }
        }
        if chosen == nil {
            for language in BIP39Mnemonic.detectionOrder {
                let list = BIP39.wordlist(language)
                guard list.isAvailable else { continue }
                let missing = unknown(in: list)
                if missing.isEmpty { chosen = (list, []); break }
                if chosen.map({ missing.count < $0.missing.count }) ?? true { chosen = (list, missing) }
            }
        }
        guard let chosen else {
            language = nil; unknownWords = tokens; trailingWordIncomplete = false; return
        }
        language = chosen.missing.count < tokens.count ? chosen.list.language : nil
        unknownWords = chosen.missing
        trailingWordIncomplete = partial.map { !chosen.list.contains($0) } ?? false
    }

    var hasSupportedLength: Bool { BIP39.supportedLengths.contains(words.count) }
    /// Every word is in the detected dictionary and the length is supported.
    /// The checksum is verified when the phrase is submitted.
    var looksComplete: Bool { hasSupportedLength && unknownWords.isEmpty && !trailingWordIncomplete }
}
