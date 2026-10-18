import Foundation
import Testing
@testable import BitToolSigner

/// What Activity keeps for a signature, and what it can rebuild from it.
/// Public BIP39 fixtures and synthetic offline transactions only.
@MainActor
struct ActivityRecordTests {
    private let password = "Activity-Password1"
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let signer = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"

    private func makeStore() async throws -> (AppStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityRecordTests/" + UUID().uuidString, isDirectory: true)
        let vault = WalletVault(directory: directory.appendingPathComponent("Vaults"),
                                deviceKeys: SessionDeviceKeys())
        let store = AppStore(vault: vault, storageDirectory: directory)
        await store.reload()
        _ = try await store.createWallet(name: "Activity fixture", mnemonic: phrase, passphrase: "", password: password)
        return (store, directory)
    }

    /// An EVM transfer of 1 wei. No funds and no network are involved; the
    /// transport names a standard response profile so a signature can be encoded.
    private func request(nonce: Int = 0) -> [String: Any] {
        ["chain": "evm", "kind": "transaction", "path": "m/44'/60'/0'/0/0", "address": signer, "masterFingerprint": "73c5da0a",
         "transport": ["type": "eth-sign-request", "requestId": "00112233-4455-6677-8899-aabbccddeeff"],
         "transaction": ["type": 2, "chainId": "1", "nonce": nonce, "gasLimit": "21000", "maxFeePerGas": "2000000000",
                         "maxPriorityFeePerGas": "1000000000", "to": "0x1111111111111111111111111111111111111111",
                         "value": "1", "data": "0x"]]
    }

    @Test func aSignatureKeepsTheRequestItSignedAndTheResponseItProduced() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.prepare(request())
        let task = try #require(store.pendingTasks.first)
        try await store.sign(taskID: task.id, password: password)

