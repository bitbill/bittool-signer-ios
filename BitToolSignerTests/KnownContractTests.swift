import Foundation
import Testing
@testable import BitToolSigner

/// The bundled known-contract library and the review notice built from it.
/// Everything here is public reference data: addresses the projects themselves
/// published. A listing identifies a deployment and nothing more, so the tests
/// are about shape, reachability and how a hit or a miss is presented.
struct KnownContractTests {
    private struct File: Decodable {
        let schemaVersion: Int
        let source: String
        let updated: String
        let categories: [String]
        let counts: [String: Int]
        let contracts: [KnownContractEntry]
    }

    private func library() throws -> File {
        let url = try #require(Bundle.main.url(forResource: "known-contracts", withExtension: "json"),
                               "known-contracts.json must ship in the app bundle")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    // MARK: The bundled library

    @Test func everyRecordIsCompleteUniqueAndCountedAsTheFileClaims() throws {
        let file = try library()
        #expect(file.schemaVersion == 1)
        #expect(file.contracts.count > 1500)
        #expect(file.updated.count == 10, "an ISO date the Settings footer can show")
        let categories = Set(file.categories)
        var perChain: [String: Int] = [:]
        var seen = Set<String>()
        for entry in file.contracts {
            #expect(!entry.name.isEmpty, "\(entry.id)")
            #expect(!entry.project.isEmpty, "\(entry.id)")
            #expect(categories.contains(entry.category), "\(entry.id)")
            #expect(seen.insert(entry.id).inserted, "duplicate \(entry.id)")
            perChain[entry.chain, default: 0] += 1
            switch entry.chainFamily {
            case "evm":
                // Stored lowercased so a lookup never depends on checksum case.
                #expect(entry.address == entry.address.lowercased(), "\(entry.id)")
                #expect(entry.address.count == 42 && entry.address.hasPrefix("0x"), "\(entry.id)")
            case "tron":
                #expect(entry.address.hasPrefix("T") && entry.address.count == 34, "\(entry.id)")
            case "solana":
                #expect((32...44).contains(entry.address.count), "\(entry.id)")
            default:
                Issue.record("unexpected chain family \(entry.chainFamily)")
            }
        }
        #expect(perChain == file.counts, "the declared counts are what the Settings page shows")
    }

    /// Nothing may be listed under a chain the browser has no row for, or it
    /// would ship as data no one can see.
    @Test @MainActor func everyListedChainIsReachableFromTheDirectory() async throws {
        let directory = TokenDirectory()
        await directory.load()
        #expect(directory.contractCount > 1500)
        #expect(!directory.contractsUpdated.isEmpty)
        let reachable = Set(directory.networks.map(\.chain)).union([TokenDirectory.everyEVMChain])
        for chain in directory.contractsByNetwork.keys {
            #expect(reachable.contains(chain), "no network row shows \(chain)")
        }
        // Deterministic deployments are offered as their own row.
        #expect(directory.everyChainContracts.count > 20)
        #expect(directory.everyChainContracts.allSatisfy { $0.everyChain })
        // Sorted by project, then name: a 300-row list is read by eye.
        let ethereum = try #require(directory.networks.first { $0.chain == "evm:1" })
        let names = directory.contracts(for: ethereum).map { [$0.project, $0.name] }
        #expect(names.count > 300)
        #expect(names == names.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) })
        #expect(directory.contracts(for: ethereum).allSatisfy { !$0.everyChain })
    }

    @Test func wellKnownAddressesAreListedWhereTheyAreExpected() throws {
        let file = try library()
        func entry(_ chain: String, _ address: String) -> KnownContractEntry? {
            file.contracts.first { $0.chain == chain && $0.address.caseInsensitiveCompare(address) == .orderedSame }
        }
        // Permit2 and Seaport 1.6 are CREATE2 deployments at one address everywhere.
        let permit2 = try #require(entry("evm:*", "0x000000000022d473030f116ddee9f6b43ac78ba3"))
        #expect(permit2.everyChain)
        #expect(permit2.project == "Uniswap")
        #expect(entry("evm:*", "0x0000000000000068f116a894984e2db1123eb395")?.project == "OpenSea")
        // Chain-specific entries stay on their chain.
        #expect(entry("evm:1", "0x00000000000001ad428e4906ae43d8f9852d0dd6")?.name.contains("Seaport") == true)
        #expect(entry("solana:", "11111111111111111111111111111111")?.category == "infra")
        #expect(entry("tron:", "TA3q7XjdBQWb4qFxaPULUsnjvVZGgC9Brz")?.project == "JustLend DAO")
    }

    @Test func everyCategoryHasItsOwnGlyph() throws {
        let file = try library()
        var glyphs: [String: String] = [:]
        for category in file.categories {
            let entry = try #require(file.contracts.first { $0.category == category }, "\(category)")
            glyphs[category] = entry.systemImage
        }
        #expect(Set(glyphs.values).count == file.categories.count, "two categories share a glyph: \(glyphs)")
        // An import that adds a category still renders, with the neutral glyph.
        let later = KnownContractEntry(chainFamily: "evm", chainId: "1", address: "0x" + String(repeating: "1", count: 40),
                                       name: "Future", project: "Future", category: "restaking")
        #expect(later.systemImage == "square.grid.2x2.fill")
    }

    // MARK: The review notice

