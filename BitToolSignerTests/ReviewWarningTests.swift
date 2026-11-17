import Foundation
import Testing
@testable import BitToolSigner

/// Translating the warnings the offline engine writes. The engine emits English
/// — that text is what the request fingerprint covers — so the interface
/// translates at the last moment, and has to put the engine's own values back
/// into a sentence written in another language.
struct ReviewWarningTests {

    @Test func aWarningWithNoTranslationKeepsTheEnginesOwnWords() {
        // A warning added to the engine and not yet translated must still be
        // readable, not blank.
        let invented = "HIGH RISK: A warning no translation table has ever seen."
        #expect(ReviewText.sentence(invented) == invented)
    }

    @Test func aTemplateFindsTheValuesTheEngineFilledIn() {
        let template = ReviewText.Template("HIGH FEE: This transaction allows up to %@ in network fees. Check the gas settings in your other wallet.")
        #expect(template.match("HIGH FEE: This transaction allows up to 0.08 ETH in network fees. Check the gas settings in your other wallet.") == ["0.08 ETH"])
        // A different warning is not this one, however similar.
        #expect(template.match("HIGH FEE: This transaction allows up to 1 SOL in priority fees. Check the fee settings in your other wallet.") == nil)
        #expect(template.match("") == nil)
    }

    @Test func severalValuesComeBackInOrder() {
        let template = ReviewText.Template("HIGH RISK: %@ hands the account %@ to the contract at %@. That contract’s code then runs as that account and can move everything in it.")
        let values = template.match("HIGH RISK: Authorization 2 hands the account 0xAAA to the contract at 0xBBB. That contract’s code then runs as that account and can move everything in it.")
        #expect(values == ["Authorization 2", "0xAAA", "0xBBB"])
    }

    @Test func aValueThatLooksLikeAPatternIsStillJustAValue() {
        // Regular-expression characters in an address or an amount must not
        // change what the template matches.
        let template = ReviewText.Template("This call also sends %@ to the contract.")
        #expect(template.match("This call also sends 1.5 (ETH) [*] to the contract.") == ["1.5 (ETH) [*]"])
    }

    @Test func everyRegisteredTemplateMatchesItsOwnSentence() {
        // Each template is both the translation key and the pattern, so a
        // template that cannot match its own text would silently never fire.
        for template in ReviewText.registeredTemplates {
            let filled = template.english.replacingOccurrences(of: "%@", with: "VALUE")
            let values = template.match(filled)
            #expect(values != nil, "no self-match: \(template.english.prefix(60))")
            #expect(values?.allSatisfy { $0 == "VALUE" } == true, "wrong capture: \(template.english.prefix(60))")
        }
    }

    @Test func noTwoTemplatesClaimTheSameSentence() {
        // Two templates that both match one warning would make the translation
        // depend on declaration order.
        for template in ReviewText.registeredTemplates {
            let filled = template.english.replacingOccurrences(of: "%@", with: "VALUE")
            let matching = ReviewText.registeredTemplates.filter { $0.match(filled) != nil }
            #expect(matching.count == 1, "\(matching.count) templates match: \(template.english.prefix(60))")
        }
    }

    @Test func aTranslationThatReordersTheValuesStillGetsThemRight() {
        // Several languages say "this instruction's TOTAL accounts, COUNT of which",
        // reversing the engine's order, so their translations number the
        // placeholders. The numbering has to survive substitution.
        let english = "%@ of this instruction’s %@ accounts come from an address lookup table and cannot be shown."
        let reordered = "this instruction’s %2$@ accounts, %1$@ of which, come from a lookup table."
        #expect(ReviewText.substitute(reordered, ["2", "7"]) == "this instruction’s 7 accounts, 2 of which, come from a lookup table.")
        #expect(ReviewText.substitute(english, ["2", "7"]) == "2 of this instruction’s 7 accounts come from an address lookup table and cannot be shown.")
        // A translation whose placeholder count disagrees is refused outright.
        #expect(ReviewText.substitute("only one %@ here", ["2", "7"]) == nil)
    }

    @Test func aTranslationThatDoesNotFitFallsBackToTheEnginesEnglish() {
        // A hand-edited .strings file with the wrong number of placeholders must
        // not put "%@" on screen: the engine's own sentence is shown instead.
        let english = "HIGH RISK: Authorization 2 hands the account 0xAAA to the contract at 0xBBB. That contract’s code then runs as that account and can move everything in it."
        let broken: (String) -> String? = { key in key.contains("%@") ? "壊れた訳 %1$@" : nil }
        #expect(ReviewText.sentence(english, translate: broken) == english)
    }