        let receipt = try #require(store.receipts.first)
        #expect(receipt.hasPayloads)
        let json = try #require(receipt.requestJSON)
        #expect(json.contains("\"chain\":\"evm\""))
        // Canonical JSON: the same request always produces the same record.
        #expect(json == String(data: try JSONSerialization.data(withJSONObject: try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]), options: [.sortedKeys]), encoding: .utf8))
        // The output is kept exactly as the result screen showed and exported it:
        // the QR frames, and the text the file export writes.
        #expect(try #require(receipt.responseFrames).first?.lowercased().hasPrefix("ur:eth-signature/") == true)
        #expect(try #require(receipt.responseText).lowercased().hasPrefix("ur:eth-signature/"))
        #expect(receipt.responseFrames == store.signatureFrames)
        #expect(receipt.responseText == store.signatureText)
    }

    /// The stored request is reviewed again rather than replayed from a summary,
    /// so Activity shows the fields the review screen showed.
    @Test func theStoredRequestReviewsAgainToTheSameCommitment() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.prepare(request())
        let signedReview = try #require(store.review)
        let task = try #require(store.pendingTasks.first)
        try await store.sign(taskID: task.id, password: password)
        let receipt = try #require(store.receipts.first)

        // A fresh store, with no pending request, rebuilds the same review.
        let reloaded = AppStore(vault: store.vault, storageDirectory: directory)
        await reloaded.reload()
        let again = try await reloaded.review(storedRequest: try #require(receipt.requestJSON),
                                              expecting: receipt.requestHash)
        #expect(again.requestHash == signedReview.requestHash)
        #expect(again.chain == signedReview.chain)
        #expect(again.fields.map(\.label) == signedReview.fields.map(\.label))
        #expect(again.fields.map(\.value) == signedReview.fields.map(\.value))
        #expect(again.display?.action == signedReview.display?.action)
        // Reviewing a record never adopts it as the pending request.
        #expect(reloaded.review == nil && reloaded.plan == nil)
    }

    @Test func aStoredRequestThatDoesNotMatchItsFingerprintIsRefused() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.prepare(request())
        let task = try #require(store.pendingTasks.first)
        try await store.sign(taskID: task.id, password: password)
        let receipt = try #require(store.receipts.first)
        let json = try #require(receipt.requestJSON)

        // A different request reviews fine on its own, but not under this hash.
        let other = String(data: try JSONSerialization.data(withJSONObject: request(nonce: 9), options: [.sortedKeys]),
                           encoding: .utf8)!
        await #expect(throws: (any Error).self) {
            try await store.review(storedRequest: other, expecting: receipt.requestHash)
        }
        await #expect(throws: (any Error).self) {
            try await store.review(storedRequest: "not json", expecting: receipt.requestHash)
        }
        // The untouched record still verifies.
        _ = try await store.review(storedRequest: json, expecting: receipt.requestHash)
    }

    @Test func thePayloadsAreKeptForTheMostRecentSignaturesOnly() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rounds = SigningReceipt.payloadRetention + 2
        for nonce in 0..<rounds {
            try await store.prepare(request(nonce: nonce))
            let task = try #require(store.pendingTasks.first)
            try await store.sign(taskID: task.id, password: password)
        }
        #expect(store.receipts.count == rounds)
        #expect(store.receipts.prefix(SigningReceipt.payloadRetention).allSatisfy { $0.hasPayloads })
        #expect(store.receipts.dropFirst(SigningReceipt.payloadRetention).allSatisfy { !$0.hasPayloads })
        // Ageing a record out never removes the record itself.
        let oldest = try #require(store.receipts.last)
        #expect(!oldest.title.isEmpty && oldest.requestHash.count == 64 && oldest.summary?.isEmpty == false)

        let reloaded = AppStore(vault: store.vault, storageDirectory: directory)
        await reloaded.reload()
        #expect(reloaded.receipts.map(\.id) == store.receipts.map(\.id))
        #expect(reloaded.receipts.filter(\.hasPayloads).count == SigningReceipt.payloadRetention)
    }

    @Test func noSecretReachesTheActivityFile() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.prepare(request())
        let task = try #require(store.pendingTasks.first)
        try await store.sign(taskID: task.id, password: password)
        let journal = try String(contentsOf: directory.appendingPathComponent("receipts.json"), encoding: .utf8)
        #expect(journal.contains("requestJSON") && journal.contains("responseText"))
        #expect(!journal.contains("abandon"))
        #expect(!journal.contains(password))
        #expect(!journal.lowercased().contains("xprv"))
        #expect(!journal.contains("seed"))
    }

    /// A payload bigger than the per-record limit is not stored at all: the
    /// record stays, and a half-written payload never reaches the file.
    @Test func anOversizedPayloadIsLeftOutInsteadOfTruncated() {
        let big = String(repeating: "a", count: SigningReceipt.payloadLimit + 1)
        #expect(SigningReceipt.stored(big) == nil)
        #expect(SigningReceipt.stored(String(repeating: "a", count: SigningReceipt.payloadLimit)) != nil)
        #expect(SigningReceipt.stored("") == nil)
        #expect(SigningReceipt.stored(nil as String?) == nil)
        #expect(SigningReceipt.stored([big]) == nil)
        #expect(SigningReceipt.stored([] as [String]) == nil)
        #expect(SigningReceipt.stored(["ur:eth-signature/abc"]) != nil)
        #expect(SigningReceipt.stored(Array(repeating: "a", count: 2_049)) == nil)
    }

    /// Partial signatures (one wallet of several) have no response yet, so the
    /// record carries the request alone rather than an empty output section.
    @Test func aRecordWithoutPayloadsReportsThatItHasNone() {
        let bare = SigningReceipt(id: UUID(), date: Date(), chain: .evm, title: "Send", requestHash: String(repeating: "a", count: 64))
        #expect(!bare.hasPayloads)
        var requestOnly = bare; requestOnly.requestJSON = "{}"
        #expect(requestOnly.hasPayloads)
        #expect(!requestOnly.withoutPayloads.hasPayloads)
        #expect(requestOnly.withoutPayloads.title == bare.title && requestOnly.withoutPayloads.id == bare.id)
    }

    /// A file over the read limit would be rejected on the next launch and take
    /// the whole history with it. The limits are chosen so that cannot happen,
    /// and the write sheds payloads if it ever does.
    @Test func theLimitsCannotProduceAFileTheNextLaunchWouldReject() {
        // Worst case: every retained record at the payload limit, twice over
        // (request and response), plus generous metadata for all 100 records.
        let worstCase = SigningReceipt.payloadRetention * 2 * SigningReceipt.payloadLimit + 100 * 1_024
        #expect(worstCase < AppStore.receiptFileLimit,
                "\(worstCase) bytes could be written but only \(AppStore.receiptFileLimit) would be read back")
    }

    @Test func manySignaturesStayReadableAcrossALaunch() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Pad the calldata so every record carries a payload of real size.
        let padding = String(repeating: "f", count: 8_000)
        for nonce in 0..<SigningReceipt.payloadRetention {
            var fat = request(nonce: nonce)
            var transaction = try #require(fat["transaction"] as? [String: Any])
            transaction["data"] = "0x" + padding
            fat["transaction"] = transaction
            try await store.prepare(fat)
            let task = try #require(store.pendingTasks.first)
            try await store.sign(taskID: task.id, password: password, riskAcknowledged: true)
        }
        let file = directory.appendingPathComponent("receipts.json")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber).intValue
        #expect(size <= AppStore.receiptFileLimit, "\(size) bytes")
        #expect(store.receipts.count == SigningReceipt.payloadRetention)
        #expect(store.receipts.allSatisfy { $0.hasPayloads })
        let reloaded = AppStore(vault: store.vault, storageDirectory: directory)
        await reloaded.reload()
        #expect(reloaded.receipts.map(\.id) == store.receipts.map(\.id))
        #expect(reloaded.error == nil, "A readable file never reports an error.")
    }

    /// The list row repeats only a few decoded facts; everything else is one tap
    /// away in All Decoded Fields.
    @Test func theDecodedEssentialsNameTheActionAmountAndCounterparty() throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"chain": "evm", "title": "Approve token spending", "summary": "", "fields": [], "warnings": [],
         "requestHash": "ab", "display": {"action": "Approve Spending", "amount": "Unlimited", "symbol": "USDT",
         "counterpartyLabel": "Spender", "counterparty": "0x000000000022D473030F116dDEE9F6B43aC78BA3", "fee": "0.0012 ETH"}}
        """#.utf8)) as? [String: Any])
        let lines = ActivityDetailView.essentials(of: TransactionReview(raw))
        #expect(lines.map(\.id) == ["action", "amount", "counterparty", "fee"])
        #expect(lines[1].value == "Unlimited USDT")
        #expect(lines[2].value.hasPrefix("0x0000") && lines[2].value.contains("…"))
        #expect(lines[3].value == "0.0012 ETH")

        // A request with no structured display still names what it was.
        let plain = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"chain": "bitcoin", "title": "Send bitcoin", "summary": "", "fields": [], "warnings": [], "requestHash": "ab"}
        """#.utf8)) as? [String: Any])
        #expect(ActivityDetailView.essentials(of: TransactionReview(plain)).map(\.value) == ["Send bitcoin"])
    }
}