    private func contract(_ json: String) -> ReviewContract? {
        ReviewContract(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    @Test func aLibraryHitCarriesTheIdentificationItIsShownWith() throws {
        let hit = try #require(contract("""
        {"address": "0x000000000022D473030F116dDEE9F6B43aC78BA3", "role": "spender", "known": true,
         "name": "Uniswap Permit2", "protocol": "Uniswap", "category": "infra", "everyChain": true}
        """))
        #expect(hit.known)
        #expect(hit.role == .spender)
        #expect(hit.name == "Uniswap Permit2")
        #expect(hit.subtitle == "Uniswap · infra")
        #expect(hit.everyChain)
        #expect(hit.token == nil)
    }

    @Test func anUnlistedAddressIsStatedAsUnlistedAndKeepsItsRole() throws {
        let miss = try #require(contract(#"{"address": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "role": "operator", "known": false}"#))
        #expect(!miss.known)
        #expect(miss.role == .operator_)
        #expect(miss.name == nil)
        #expect(miss.subtitle == nil)
        #expect(!miss.everyChain)
    }

    /// The engine exempts an address the token registry already identified, so
    /// a USDT approval is not presented as an unknown contract.
    @Test func aRegistryTokenIsNamedInsteadOfCalledUnknown() throws {
        let token = try #require(contract(#"{"address": "0xdAC17F958D2ee523a2206206994597C13D831ec7", "role": "contract", "known": false, "token": "Tether USD (USDT)"}"#))
        #expect(!token.known)
        #expect(token.token == "Tether USD (USDT)")
        #expect(token.role == .contract)
    }

    /// "Known" with nothing to show is not a hit: the point of the notice is a
    /// name a person can compare with the project's own documentation.
    @Test func knownWithoutANameIsNotPresentedAsAHit() throws {
        let nameless = try #require(contract(#"{"address": "0x1234567890AbcdEF1234567890aBcdef12345678", "role": "spender", "known": true, "protocol": "Mystery"}"#))
        #expect(!nameless.known)
        #expect(nameless.name == nil)
        #expect(nameless.subtitle == nil, "no identification is shown for a nameless hit")
    }

    @Test func anUnknownRoleFallsBackToTheLeastSpecificWording() throws {
        let later = try #require(contract(#"{"address": "0x1234567890AbcdEF1234567890aBcdef12345678", "role": "delegate", "known": false}"#))
        #expect(later.role == .contract)
    }

    @Test func aRecordWithoutAnAddressIsNoRecord() {
        #expect(contract(#"{"role": "spender", "known": true, "name": "X"}"#) == nil)
        #expect(contract(#"{"address": "", "known": false}"#) == nil)
        #expect(contract(#"{"address": "   ", "known": false}"#) == nil)
        #expect(ReviewContract(nil) == nil)
        #expect(ReviewContract("0xabc") == nil)
        // An address long enough to be a decoration rather than an address.
        #expect(contract("{\"address\": \"\(String(repeating: "a", count: 400))\", \"known\": false}") == nil)
    }

    @Test func theReviewReadsTheContractTheEngineAttached() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"chain": "evm", "title": "Approve token spending", "summary": "Approve unlimited USDT",
         "fields": [{"label": "Spender", "value": "0x000000000022D473030F116dDEE9F6B43aC78BA3"}],
         "warnings": [], "requestHash": "ab", "riskLevel": "high", "decodeStatus": "fullyDecoded",
         "display": {"action": "Approve Spending", "counterpartyLabel": "Spender", "counterparty": "0x000000000022D473030F116dDEE9F6B43aC78BA3"},
         "contract": {"address": "0x000000000022D473030F116dDEE9F6B43aC78BA3", "role": "spender", "known": true,
                      "name": "Uniswap Permit2", "protocol": "Uniswap", "category": "infra", "everyChain": true}}
        """#.utf8)) as? [String: Any])
        let review = TransactionReview(raw)
        let contract = try #require(review.contract)
        #expect(contract.name == "Uniswap Permit2")
        // The summary already shows this address, so the notice goes there
        // rather than being repeated as a card.
        #expect(ReviewSummaryCard.showsNotice(for: review))
    }

    /// A token transfer authorizes the token contract, which is not the
    /// recipient the summary shows, so that notice needs its own card.
    @Test func aNoticeAboutAnAddressTheSummaryDoesNotShowGetsItsOwnCard() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"chain": "evm", "title": "Token transfer", "summary": "Send 1 USDT",
         "fields": [], "warnings": [], "requestHash": "ab", "decodeStatus": "fullyDecoded",
         "display": {"action": "Send", "counterpartyLabel": "To", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa"},
         "contract": {"address": "0xdAC17F958D2ee523a2206206994597C13D831ec7", "role": "contract", "known": false, "token": "Tether USD (USDT)"}}
        """#.utf8)) as? [String: Any])
        let review = TransactionReview(raw)
        #expect(review.contract?.token == "Tether USD (USDT)")
        #expect(!ReviewSummaryCard.showsNotice(for: review))
    }

    @Test func aChecksumDifferenceStillCountsAsTheSameAddress() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"chain": "evm", "title": "Approve", "summary": "", "fields": [], "warnings": [], "requestHash": "ab",
         "display": {"action": "Approve Spending", "counterpartyLabel": "Spender", "counterparty": "0x000000000022D473030F116dDEE9F6B43aC78BA3"},
         "contract": {"address": "0x000000000022d473030f116ddee9f6b43ac78ba3", "role": "spender", "known": true, "name": "Uniswap Permit2"}}
        """#.utf8)) as? [String: Any])
        #expect(ReviewSummaryCard.showsNotice(for: TransactionReview(raw)))
    }

    @Test func aReviewWithoutAContractHasNoNotice() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"chain": "bitcoin", "title": "Send bitcoin", "summary": "", "fields": [], "warnings": [], "requestHash": "ab"}
        """#.utf8)) as? [String: Any])
        let review = TransactionReview(raw)
        #expect(review.contract == nil)
        #expect(!ReviewSummaryCard.showsNotice(for: review))
    }
}