    @Test func eitherApostropheMatchesEither() {
        // The engine writes "transaction's", the catalogue "transaction’s". Both
        // spellings of the text match both spellings of the template, and the
        // values come back exactly as the engine wrote them.
        let curly = ReviewText.Template("%@ of this instruction’s %@ accounts come from an address lookup table and cannot be shown.")
        let straight = ReviewText.Template("%@ of this instruction's %@ accounts come from an address lookup table and cannot be shown.")
        for template in [curly, straight] {
            #expect(template.match("1 of this instruction's 2 accounts come from an address lookup table and cannot be shown.") == ["1", "2"])
            #expect(template.match("1 of this instruction’s 2 accounts come from an address lookup table and cannot be shown.") == ["1", "2"])
        }
        // The widening is for apostrophes only: other text still has to agree.
        #expect(curly.match("1 of this instructions 2 accounts come from an address lookup table and cannot be shown.") == nil)
    }

    /// Two requests whose reviews carry the warnings that used to stay in English
    /// in every language: the two lookup-table warnings and both kinds of EIP-7702
    /// delegation warning. Generated from the public test mnemonic.
    private static let lookupTableRequest: [String: Any] = ["chain": "solana", "kind": "transaction", "message":
        "gAEAAQPwNidiRqdbneM0ntQrFeIy9lGPwg9fzU8dZOgfm9JY9wQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQECAgADDAIAAAAAypo7AAAAAAEGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgEDAA=="]
    private static let delegationRequest: [String: Any] = ["chain": "evm", "kind": "transaction",
        "address": "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", "transaction":
        "0x04f8da01800102830186a0949858effd232b4033e47d90003d41ec34ecaeda948080c0f8b8f85a019400000000219ab540356cbb839cbe05303d7705fa0101a0a92ef63d1acae0e28d3a6df5f62b76b58a981fe84856782897e63a1c64d35a7da043e82e50e86c9fc8ae8dc04aedefe83c0a47a351446d1027043bdca7870e3f2df85a019400000000219ab540356cbb839cbe05303d7705fa0401a04d3c36df683aa4e0f1c877f4b0bf16a09969d912d686936019009868fd8451fca04ea87316ba1c6bab6bfdd433d6510f2a9343a96dd2c0798afb01d31fa019a08a"]

    @Test(arguments: ["ja", "zh-Hans"])
    func theEnginesRealWarningsAreTranslated(language: String) async throws {
        // The test that should have existed: run the app's real engine, then read
        // its warnings through a language other than English. Falling back to
        // English is a failure here, not a pass.
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language): no .lproj")
        let bundle = try #require(Bundle(path: path))
        let marker = "\u{0}missing\u{0}"
        let translate: (String) -> String? = { key in
            let value = bundle.localizedString(forKey: key, value: marker, table: nil)
            return value == marker ? nil : value
        }
        let engine = SigningEngine()
        var checked = 0
        for request in [Self.lookupTableRequest, Self.delegationRequest] {
            let review = try await engine.run(operation: "review", parameters: ["request": request])
            for warning in try #require(review["warnings"] as? [String]) {
                let shown = ReviewText.sentence(warning, translate: translate)
                #expect(shown != warning, "\(language) left this in English: \(warning.prefix(90))")
                #expect(!shown.contains("%@") && !shown.contains("$@"), "a placeholder reached the screen: \(shown)")
                checked += 1
            }
        }
        #expect(checked >= 5, "the requests should produce the lookup-table and delegation warnings")
    }

    @Test func aTranslatedWarningIsActuallyLoadedFromTheBundle() throws {
        // Proof the table is wired up, not just that the fallback works. The
        // app under test runs in English, so look the string up in a language
        // bundle directly.
        let english = "UNLIMITED spending approval."
        for language in ["zh-Hans", "ja", "de", "ru"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language): no .lproj")
            let bundle = try #require(Bundle(path: path), "\(language): unreadable bundle")
            let translated = bundle.localizedString(forKey: english, value: "MISSING", table: nil)
            #expect(translated != "MISSING", "\(language) has no translation")
            #expect(translated != english, "\(language) was left in English")
        }
    }

    @Test func theEnginesLiveWarningsAreCoveredOrLeftInEnglish() async throws {
        // Run a real request through the real engine and check that every warning
        // it produces is either translated by an exact entry or matched by a
        // template — never half-substituted.
        let engine = SigningEngine()
        let request: [String: Any] = ["chain": "evm", "kind": "transaction", "transaction": [
            "type": 2, "chainId": 7700, "nonce": 0, "to": "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
            "value": "0", "data": "0x12345678", "gasLimit": "100000", "maxFeePerGas": "2", "maxPriorityFeePerGas": "1"]]
        let review = try await engine.run(operation: "review", parameters: ["request": request])
        let warnings = try #require(review["warnings"] as? [String])
        #expect(!warnings.isEmpty)
        for warning in warnings {
            let shown = ReviewText.sentence(warning)
            #expect(!shown.isEmpty)
            #expect(!shown.contains("%@"), "a placeholder reached the screen: \(shown)")
        }
        // This chain has no name here, so that notice must be one of them, and it
        // is a template warning — proof the value survived the round trip.
        #expect(warnings.contains { $0.contains("does not recognise EVM chain 7700") })
        let notice = try #require(warnings.first { $0.contains("does not recognise EVM chain") })
        #expect(ReviewText.sentence(notice).contains("7700"))
    }
}
