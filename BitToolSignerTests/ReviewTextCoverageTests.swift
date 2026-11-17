import Foundation
import Testing
@testable import BitToolSigner

/// Every piece of engine text the review screen can draw reaches a person in
/// their language — measured on what the engine actually produces, not on its
/// source code.
///
/// `engine/test/fixtures/review-text-corpus.json` is recorded by running the
/// engine's whole test suite (`node test/support/review-text-corpus.mjs` in
/// `engine/`) and keeping every warning, refusal, title, action, headline, label
/// and unit word its reviews contain. This test draws each one through the real
/// `ReviewText`, in every language the app ships, and fails on any that would
/// fall back to English. A source scan missed warnings held in constants, built
/// by helpers, or numbered "Order 2:" — this cannot.
struct ReviewTextCoverageTests {
    private static let corpus: [String: [String]] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/test/fixtures/review-text-corpus.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return decoded
    }()

    /// How each kind of text is drawn, as `RequestReviewView`, `ActivityTab` and
    /// `SignatureResultView` draw it.
    private static let kinds: [(name: String, as: ReviewText.Kind)] = [
        ("warning", .sentence), ("refusal", .sentence), ("note", .sentence),
        ("title", .phrase), ("action", .phrase), ("counterpartyLabel", .phrase),
        ("amountWord", .phrase), ("symbol", .phrase), ("networkPhrase", .phrase),
        ("label", .label), ("assetContractLabel", .label), ("headline", .headline),
    ]

    /// Headlines that are values with no words in them: NFT IDs, amounts, call and
    /// order lists the engine assembles from the request. They are drawn as the
    /// engine wrote them, in every language.
    private static let valueHeadlines = [
        "^[0-9]", "^NFT #", "^For (ANY|NFT)", "^Destroys [0-9.]+ (tokens?|NFT|raw units?)\\b", "^Give [0-9]",
        "^Listings root ", "^Merkle root ",
    ]

    private static var languages: [String] {
        Bundle.main.paths(forResourcesOfType: "lproj", inDirectory: nil)
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .filter { $0 != "en" && $0 != "Base" }.sorted()
    }

    @Test func theCorpusIsThere() {
        // Guard the guard: an empty or unreadable corpus would make the test below pass.
        #expect((Self.corpus["warning"]?.count ?? 0) > 200, "review-text-corpus.json is missing or too small")
        #expect((Self.corpus["label"]?.count ?? 0) > 500)
        #expect(Self.languages.count == 20, "expected 20 translated languages, found \(Self.languages)")
    }

    @Test(arguments: languages)
    func everyEngineTextIsTranslated(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language): no .lproj")
        let bundle = try #require(Bundle(path: path))
        let marker = "\u{0}missing\u{0}"
        let translate: ReviewText.Lookup = { key in
            let value = bundle.localizedString(forKey: key, value: marker, table: nil)
            return value == marker ? nil : value
        }
        var english: [String] = []
        for (name, kind) in Self.kinds {
            for text in Self.corpus[name] ?? [] {
                if name == "headline", Self.valueHeadlines.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { continue }
                let shown = ReviewText.render(text, as: kind, translate: translate)
                #expect(!shown.text.contains("%@") && !shown.text.contains("$@"), "\(language): a placeholder reached the screen: \(shown.text)")
                if !shown.complete { english.append("[\(name)] \(text.prefix(100))") }
            }
        }
        #expect(english.isEmpty, "\(language): \(english.count) engine texts would appear in English, first: \(english.prefix(8).joined(separator: " | "))")
    }

    @Test func numberedPartsAreTranslatedAroundTheirNumbers() throws {
        // Spot checks with a table that marks what it translated, so the shape of
        // the result is visible: a numbered prefix, a label split at " · ", a unit
        // kept as the engine wrote it, and a severity marker kept with its sentence.
        let table: [String: String] = [
            "Order %@": "«Order %@»", "Call %@": "«Call %@»", "Instruction %@": "«Instruction %@»",
            "Amount": "«Amount»", "Also paid": "«Also paid»", "Item %@": "«Item %@»",
            "HIGH RISK: You receive nothing for the items you give.": "«HIGH RISK: nothing»",
            "UNLIMITED spending approval.": "«UNLIMITED.»",
        ]
        let translate: ReviewText.Lookup = { table[$0] }
        #expect(ReviewText.render("HIGH RISK: Order 2: You receive nothing for the items you give.", as: .sentence, translate: translate)
                == .init(text: "«Order 2»: «HIGH RISK: nothing»", complete: true))
        #expect(ReviewText.render("UNLIMITED spending approval (Call 3).", as: .sentence, translate: translate)
                == .init(text: "«UNLIMITED.» («Call 3»)", complete: true))
        #expect(ReviewText.render("Instruction 4 · Amount (USDC)", as: .label, translate: translate)
                == .init(text: "«Instruction 4» · «Amount» (USDC)", complete: true))
        #expect(ReviewText.render("Order 3 · Also paid · Item 2", as: .label, translate: translate)
                == .init(text: "«Order 3» · «Also paid» · «Item 2»", complete: true))
        // A numbered sentence that does not translate in full is drawn exactly as the
        // engine wrote it — never reassembled with its marker moved, which is what
        // English (an empty table) would otherwise get.
        let original = "HIGH RISK: Order 2: Unknown token contract: amounts are shown in raw units; token metadata is unavailable offline."
        #expect(ReviewText.render(original, as: .sentence, translate: { _ in nil }) == .english(original))
        #expect(ReviewText.render(original, as: .sentence, translate: translate) == .english(original), "label translates, sentence does not")
        #expect(ReviewText.render("UNLIMITED spending approval (Call 3).", as: .sentence, translate: { _ in nil })
                == .english("UNLIMITED spending approval (Call 3)."))
        // Anything the table lacks is drawn in English and reported as such.
        #expect(ReviewText.render("Order 3 · Zone hash", as: .label, translate: translate).complete == false)
        #expect(ReviewText.render("Instruction 4 · Amount (stored, not enforced)", as: .label, translate: translate).complete == false)
    }

    @Test func aMessageIsNeverShownTranslated() {
        // The words of a message are what gets signed; one that happens to equal a
        // catalogue entry must still be drawn exactly as it is.
        #expect(ReviewText.headlineIsTheirs(action: "Sign Message"))
        #expect(ReviewText.headlineIsTheirs(action: "Sign Typed Data"))
        #expect(!ReviewText.headlineIsTheirs(action: "Send"))
    }
}
