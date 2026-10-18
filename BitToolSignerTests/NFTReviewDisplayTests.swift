import Foundation
import SwiftUI
import UIKit
import Testing
@testable import BitToolSigner

/// NFT fields of the engine's review display: parsing bounds, summary helpers
/// and Details routing. Public fixtures only.
struct NFTReviewDisplayTests {
    private let contract = "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D"
    /// keccak256("vitalik") as a decimal ENS token ID (77 digits).
    private let ensID = "79233663829379634837589865448569342784712482819484549289560981379859480642508"

    /// `review.display` exactly as the engine emits it (engine/src at this revision) for:
    /// ERC-721 safeTransferFrom of an ENS name, approve(spender, 2^255) and approve(spender, MAX)
    /// on contracts outside the token registry, transferFrom(…, 1234) on BAYC, ERC-1155 single and
    /// batch transfers, setApprovalForAll, and Seaport 1.6 orders (OpenSea-style listing, a listing
    /// priced in 10^77 raw units of an unknown token, and a mixed order giving NFT #2 plus 0.1 ETH).
    private static let engineFixtures: [String: [String: Any]] = {
        let json = #"""
        {
        "ensTransfer": {"action": "Send NFT", "headline": "NFT #79233663…80642508 (77 digits)", "counterpartyLabel": "To", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "assetKind": "nft", "assetContract": "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85", "assetContractLabel": "NFT contract (not verified)", "tokenId": "79233663829379634837589865448569342784712482819484549289560981379859480642508", "fee": "0.0002 ETH"},
        "ambiguousApproveHuge": {"action": "Approve (NFT or token)", "headline": "NFT #57896044…64819968 (77 digits) — or 57896044…64819968 (77 digits) raw token units if this is an ERC-20", "counterpartyLabel": "Spender", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "assetKind": "nftOrToken", "assetContract": "0x1111111111111111111111111111111111111111", "assetContractLabel": "Contract (NFT or token)", "tokenId": "57896044618658097711785492504343953926634992332820282019728792003956564819968", "fee": "0.0002 ETH"},
        "ambiguousApproveUnlimited": {"action": "Approve (NFT or token)", "amount": "Unlimited", "symbol": "tokens", "headline": "NFT #11579208…29639935 (78 digits) — or unlimited raw token units if this is an ERC-20", "counterpartyLabel": "Spender", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "assetKind": "nftOrToken", "assetContract": "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D", "assetContractLabel": "Contract (NFT or token)", "tokenId": "115792089237316195423570985008687907853269984665640564039457584007913129639935", "fee": "0.0002 ETH"},
        "ambiguousTransferShort": {"action": "Transfer (NFT or token)", "headline": "NFT #1234 — or 1234 raw units if ERC-20", "counterpartyLabel": "To", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "assetKind": "nftOrToken", "assetContract": "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D", "assetContractLabel": "Contract (NFT or token)", "tokenId": "1234", "fee": "0.0002 ETH"},
        "erc1155Single": {"action": "Send ERC-1155 Token", "headline": "3 × #7", "counterpartyLabel": "To", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "assetKind": "multiToken", "assetContract": "0x1111111111111111111111111111111111111111", "assetContractLabel": "ERC-1155 contract (not verified)", "tokenId": "7", "fee": "0.0002 ETH"},
        "erc1155Batch": {"action": "Send ERC-1155 Batch", "headline": "3 items · IDs #7, #8 (+1 more)", "counterpartyLabel": "To", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "assetKind": "multiToken", "assetContract": "0x1111111111111111111111111111111111111111", "assetContractLabel": "ERC-1155 contract (not verified)", "fee": "0.0002 ETH"},
        "collectionApproval": {"action": "Approve All NFTs", "headline": "All your NFTs in 0xBC4C…f13D", "counterpartyLabel": "Operator", "counterparty": "0xBAbAbabAbabaBABaBAbABabaBAbAbaBaBAbABaBa", "assetKind": "nft", "assetContract": "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D", "assetContractLabel": "NFT contract (not verified)", "fee": "0.0002 ETH"},
        "seaportListing": {"action": "List NFT for Sale (Seaport 1.6)", "amount": "0.95", "symbol": "ETH", "headline": "NFT #1234 · 0xBC4C…f13D", "counterpartyLabel": "Marketplace", "counterparty": "0x0000000000000068F116a894984e2DB1123eB395", "assetKind": "nftOrder", "assetContract": "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D", "assetContractLabel": "NFT contract (not verified)", "tokenId": "1234", "give": ["NFT #1234 · 0xBC4C…f13D"], "receive": ["0.95 ETH"], "others": ["0.025 ETH → 0x0000…a719 (OpenSea fee recipient)", "0.025 ETH → 0x1234…7890 (unrecognised recipient)"]},
        "seaportRawPrice": {"action": "List NFT for Sale (Seaport 1.6)", "amount": "100000000000000000000000000000000000000000000000000000000000000000000000000000", "symbol": "raw units", "headline": "NFT #1234 · 0xBC4C…f13D", "counterpartyLabel": "Marketplace", "counterparty": "0x0000000000000068F116a894984e2DB1123eB395", "assetKind": "nftOrder", "assetContract": "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D", "assetContractLabel": "NFT contract (not verified)", "tokenId": "1234", "give": ["NFT #1234 · 0xBC4C…f13D"], "receive": ["100000000000000000000000000000000000000000000000000000000000000000000000000000 raw units of 0x7777…7777"]},
        "seaportMixed": {"action": "Sign Seaport Order (Seaport 1.6)", "headline": "Give 2 items · receive 1 item", "counterpartyLabel": "Marketplace", "counterparty": "0x0000000000000068F116a894984e2DB1123eB395", "assetKind": "nftOrder", "assetContract": "0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D", "assetContractLabel": "NFT contract (not verified)", "tokenId": "2", "give": ["NFT #2 · 0xBC4C…f13D", "0.1 ETH"], "receive": ["1 ETH"]}
        }
        """#
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return object as? [String: [String: Any]] ?? [:]
    }()

    private func fixture(_ name: String) throws -> [String: Any] {
        try #require(Self.engineFixtures[name], "missing fixture \(name)")
    }

    private func engineDisplay(_ name: String) throws -> ReviewDisplay {
        try #require(review(try fixture(name)).display, "\(name)")
    }

    private func review(_ display: [String: Any], chain: String = "evm") -> TransactionReview {
        TransactionReview([
            "chain": chain, "title": "Contract call", "summary": "", "requestHash": String(repeating: "b", count: 64),
            "fields": [["label": "Network", "value": "Ethereum"]], "warnings": [], "decodeStatus": "fullyDecoded",
            "riskLevel": "normal", "network": ["chainId": "1", "name": "Ethereum", "symbol": "ETH"],
            "display": display,
        ])
    }

    private func parse(_ raw: [String: Any]) -> ReviewDisplay? { ReviewDisplay(raw) }

    // MARK: Parsing

    @Test func engineFixturesParseWithTheirKind() throws {
        #expect(Self.engineFixtures.count == 10)
        let kinds: [String: ReviewAssetKind] = [
            "ensTransfer": .nft, "collectionApproval": .nft, "ambiguousApproveHuge": .nftOrToken,
            "ambiguousApproveUnlimited": .nftOrToken, "ambiguousTransferShort": .nftOrToken, "erc1155Single": .multiToken,
            "erc1155Batch": .multiToken, "seaportListing": .nftOrder, "seaportRawPrice": .nftOrder, "seaportMixed": .nftOrder,
        ]
        for (name, kind) in kinds {
            let display = try engineDisplay(name)
            #expect(display.assetKind == kind, "\(name)")
            #expect(display.assetContract != nil && display.assetContractLabel != nil, "\(name)")
            #expect(display.note == nil, "\(name)")
        }
        let listing = try engineDisplay("seaportListing")
        #expect(listing.flowSections.map(\.kind) == [.give, .receive, .others])
        #expect(listing.others.last == "0.025 ETH → 0x1234…7890 (unrecognised recipient)")
    }

    @Test func parsesEveryNFTField() throws {
        let display = try #require(review([
            "action": "Send NFT", "headline": "NFT #1234", "counterpartyLabel": "To",
            "counterparty": "0x2222222222222222222222222222222222222222",
            "assetKind": "nft", "assetContract": contract, "assetContractLabel": "Collection contract", "tokenId": "1234",
            "give": ["NFT #1234 · 0xBC4C…f13D"], "receive": ["0.95 ETH"],
            "others": ["0.025 ETH → 0x0000…a719 (OpenSea fee recipient)"],
        ]).display)
        #expect(display.action == "Send NFT")
        #expect(display.assetKind == .nft && display.isNFT)
        #expect(display.assetContract == contract)
        #expect(display.assetContractLabel == "Collection contract")
        #expect(display.assetContractCaption == "Collection contract")
        #expect(display.tokenId == "1234")
        #expect(display.give == ["NFT #1234 · 0xBC4C…f13D"])
        #expect(display.receive == ["0.95 ETH"])
        #expect(display.others == ["0.025 ETH → 0x0000…a719 (OpenSea fee recipient)"])
        #expect(display.counterparty == "0x2222222222222222222222222222222222222222")
    }

    @Test func parsesEveryAssetKind() {
        let kinds: [(String, ReviewAssetKind)] = [("nft", .nft), ("nftOrToken", .nftOrToken), ("multiToken", .multiToken), ("nftOrder", .nftOrder)]
        for (raw, kind) in kinds {
            #expect(parse(["action": "A", "assetKind": raw])?.assetKind == kind)
        }
    }

    @Test func displayWithoutNFTKeysIsUnchanged() throws {
        let raw: [String: Any] = ["action": "Send", "amount": "1", "symbol": "ETH", "counterpartyLabel": "To",
                                  "counterparty": "0x0000000000000000000000000000000000000001", "fee": "0.0001 ETH"]
        let display = try #require(ReviewDisplay(raw))
        #expect(display == ReviewDisplay(action: "Send", amount: "1", symbol: "ETH", headline: nil, counterpartyLabel: "To",
                                         counterparty: "0x0000000000000000000000000000000000000001", fee: "0.0001 ETH", note: nil))
        #expect(!display.isNFT)
        #expect(display.assetContract == nil && display.tokenId == nil && display.assetContractLabel == nil)
        #expect(display.give.isEmpty && display.receive.isEmpty && display.others.isEmpty)
        #expect(display.flowSections.isEmpty)
        #expect(display.summaryTokenID == nil)
        #expect(!display.showsAssetBox)
        #expect(display.assetContractCaption == "NFT contract (not verified)")
    }

    @Test func missingOrMalformedDisplayIsNil() {
        #expect(ReviewDisplay(nil) == nil)
        #expect(ReviewDisplay("Send NFT") == nil)
        #expect(parse(["headline": "NFT #1"]) == nil)
        #expect(parse(["action": 7]) == nil)
        #expect(review(["headline": "NFT #1", "assetKind": "nft"]).display == nil)
    }

    @Test func wrongTypesAreIgnored() throws {
        let display = try #require(parse([
            "action": "Send NFT", "assetKind": "nftOrder", "assetContract": 42, "assetContractLabel": ["Mint"],
            "tokenId": NSNumber(value: 1234), "give": "NFT #1", "receive": ["0.95 ETH", 3], "others": ["to": "x"],
        ]))
        #expect(display.action == "Send NFT")
        #expect(display.assetKind == .nftOrder)
        #expect(display.assetContract == nil && display.assetContractLabel == nil && display.tokenId == nil)
        // A list with any non-string entry is dropped whole, never shown partially.
        #expect(display.give.isEmpty && display.receive.isEmpty && display.others.isEmpty)
        #expect(parse(["action": "Send NFT", "assetKind": 1])?.assetKind == nil)
    }

    @Test func unknownAssetKindDropsEveryNFTKey() throws {
        // Fail closed on an engine/app version mismatch: no contract box, no
        // "NFT contract (not verified)" caption, no order lists.
        var raw = try fixture("seaportListing")
        for kind in ["NFT", "erc721", "", "nftorder", "token", "nftBid"] {
            raw["assetKind"] = kind
            let display = try #require(parse(raw))
            #expect(display.assetKind == nil && !display.isNFT, "\(kind)")
            #expect(display.assetContract == nil && display.assetContractLabel == nil && display.tokenId == nil, "\(kind)")
            #expect(display.give.isEmpty && display.receive.isEmpty && display.others.isEmpty, "\(kind)")
            #expect(!display.showsAssetBox && display.flowSections.isEmpty && display.summaryTokenID == nil, "\(kind)")
            // The generic keys are still shown.
            #expect(display.action == "List NFT for Sale (Seaport 1.6)" && display.amount == "0.95", "\(kind)")
        }
        raw["assetKind"] = nil
        #expect(parse(raw).map { !$0.showsAssetBox && $0.flowSections.isEmpty } == true)
        // A memberwise display without a kind never shows NFT boxes either.
        let bare = ReviewDisplay(action: "Send", amount: nil, symbol: nil, headline: nil, counterpartyLabel: nil, counterparty: nil,
                                 fee: nil, note: nil, assetContract: contract, tokenId: ensID, give: ["NFT #1"])
        #expect(!bare.showsAssetBox && bare.flowSections.isEmpty && bare.summaryTokenID == nil)
    }

    @Test func emptyValuesAreAbsent() throws {
        let display = try #require(parse([
            "action": "Send NFT", "assetKind": "nftOrder", "assetContract": "", "assetContractLabel": "  ", "tokenId": "\n",
            "give": ["", " ", "NFT #1"], "receive": [String](),
        ]))
        #expect(display.assetContract == nil && display.assetContractLabel == nil && display.tokenId == nil)
        #expect(display.give == ["NFT #1"])
        #expect(display.receive.isEmpty)
    }

    @Test func oversizedValuesAreBounded() throws {
        let long = String(repeating: "9", count: 301)
        let exact = String(repeating: "7", count: 300)
        let display = try #require(parse([
            "action": "List NFT", "assetKind": "nftOrder", "assetContract": long, "assetContractLabel": long, "tokenId": exact,
            "give": (1...40).map { "NFT #\($0)" }, "receive": (1...32).map { "\($0) ETH" }, "others": [long],
        ]))
        // Identifiers are shown whole or not at all.
        #expect(display.assetContract == nil)
        #expect(display.assetContractLabel == nil)
        #expect(display.tokenId == exact)
        // More than 32 lines: 31 lines plus a pointer to Details.
        #expect(display.give.count == ReviewDisplay.maxListLines)
        #expect(display.give.first == "NFT #1" && display.give[30] == "NFT #31")
        #expect(display.give.last == "+9 more (see Details)")
        // Exactly 32 lines are kept as sent.
        #expect(display.receive == (1...32).map { "\($0) ETH" })
        // Over-long lines are cut in the middle within the cap.
        let line = try #require(display.others.first)
        #expect(line.count == ReviewDisplay.maxStringLength)
        #expect(line.hasPrefix("999") && line.hasSuffix("999") && line.contains("…"))
    }

    @Test func overLongLinesKeepTheRecipientTag() {
        let tail = " → 0x1234…5678 (unrecognised recipient)"
        let line = "Order 3: " + String(repeating: "1", count: 78) + " raw units of 0x7777…7777 → "
            + String(repeating: "2", count: 78) + " raw units of 0x7777…7777 (changes linearly over time) "
            + String(repeating: "x", count: 80) + tail
        #expect(line.count > ReviewDisplay.maxStringLength)
        let bounded = ReviewDisplay.boundedLine(line)
        #expect(bounded.count == ReviewDisplay.maxStringLength)
        #expect(bounded.hasPrefix("Order 3: " + String(repeating: "1", count: 78) + " raw units"))
        #expect(bounded.hasSuffix(tail))
        #expect(bounded.contains("…"))
        let short = "0.025 ETH" + tail
        #expect(ReviewDisplay.boundedLine(short) == short)
        #expect(ReviewDisplay.boundedLines([line]) == [bounded])
    }

    // MARK: Summary helpers

    private struct SummaryRow: Equatable {
        let id: String?
        let caption: LocalizedStringKey
        let box: Bool
    }

    @Test func tokenIDRowAndCaptionForEngineDisplays() throws {
        func row(_ name: String) throws -> SummaryRow {
            let display = try engineDisplay(name)
            return SummaryRow(id: display.summaryTokenID, caption: display.tokenIDCaption, box: display.showsAssetBox)
        }
        // Proven NFT with an abbreviated headline: the full ID, captioned as a token ID.
        #expect(try row("ensTransfer") == SummaryRow(id: ensID, caption: "Token ID", box: true))
        // Ambiguous NFT-or-ERC-20: the same number may be an allowance or amount.
        let huge = "57896044618658097711785492504343953926634992332820282019728792003956564819968"
        #expect(try row("ambiguousApproveHuge") == SummaryRow(id: huge, caption: "Token ID or raw amount", box: true))
        let max = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        #expect(try row("ambiguousApproveUnlimited") == SummaryRow(id: max, caption: "Token ID or raw amount", box: true))
        #expect(try row("ambiguousTransferShort") == SummaryRow(id: nil, caption: "Token ID or raw amount", box: true))
        // Headlines that show "#<id>" whole.
        #expect(try row("erc1155Single") == SummaryRow(id: nil, caption: "Token ID", box: true))
        #expect(try row("erc1155Batch") == SummaryRow(id: nil, caption: "Token ID", box: true))
        #expect(try row("seaportListing") == SummaryRow(id: nil, caption: "Token ID", box: true))
        #expect(try row("collectionApproval") == SummaryRow(id: nil, caption: "Token ID", box: true))
        // "Give 2 items" is a count, not NFT #2.
        #expect(try row("seaportMixed") == SummaryRow(id: "2", caption: "Token ID", box: true))
        // The engine's caption is shown as sent; the default is used only when it is missing.
        #expect(try engineDisplay("ensTransfer").assetContractCaption == "NFT contract (not verified)")
        #expect(try engineDisplay("ambiguousApproveHuge").assetContractCaption == "Contract (NFT or token)")
    }

    @Test func tokenIDRowOnlyWhenTheHeadlineShowsHashID() {
        func summary(_ headline: String?, _ tokenID: String?, amount: String? = nil) -> String? {
            ReviewDisplay(action: "Send NFT", amount: amount, symbol: nil, headline: headline, counterpartyLabel: nil,
                          counterparty: nil, fee: nil, note: nil, assetKind: .nft, tokenId: tokenID).summaryTokenID
        }
        #expect(summary("NFT #1234", "1234") == nil)
        #expect(summary("3 × #7", "7") == nil)
        #expect(summary("NFT #0", "0") == nil)
        #expect(summary("NFT #79233663…80642508 (77 digits)", ensID) == ensID)
        #expect(summary("NFT #12345", "1234") == "1234")
        #expect(summary("NFT #91234", "1234") == "1234")
        #expect(summary(nil, "1234") == "1234")
        #expect(summary("NFT #1234", nil) == nil)
        #expect(summary(nil, "88", amount: "Token #88") == nil)
        // Counts and decimals never count as showing the ID.
        #expect(summary("Give 2 items · receive 1 item", "2") == "2")
        #expect(summary("Give 2 items · receive 1 item", "1") == "1")
        #expect(summary("NFT #1234 · 0xBC4C…f13D", "95", amount: "0.95") == "95")
        #expect(summary("Sale 1234", "1234") == "1234")
    }

    @Test func hashIDMatchingRespectsDigitBoundaries() {
        #expect(ReviewDisplay.text("NFT #1234", showsTokenID: "1234"))
        #expect(ReviewDisplay.text("NFT #1234 — or 1234 raw units if ERC-20", showsTokenID: "1234"))
        #expect(ReviewDisplay.text("IDs #12345, #1234 (+1 more)", showsTokenID: "1234"))
        #expect(ReviewDisplay.text("3 × #7", showsTokenID: "7"))
        #expect(!ReviewDisplay.text("1234", showsTokenID: "1234"))
        #expect(!ReviewDisplay.text("NFT #12345", showsTokenID: "1234"))
        #expect(!ReviewDisplay.text("NFT #01234", showsTokenID: "1234"))
        #expect(!ReviewDisplay.text("0.95", showsTokenID: "95"))
        #expect(!ReviewDisplay.text("Give 2 items", showsTokenID: "2"))
        #expect(!ReviewDisplay.text("NFT #1234", showsTokenID: ""))
    }

    @Test func nftAmountsAndHeadlinesAreNeverCutOff() throws {
        for name in ["seaportRawPrice", "ambiguousApproveUnlimited", "ensTransfer"] {
            let display = try engineDisplay(name)
            #expect(ReviewSummaryCard.amountLineLimit(display) == nil, "\(name)")
            #expect(ReviewSummaryCard.headlineLineLimit(display) == nil, "\(name)")
        }
        // Non-NFT reviews keep their existing limits.
        let plain = ReviewDisplay(action: "Send", amount: "1", symbol: "ETH", headline: nil, counterpartyLabel: nil,
                                  counterparty: nil, fee: nil, note: nil)
        #expect(ReviewSummaryCard.amountLineLimit(plain) == 2 && ReviewSummaryCard.headlineLineLimit(plain) == 8)
        #expect(ReviewSummaryCard.amountLineLimit(nil) == 2 && ReviewSummaryCard.headlineLineLimit(nil) == 8)
    }

    @Test func flowSectionsKeepOrderAndSkipEmptyLists() {
        let display = ReviewDisplay(action: "List NFT", amount: "0.95", symbol: "ETH", headline: nil, counterpartyLabel: nil,
                                    counterparty: nil, fee: nil, note: nil, assetKind: .nftOrder,
                                    give: ["NFT #1234 · 0xBC4C…f13D"], others: ["0.025 ETH → 0x0000…a719 (OpenSea fee recipient)"])
        #expect(display.flowSections.map(\.kind) == [.give, .others])
        #expect(display.flowSections.map(\.title) == ["You give", "Also paid out"])
        #expect(display.flowSections.map(\.systemImage) == ["arrow.up.right", "arrow.triangle.branch"])
        #expect(ReviewFlowSection(kind: .receive, lines: ["1 ETH"]).title == "You receive")
        #expect(ReviewFlowSection(kind: .receive, lines: ["1 ETH"]).systemImage == "arrow.down.left")
    }

    @Test func glyphAndSpokenLabels() {
        #expect(ReviewAssetKind.nft.systemImage == "photo.artframe")
        #expect(ReviewAssetKind.nftOrToken.systemImage == "photo.artframe")
        // ERC-1155 IDs may be fungible: a neutral stack, never called an NFT.
        #expect(ReviewAssetKind.multiToken.systemImage == "square.stack.3d.up.fill")
        #expect(ReviewAssetKind.nftOrder.systemImage == "tag.fill")
        #expect(ReviewAssetKind.nft.accessibilityLabel == "NFT")
        #expect(ReviewAssetKind.multiToken.accessibilityLabel == "ERC-1155 token")
        #expect(ReviewAssetKind.nftOrToken.accessibilityLabel == "NFT or token")
        #expect(ReviewAssetKind.nftOrder.accessibilityLabel == "NFT order")
        for kind in [ReviewAssetKind.nft, .nftOrToken, .multiToken, .nftOrder] {
            #expect(UIImage(systemName: kind.systemImage) != nil, "\(kind)")
        }
        #expect(ReviewDisplay.spokenTokenID("1234") == "1234")
        #expect(ReviewDisplay.spokenTokenID("12345678901234") == "1234, 5678, 9012, 34")
    }

    // MARK: Details routing

    @Test func tokenIDsAndQuantitiesAreNeverStyledAsAddresses() {
        // 33% of random uint256 IDs pass the Bitcoin pattern; routing is by label.
        let bitcoinLike = "106686051536470969934437590839493823286117473395005282216036227418063047698617"
        #expect(AddressFormatter.looksLikeAddress(bitcoinLike))
        for label in ["Token ID", "Item 2 · Token ID", "Call 2: Token ID", "NFT token ID", "Amount / NFT token ID",
                      "Allowance / NFT token ID", "Quantity", "Item 1 · Quantity", "Total quantity", "Items", "Distinct token IDs"] {
            let field = ReviewField(id: 0, label: label, value: bitcoinLike)
            #expect(field.holdsNumber, "\(label)")
            #expect(field.isTokenIdentifier, "\(label)")
            #expect(!field.rendersAsAddress, "\(label)")
            #expect(ReviewDetailsCard.rowStyle(field) == .identifier, "\(label)")
        }
        for label in ["Token amount (raw units)", "Allowance (raw units)", "Raw amount", "Native amount (wei)"] {
            let field = ReviewField(id: 0, label: label, value: bitcoinLike)
            #expect(field.holdsNumber && !field.isTokenIdentifier && !field.rendersAsAddress, "\(label)")
            #expect(ReviewDetailsCard.rowStyle(field) == .text, "\(label)")
        }
    }

    @Test func detailsRowStyles() {
        // Long item lists stay whole instead of collapsing behind "Show All".
        let items = ReviewField(id: 1, label: "Items", value: (1...8).map { "#\($0)000000000000000000000000000 × \($0)" }.joined(separator: "\n"))
        #expect(items.isLong)
        #expect(ReviewDetailsCard.rowStyle(items) == .identifier)
        // Beyond 4,096 characters even an identifier field collapses.
        #expect(ReviewDetailsCard.rowStyle(ReviewField(id: 2, label: "Items", value: String(repeating: "#1 × 1\n", count: 700))) == .collapsible)
        #expect(ReviewDetailsCard.rowStyle(ReviewField(id: 3, label: "Signed values", value: String(repeating: "a", count: 300))) == .collapsible)
        #expect(ReviewDetailsCard.rowStyle(ReviewField(id: 4, label: "Method", value: "safeTransferFrom")) == .text)
        #expect(ReviewDetailsCard.rowStyle(ReviewField(id: 5, label: "Recipient", value: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")) == .address)
    }

    @Test func allDigitAddressesKeepAddressFormatting() {
        // The Solana System Program ID is 32 ones and must stay a copyable address.
        let system = ReviewField(id: 0, label: "Instruction 1 · Program", value: String(repeating: "1", count: 32))
        #expect(!system.holdsNumber && system.rendersAsAddress)
        #expect(ReviewDetailsCard.rowStyle(system) == .address)
        for label in ["Recipient", "Recipient / contract", "Contract", "Mint", "Operator", "Safe: Recipient", "Token account"] {
            let field = ReviewField(id: 0, label: label, value: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
            #expect(!field.holdsNumber && field.rendersAsAddress, "\(label)")
        }
        #expect(!ReviewField(id: 0, label: "Method", value: "safeTransferFrom").rendersAsAddress)
    }

    // MARK: Rendering

    @MainActor private func render(_ review: TransactionReview, size: DynamicTypeSize = .large,
                                   scheme: ColorScheme = .light) throws -> UIImage {
        let card = ReviewSummaryCard(review: review)
            .frame(width: 353)
            .padding(20)
            .background(Palette.background)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return try #require(renderer.uiImage)
    }

    @MainActor @Test func summaryCardRendersEngineDisplays() throws {
        let directory = ProcessInfo.processInfo.environment["NFT_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for name in Self.engineFixtures.keys.sorted() {
            for (size, scheme) in [(DynamicTypeSize.large, ColorScheme.light), (.accessibility5, .dark)] {
                let image = try render(review(try fixture(name)), size: size, scheme: scheme)
                #expect(image.size.width > 0 && image.size.height > 0, "\(name)")
                if let directory, let data = image.pngData() {
                    try data.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark-ax5" : "light").png"))
                }
            }
        }
    }

    @MainActor @Test func rawUnitOrderPriceWrapsInsteadOfTruncating() throws {
        // 78 digits + " raw units" needs about six largeTitle lines on a phone-width
        // card. A two-line limit (even at half scale) would leave it about one line
        // taller than a short price; wrapping in full makes it several lines taller.
        let raw = try fixture("seaportRawPrice")
        var short = raw
        short["amount"] = "0.95"
        short["symbol"] = "ETH"
        let rawHeight = try render(review(raw)).size.height
        let shortHeight = try render(review(short)).size.height
        let line = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).lineHeight
        #expect(rawHeight - shortHeight > 3 * line, "raw \(rawHeight) vs short \(shortHeight), line \(line)")
    }

    @MainActor @Test func detailsCardRendersTokenIDsAsPlainText() throws {
        let fields = [
            ReviewField(id: 0, label: "Token ID", value: "106686051536470969934437590839493823286117473395005282216036227418063047698617"),
            ReviewField(id: 1, label: "Items", value: (1...8).map { "#\($0)000000000000000000000000000 × \($0)" }.joined(separator: "\n")),
            ReviewField(id: 2, label: "Instruction 1 · Program", value: String(repeating: "1", count: 32)),
        ]
        #expect(fields.map(ReviewDetailsCard.rowStyle) == [.identifier, .identifier, .address])
        let renderer = ImageRenderer(content: ReviewDetailsCard(fields: fields).frame(width: 353).padding(20).background(Palette.background))
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        if let directory = ProcessInfo.processInfo.environment["NFT_SNAPSHOT_DIR"], let data = image.pngData() {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("details.png"))
        }
    }
}
