import Foundation
import Testing
@testable import BitToolSigner

/// The Terms of Use and Privacy Policy ship inside the app: no page is fetched,
/// and the one address they name — the publisher's own site, as the contact —
/// is shown as plain text that the app never opens.
@MainActor
struct LegalDocumentTests {
    /// Filled in before release; the test only checks that no new ones appear.
    private let knownPlaceholders: Set<String> = ["[Publisher legal name]", "[Governing law jurisdiction]"]

    @Test(arguments: LegalDocument.allCases)
    func documentIsBundledAndRendersWithoutLinks(_ document: LegalDocument) throws {
        let url = try #require(Bundle.main.url(forResource: document.resource, withExtension: "txt"),
                               "\(document.title) must ship with the app.")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(document.title + "\nVersion 1.1 · Effective "))
        let addresses = text.matches(of: /https?:\/\/[^\s]+/).map { String($0.output) }
        #expect(Set(addresses).isSubset(of: ["https://bittool.com/signer"]), "Only our own contact address may appear: \(addresses)")
        #expect(text.contains("BITTOOL PTE. LTD."), "\(document.title) must name the publisher.")
        // Publisher, address and site each stand alone, so the page shows them on their own lines.
        let blocks = LegalDocumentView.blocks(of: document)
        let contact = try #require(blocks.firstIndex { $0.text == "https://bittool.com/signer" },
                                   "\(document.title) must show the site as its own block.")
        #expect(blocks[contact - 1].text == "support@bittool.com")
        #expect(blocks[contact - 2].text == "BITTOOL PTE. LTD.")
        #expect(blocks[contact - 3].kind == .heading && blocks[contact - 3].text.hasSuffix("Contact"))

        #expect(blocks.count > 20)
        #expect(blocks.filter { $0.kind == .heading }.count >= 10)
        #expect(blocks.allSatisfy { !$0.text.isEmpty && !$0.text.hasPrefix("## ") && !$0.text.hasPrefix("- ") })
        // The title belongs to the navigation bar; the version line leads the page.
        #expect(!blocks.contains { $0.text == document.title })
        #expect(blocks.first?.kind == .version && blocks.first?.text.hasPrefix("Version 1.1 ") == true)
        #expect(blocks.filter { $0.kind == .version }.count == 1)

        let placeholders = text.matches(of: /\[[^\]]+\]/).map { String($0.output) }
        #expect(Set(placeholders).isSubset(of: knownPlaceholders), "Unexpected placeholder: \(placeholders)")
    }

    @Test func privacyPolicyDescribesWhatTheAppActuallyDoes() throws {
        let url = try #require(Bundle.main.url(forResource: LegalDocument.privacy.resource, withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        for claim in ["no networking code", "Clear Activity", "two minutes", "Secure Enclave", "excluded from iCloud"] {
            #expect(text.contains(claim), "The policy should still say: \(claim)")
        }
    }
}

/// A paragraph may be wrapped over several lines in the bundled file; the page
/// must still show it as one block.
extension LegalDocumentTests {
    @Test func aBlankLineStartsANewBlock() {
        let parsed = LegalDocumentView.blocks(of: "Doc\nVersion 1.1 · Effective today\n\n## Contact\nfirst line\n\nsecond paragraph\nwrapped on",
                                              title: "Doc")
        #expect(parsed.map(\.text) == ["Version 1.1 · Effective today", "Contact", "first line", "second paragraph wrapped on"])
        #expect(parsed.map(\.kind) == [.version, .heading, .paragraph, .paragraph])
    }

    @Test func aWrappedParagraphStaysOneBlock() throws {
        let blocks = LegalDocumentView.blocks(of: .privacy)
        let heading = try #require(blocks.firstIndex { $0.kind == .heading && $0.text.hasPrefix("7.") })
        let paragraph = try #require(blocks[(heading + 1)...].first)
        #expect(paragraph.kind == .paragraph)
        #expect(paragraph.text.contains("never your recovery phrase"))
    }
}
