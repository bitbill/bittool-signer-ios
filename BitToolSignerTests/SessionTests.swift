import Foundation
import CryptoKit
import Testing
@testable import BitToolSigner

/// Public BIP39 fixtures and synthetic offline transactions only. Gates expose
/// races deterministically; the default engine is the actual bundled JS runtime.
@MainActor
struct SessionTests {
    private let password = "Session-Password1"
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let signer = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"

    @Test func oldEncryptedWalletMigratesWithoutRewritingItsSecret() async throws {
        let (store, directory, wallet) = try await makeStore(complete: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = vaultFile(directory, wallet.id)
        let before = try Data(contentsOf: file)
        #expect(store.metadataStatus(for: wallet.id) == .needsCompletion)
        #expect(store.publicMetadata(for: wallet.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Vaults/.\(wallet.id.uuidString.lowercased()).attempts").path))
        try await store.completeSetup(walletID: wallet.id, password: password)
        #expect(store.metadataStatus(for: wallet.id) == .ready)
        #expect(try Data(contentsOf: file) == before)
        let index = try #require(store.publicMetadata(for: wallet.id))
        #expect((index.raw["bitcoinPublicNodes"] as? [Any])?.count == 6)
        #expect((index.raw["tronAddressIndex"] as? [Any])?.count == 100)
        #expect((index.raw["solanaPublicKeys"] as? [Any])?.count == 3)
        #expect(index.raw["solanaAccounts"] == nil)
        #expect(index.raw["version"] as? Int == 1)

        // Wallet-level pairing reads only this public index: the four BTC script xpubs, EVM, TRON and the three Solana addresses.
        let pairing = try await store.walletPairing(walletID: wallet.id)
        // An animated multi-part QR: every frame carries its sequence number.
        #expect(pairing.frames.count >= 2, "The wallet-level QR is animated: \(pairing.frames.count) frame(s).")
        #expect(pairing.frames.allSatisfy { $0.hasPrefix("UR:BYTES/") })
        // Four Bitcoin script types plus EVM and TRON carry an xpub each; the
        // three Solana presets ship as addresses, because Solana has none.
        #expect(pairing.json.components(separatedBy: "\"xpub\"").count - 1 == 6)
        #expect(pairing.json.components(separatedBy: "\"address\"").count - 1 == 3)
        for path in ["m/84'/0'/0'", "m/86'/0'/0'", "m/49'/0'/0'", "m/44'/0'/0'"] {
            #expect(pairing.json.contains(path), "\(path) is exported")
        }
        #expect(!pairing.json.contains("m/48'"), "Multisig profiles stay out of the pairing.")
        #expect(pairing.json.contains("m/44'/501'/0'/0'") && !pairing.json.contains("m/44'/501'/1'/0'"))
        #expect(pairing.firstAddresses.map(\.chain) == ["btc", "btc", "btc", "btc", "evm", "tron", "sol", "sol", "sol"])
        // Every line needs its own identity and its own address: keying on the
        // chain alone made SwiftUI draw the first Bitcoin row four times.
        #expect(Set(pairing.firstAddresses.map(\.id)).count == pairing.firstAddresses.count,
                "Duplicate ids: \(pairing.firstAddresses.map(\.id))")
        #expect(Set(pairing.firstAddresses.map(\.address)).count == pairing.firstAddresses.count,
                "Repeated addresses: \(pairing.firstAddresses.map(\.address))")
        #expect(Set(pairing.firstAddresses.map(\.path)).count == pairing.firstAddresses.count)
        #expect(pairing.firstAddresses.filter { $0.chain == "btc" }.map(\.profile) == ["native", "taproot", "nested", "legacy"])
        #expect(pairing.firstAddresses.filter { $0.chain == "sol" }.map(\.profile) == ["standard", "trust", "legacy"])
        // The four Bitcoin addresses are one of each type, in offer order.
        let bitcoin = pairing.firstAddresses.filter { $0.chain == "btc" }.map(\.address)
        #expect(bitcoin.count == 4)
        #expect(bitcoin[0].hasPrefix("bc1q") && bitcoin[1].hasPrefix("bc1p")
                && bitcoin[2].hasPrefix("3") && bitcoin[3].hasPrefix("1"), "\(bitcoin)")
        #expect(pairing.firstAddresses.first { $0.chain == "evm" }?.address == signer)
        #expect(pairing.json.contains("\"protocol\" : \"bittool-signer-wallet\"") && pairing.json.contains("xpub") && !pairing.json.contains("xprv"))

        var other = index.raw; other["version"] = 2
        #expect(throws: (any Error).self) { try WalletPublicMetadata(other) }
        let cache = try String(contentsOf: directory.appendingPathComponent("PublicWallets/\(wallet.id.uuidString.lowercased()).json"), encoding: .utf8)
        #expect(!cache.contains(password))
        #expect(!cache.contains("abandon"))
        #expect(!cache.contains("xprv"))
        let reloaded = AppStore(vault: store.vault, storageDirectory: directory)
        await reloaded.reload()
        #expect(reloaded.publicMetadata(for: wallet.id)?.walletKeyId == index.walletKeyId)
        #expect(reloaded.wallets.first?.id == wallet.id)
    }

    @Test func corruptPublicCacheDoesNotDamageOrDecryptTheWallet() async throws {
        let (store, directory, wallet) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encrypted = try Data(contentsOf: vaultFile(directory, wallet.id))
        let sidecar = directory.appendingPathComponent("PublicWallets/\(wallet.id.uuidString.lowercased()).json")
        try Data("corrupt public fixture".utf8).write(to: sidecar)
        await store.reload()
        #expect(store.metadataStatus(for: wallet.id) == .invalid)
        #expect(store.publicMetadata(for: wallet.id) == nil)
        #expect(try Data(contentsOf: vaultFile(directory, wallet.id)) == encrypted)
        try await store.completeSetup(walletID: wallet.id, password: password)
        #expect(store.metadataStatus(for: wallet.id) == .ready)
    }

    @Test func stableIdentitySurvivesRenamePasswordChangeAndRejectsDuplicateImport() async throws {
        let (store, directory, wallet) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try #require(store.publicMetadata(for: wallet.id)?.walletKeyId)
        let fingerprint = store.fingerprint(for: wallet.id)
        #expect(fingerprint == "73C5DA0A", "The displayed identity is the BIP32 master fingerprint, as in pairing exports.")
        let encrypted = try Data(contentsOf: vaultFile(directory, wallet.id))
        try await store.renameWallet(walletID: wallet.id, name: "Renamed public fixture")
        #expect(store.walletLabel(for: wallet.id) == "Renamed public fixture")
        #expect(store.fingerprint(for: wallet.id) == fingerprint)
        #expect(try Data(contentsOf: vaultFile(directory, wallet.id)) == encrypted)
        do {
            _ = try await store.createWallet(name: "Duplicate", mnemonic: phrase, passphrase: "", password: password)
            Issue.record("The same effective seed must not create a duplicate wallet.")
        } catch let error as AppIssue {
            #expect(error.localizedDescription.contains("already belong"))
        }
        #expect(store.wallets.count == 1)
        let other = try await store.createWallet(name: "Different public passphrase", mnemonic: phrase,
                                                 passphrase: "Public alternate test wallet", password: password)
        #expect(store.publicMetadata(for: other.id)?.walletKeyId != key)
        #expect(store.wallets.count == 2)
        try await store.changePassword(walletID: wallet.id, current: password, new: "Changed-Password2")
        await store.reload()
        #expect(store.publicMetadata(for: wallet.id)?.walletKeyId == key)
        #expect(store.fingerprint(for: wallet.id) == fingerprint)
        #expect(store.fingerprint(for: other.id) != fingerprint, "A different passphrase gives a different fingerprint.")
        try await store.vault.verifyPassword(id: wallet.id, password: "Changed-Password2")
    }

    @Test func incompleteLegacyWalletDoesNotBlockImportAndDuplicatesAreFlaggedWhenCompleted() async throws {
        let (store, directory, original) = try await makeStore(complete: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.hasIncompleteWallets)
        let imported = try await store.createWallet(name: "Unknown legacy identity", mnemonic: phrase, passphrase: "", password: password)
        #expect(store.wallets.count == 2)
        #expect(store.metadataStatus(for: original.id) == .needsCompletion)
        try await store.prepare(request())
        let previouslyMatched = try #require(store.pendingTasks.first)
        #expect(previouslyMatched.walletID == imported.id)
        try await store.completeSetup(walletID: original.id, password: password)
        #expect(!store.hasIncompleteWallets)
        #expect(store.duplicateWalletIDs == [original.id, imported.id])
        #expect(store.plan == nil)
        #expect(store.matchingError == "Wallet information changed. Match this request again.")
        await #expect(throws: AppIssue.self) { try await store.sign(taskID: previouslyMatched.id, password: password) }
        try await store.retryMatching()
        #expect(store.plan == nil)
        #expect(store.matchingError != nil)
        #expect(store.wallets.count == 2)
    }

    @Test func publicBrowsingDoesNotSelectASignerAndEachSignatureNeedsItsPassword() async throws {
        let engine = ControlledSigningEngine()
        let (store, directory, wallet) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = try await store.createWallet(name: "Other public wallet", mnemonic: phrase,
                                                 passphrase: "Public alternate test wallet", password: "Other-Password2")
        let addresses = try await store.addresses(walletID: other.id, chain: .evm, profile: "standard", start: 8, count: 2)
        #expect(addresses.count == 2)
        #expect(addresses.first?.path == "m/44'/60'/0'/0/8")
        try await store.prepare(request())
        let task = try #require(store.pendingTasks.first)
        #expect(task.walletID == wallet.id)
        #expect(task.addresses.contains(signer))
        await #expect(throws: VaultError.authenticationFailed) { try await store.sign(taskID: task.id, password: "Other-Password2") }
        #expect(!store.hasSignedResponse)
        let failedCalls = await engine.invocationCount("signPlanTask")
        #expect(failedCalls == 0)
        try await store.sign(taskID: task.id, password: password)
        #expect(store.hasSignedResponse)
        #expect(store.completedTaskIDs == [task.id])
        #expect(store.signatureFrames.first?.lowercased().hasPrefix("ur:eth-signature/") == true)
        // The result card shows what the QR carries, decoded back from its frames.
        let signed = try #require(store.signaturePayload)
        #expect(signed.title == "Payload (JSON)" && signed.summary.hasPrefix("ur:eth-signature · CBOR · "))
        #expect(signed.text.contains("\"signature\"") && signed.text.contains("\"request-id\""))
        #expect(store.receipts.count == 1)
        #expect(store.receipts.first?.masterFingerprint == "73c5da0a", "Activity shows the same fingerprint as the wallet card.")
        try await store.prepare(request(nonce: 1))
        #expect(store.signaturePayload == nil, "A new request clears the previous result's payload.")
        let next = try #require(store.pendingTasks.first)
        await #expect(throws: VaultError.authenticationFailed) { try await store.sign(taskID: next.id, password: "") }
        #expect(!store.hasSignedResponse)
        try await store.sign(taskID: next.id, password: password)
        #expect(store.receipts.count == 2)
        let journal = try String(contentsOf: directory.appendingPathComponent("receipts.json"), encoding: .utf8)
        #expect(!journal.contains("abandon"))
        #expect(!journal.contains(password))
    }

    @Test func missingAndConflictingSelectorsNeverProduceAnAuthorizableTask() async throws {
        let (store, directory, _) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var missing = request()
        missing.removeValue(forKey: "address"); missing.removeValue(forKey: "masterFingerprint")
        try await store.prepare(missing)
        #expect(store.review != nil)
        #expect(store.plan == nil)
        #expect(store.matchingError != nil)
        await #expect(throws: AppIssue.self) { try await store.sign(taskID: "unmatched", password: password) }
        var conflicting = request()
        conflicting["address"] = "0x1111111111111111111111111111111111111111"
        try await store.prepare(conflicting)
        #expect(store.plan == nil)
        #expect(store.matchingError != nil)
        #expect(!store.hasSignedResponse)
    }

    @Test func stalePublicCacheCannotAuthorizeADifferentEncryptedSeed() async throws {
        let (store, directory, wallet) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SigningEngine()
        let different = try WalletPublicMetadata(await engine.run(operation: "derivePublicIndex", parameters: ["mnemonic": phrase, "passphrase": "Public alternate test wallet"]))
        try await store.publicRepository.save(different, walletID: wallet.id, key: publicDataKey(store))
        await store.reload()
        let address = try #require((different.raw["evmDefaultAddress"] as? [String: Any])?["address"] as? String)
        var otherRequest = request()
        otherRequest["address"] = address; otherRequest["masterFingerprint"] = different.masterFingerprint
        try await store.prepare(otherRequest)
        let task = try #require(store.pendingTasks.first)
        await #expect(throws: SigningEngineError.self) { try await store.sign(taskID: task.id, password: password) }
        #expect(!store.hasSignedResponse)
        #expect(store.receipts.isEmpty)
        try await store.completeSetup(walletID: wallet.id, password: password)
        #expect(store.publicMetadata(for: wallet.id)?.masterFingerprint == "73c5da0a")
    }

    @Test func backgroundCancelsInFlightTaskWithoutLosingTheReviewedRequest() async throws {
        let engine = ControlledSigningEngine()
        let (store, directory, _) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.prepare(request())
        let task = try #require(store.pendingTasks.first)
        let commitment = store.review?.requestHash
        let gate = await engine.holdNext("signPlanTask")
        let signing = Task { try await store.sign(taskID: task.id, password: password) }
        await gate.waitUntilStarted()
        store.suspend()
        await gate.release()
        do { try await signing.value; Issue.record("A backgrounded authorization must be discarded.") }
        catch is CancellationError {}
        #expect(!store.hasSignedResponse)
        #expect(store.completedTaskIDs.isEmpty)
        #expect(store.receipts.isEmpty)
        #expect(store.review?.requestHash == commitment)
        #expect(!store.busy)
        try await store.sign(taskID: task.id, password: password)
        #expect(store.hasSignedResponse)
    }

    @Test func replacingOrRejectingARequestDiscardsLateResults() async throws {
        let engine = ControlledSigningEngine()
        let (store, directory, _) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await engine.holdNext("resolveSigningPlan")
        let resolving = Task { try await store.prepare(request()) }
        await gate.waitUntilStarted()
        store.clearRequest()
        await gate.release()
        do { try await resolving.value; Issue.record("Rejected matching work must stay cancelled.") }
        catch is CancellationError {}
        #expect(store.plan == nil)
        #expect(store.review == nil)
        try await store.prepare(request())
        let task = try #require(store.pendingTasks.first)
        let signingGate = await engine.holdNext("signPlanTask")
        let signing = Task { try await store.sign(taskID: task.id, password: password) }
        await signingGate.waitUntilStarted()
        try await store.prepare(request(nonce: 2))
        let current = store.review?.requestHash
        await signingGate.release()
        do { try await signing.value; Issue.record("Replaced requests must not publish signatures.") }
        catch is CancellationError {}
        #expect(store.review?.requestHash == current)
        #expect(!store.hasSignedResponse)
        #expect(store.receipts.isEmpty)
    }

    @Test func interruptedMatchingCanRetryTheFrozenRequestWithoutAuthorization() async throws {
        let engine = ControlledSigningEngine()
        let (store, directory, _) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await engine.holdNext("resolveSigningPlan")
        let resolving = Task { try await store.prepare(request()) }
        await gate.waitUntilStarted()
        let hash = try #require(store.review?.requestHash)
        #expect(store.plan == nil)
        store.suspend()
        #expect(store.matchingError == "Matching interrupted. Try again.")
        await gate.release()
        do { try await resolving.value; Issue.record("Interrupted matching must discard its old result.") }
        catch is CancellationError {}
        try await store.retryMatching()
        #expect(store.review?.requestHash == hash)
        #expect(store.plan?.requestHash == hash)
        #expect(store.pendingTasks.count == 1)
        #expect(store.matchingError == nil)
        #expect(store.completedTaskIDs.isEmpty)
        #expect(!store.hasSignedResponse)
        let signingCalls = await engine.invocationCount("signPlanTask")
        #expect(signingCalls == 0)
        await #expect(throws: AppIssue.self) { try await store.retryMatching() }
    }

    @Test func publicCollectionChangesCancelInFlightSignaturesAndLateMatches() async throws {
        let engine = ControlledSigningEngine()
        let (store, directory, wallet) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try #require(store.publicMetadata(for: wallet.id))
        try await store.prepare(request())
        let task = try #require(store.pendingTasks.first)
        let hash = store.review?.requestHash
        let gate = await engine.holdNext("signPlanTask")
        let signing = Task { try await store.sign(taskID: task.id, password: password) }
        await gate.waitUntilStarted()
        try await store.publicRepository.remove(walletID: wallet.id)
        await store.reload()
        #expect(store.plan == nil)
        #expect(store.review?.requestHash == hash)
        #expect(store.matchingError == "Wallet information changed. Match this request again.")
        await gate.release()
        do { try await signing.value; Issue.record("Changed public metadata must invalidate an in-flight signature.") }
        catch is CancellationError {}
        #expect(!store.hasSignedResponse)
        #expect(store.completedTaskIDs.isEmpty)
        #expect(store.receipts.isEmpty)

        try await store.publicRepository.save(metadata, walletID: wallet.id, key: publicDataKey(store))
        await store.reload()
        let matchingGate = await engine.holdNext("resolveSigningPlan")
        let matching = Task { try await store.retryMatching() }
        await matchingGate.waitUntilStarted()
        try await store.publicRepository.remove(walletID: wallet.id)
        await store.reload()
        await matchingGate.release()
        try await matching.value
        #expect(store.plan == nil)
        #expect(store.matchingError == "Wallet information changed. Match this request again.")
        #expect(store.review?.requestHash == hash)
    }

    @Test func fixedMultiWalletTasksRequireSeparatePasswordsAndPublishOnlyWhenComplete() async throws {
        // The controlled plan tests Swift orchestration; chain-specific multi-
        // signer byte preservation and cryptographic checks live in engine tests.
        let engine = ControlledSigningEngine()
        let (store, directory, wallet) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = try await store.createWallet(name: "Second fixed task", mnemonic: phrase,
                                                 passphrase: "Public alternate test wallet", password: "Other-Password2")
        let tasks = try [wallet.id, other.id].enumerated().map { offset, id -> [String: Any] in
            let metadata = try #require(store.publicMetadata(for: id))
            let key = try #require(metadata.raw["evmDefaultAddress"] as? [String: Any])
            return ["id": "task-\(offset)", "localWalletId": id.uuidString, "walletKeyId": metadata.walletKeyId,
                    "chain": "evm", "paths": [key["path"]!], "publicKeys": [key["publicKey"]!], "addresses": [key["address"]!]]
        }
        await engine.useOrchestrationTasks(tasks)
        try await store.prepare(request())
        await #expect(throws: AppIssue.self) { try await store.sign(taskID: "task-1", password: "Other-Password2") }
        try await store.sign(taskID: "task-0", password: password)
        #expect(!store.hasSignedResponse)
        #expect(store.pendingTasks.map(\.id) == ["task-1"])
        let originalPlanHash = store.plan?.planHash
        try await store.renameWallet(walletID: other.id, name: "Rename does not change matching")
        #expect(store.plan?.planHash == originalPlanHash)
        #expect(store.completedTaskIDs == ["task-0"])
        await #expect(throws: VaultError.authenticationFailed) { try await store.sign(taskID: "task-1", password: password) }
        #expect(store.completedTaskIDs == ["task-0"])

        let publicIndex = try #require(store.publicMetadata(for: other.id))
        try await store.publicRepository.remove(walletID: other.id)
        await store.reload()
        #expect(store.plan == nil)
        #expect(store.completedTaskIDs.isEmpty)
        #expect(!store.hasSignedResponse)
        #expect(store.matchingError == "Wallet information changed. Match this request again.")
        try await store.publicRepository.save(publicIndex, walletID: other.id, key: publicDataKey(store))
        await store.reload()
        try await store.retryMatching()
        #expect(store.pendingTasks.map(\.id) == ["task-0", "task-1"])
        await #expect(throws: AppIssue.self) { try await store.sign(taskID: "task-1", password: "Other-Password2") }
        try await store.sign(taskID: "task-0", password: password)
        try await store.sign(taskID: "task-1", password: "Other-Password2")
        #expect(store.hasSignedResponse)
        #expect(store.pendingTasks.isEmpty)
        #expect(store.receipts.count == 3)
        #expect(store.receipts.map(\.walletID) == [other.id, wallet.id, wallet.id])
    }

    @Test func interruptedCreationDoesNotLeaveAnEncryptedOrPublicWallet() async throws {
        let engine = ControlledSigningEngine()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WalletVault(directory: directory.appendingPathComponent("Vaults"), deviceKeys: SessionDeviceKeys())
        let store = AppStore(vault: vault, engine: engine, storageDirectory: directory)
        await store.reload()
        let gate = await engine.holdNext("derivePublicIndex")
        let creation = Task { try await store.createWallet(name: "Cancelled fixture", mnemonic: phrase, passphrase: "", password: password) }
        await gate.waitUntilStarted(); store.suspend(); await gate.release()
        do { _ = try await creation.value; Issue.record("Suspension before persistence must cancel creation.") }
        catch is CancellationError {}
        let records = try await vault.list()
        #expect(records.isEmpty)
        #expect(store.wallets.isEmpty)
    }

    private func request(nonce: Int = 0) -> [String: Any] {
        ["chain": "evm", "kind": "transaction", "path": "m/44'/60'/0'/0/0", "address": signer, "masterFingerprint": "73c5da0a",
         // Synthetic direct-engine fixture with a standard response profile.
         // Actual CBOR/UR payload binding is covered by protocol integration tests.
         "transport": ["type": "eth-sign-request", "requestId": "00112233-4455-6677-8899-aabbccddeeff"],
         "transaction": ["type": 2, "chainId": "1", "nonce": nonce, "gasLimit": "21000", "maxFeePerGas": "2000000000",
                         "maxPriorityFeePerGas": "1000000000", "to": "0x1111111111111111111111111111111111111111", "value": "1", "data": "0x"]]
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-session-\(UUID())") }
    @Test func connectOpeningQRIsPreparedOnlyWhileAllowedAndClearedOnSuspend() async throws {
        let engine = ControlledSigningEngine()
        let (store, directory, wallet) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.sleep(for: .milliseconds(900))
        #expect(store.preparedConnect(walletID: wallet.id) == nil, "Nothing is prepared until RootView allows it.")
        #expect(await engine.invocationCount("createWalletPairing") == 0)

        store.setConnectPrefetch(allowed: true)
        var prepared: AppStore.PreparedConnect?
        for _ in 0..<100 where prepared == nil {
            try await Task.sleep(for: .milliseconds(50))
            prepared = store.preparedConnect(walletID: wallet.id)
        }
        let payload = try #require(prepared).payload
        // Connect opens on Wallet Level, so that is what is prepared.
        #expect(payload == (try await store.walletPairing(walletID: wallet.id)), "It is exactly Connect's opening QR.")
        #expect(payload.json.contains("\"protocol\" : \"bittool-signer-wallet\"") && !payload.json.contains("xprv"))
        let coin = try await store.pairing(walletID: wallet.id, chain: .bitcoin)
        let view = try #require(coin.payloadView, "Coin-level QR codes carry a payload view.")
        #expect(view.format == .json && view.summary.hasPrefix("ur:crypto-account · CBOR · "))
        #expect(view.text.contains("\"master-fingerprint\" : 1942346250") && view.text.contains("witness-public-key-hash"))
        #expect(!view.text.contains("xprv") && !view.text.contains("\"is-private\" : true"))
        let address = try await store.pairing(walletID: wallet.id, chain: .tron, profile: "standard", outputMode: "address", index: 3)
        #expect(address.payloadView?.format == .text && address.payloadView?.text == address.address)
        #expect(prepared?.images.count == payload.frames.count, "The QR images are rendered ahead too.")

        store.suspend()
        #expect(store.preparedConnect(walletID: wallet.id) == nil)
        store.setConnectPrefetch(allowed: false)
    }

    @Test func aPreparedQRThatOutlivesASuspendIsDiscarded() async throws {
        let engine = ControlledSigningEngine()
        let (store, directory, wallet) = try await makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = await engine.holdNext("createWalletPairing")
        store.setConnectPrefetch(allowed: true)
        await gate.waitUntilStarted()
        store.suspend() // e.g. App Lock while the engine is still working
        await gate.release()
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.preparedConnect(walletID: wallet.id) == nil)
        store.setConnectPrefetch(allowed: false)
    }

    private func vaultFile(_ directory: URL, _ id: UUID) -> URL { directory.appendingPathComponent("Vaults/\(id.uuidString.lowercased()).bsvault") }
    private func publicDataKey(_ store: AppStore) async throws -> SymmetricKey {
        try #require(await store.vault.publicDataKey(createIfMissing: true))
    }

    private func makeStore(engine: any OfflineSigningEngine = ControlledSigningEngine(), complete: Bool = true) async throws -> (AppStore, URL, VaultMetadata) {
        let directory = temporaryDirectory()
        let vault = WalletVault(directory: directory.appendingPathComponent("Vaults"), deviceKeys: SessionDeviceKeys())
        let wallet = try await vault.create(name: "Public session fixture", mnemonic: phrase, password: password)
        let store = AppStore(vault: vault, engine: engine, storageDirectory: directory)
        await store.reload()
        if complete { try await store.completeSetup(walletID: wallet.id, password: password) }
        return (store, directory, wallet)
    }
}

private actor EngineGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; waiters.forEach { $0.resume() }; waiters = []
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor ControlledSigningEngine: OfflineSigningEngine {
    private let real = SigningEngine()
    private var pendingGate: (String, EngineGate)?
    private var invocations: [String: Int] = [:]
    private var orchestrationTasks: [[String: Any]]?
    func invocationCount(_ operation: String) -> Int { invocations[operation, default: 0] }
    func useOrchestrationTasks(_ tasks: [[String: Any]]) { orchestrationTasks = tasks }
    func holdNext(_ operation: String) -> EngineGate {
        let gate = EngineGate(); pendingGate = (operation, gate); return gate
    }
    func run(operation: String, parameters: [String: Any]) async throws -> [String: Any] {
        invocations[operation, default: 0] += 1
        if let (expected, gate) = pendingGate, expected == operation {
            pendingGate = nil; await gate.pause()
        }
        if let tasks = orchestrationTasks {
            if operation == "resolveSigningPlan" {
                let reviewed = try await real.run(operation: "review", parameters: ["request": parameters["request"] ?? [:]])
                return ["status": "ready", "requestHash": reviewed["requestHash"] ?? "", "planHash": String(repeating: "a", count: 64), "tasks": tasks]
            }
            if operation == "signPlanTask" {
                let plan = parameters["plan"] as? [String: Any] ?? [:]
                return ["requestHash": plan["requestHash"] ?? "", "planHash": plan["planHash"] ?? "",
                        "taskId": parameters["taskId"] ?? "", "signature": "public-orchestration-fixture"]
            }
            if operation == "encodeResponse" {
                return ["frames": ["public-orchestration-result"], "text": "public-orchestration-result"]
            }
        }
        return try await real.run(operation: operation, parameters: parameters)
    }
}

final class SessionDeviceKeys: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    func create(id: UUID, key: Data) throws { lock.lock(); defer { lock.unlock() }; keys[id] = key }
    func read(id: UUID) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = keys[id] else { throw VaultError.deviceKeyUnavailable }
        return value
    }
    func delete(id: UUID) throws { lock.lock(); defer { lock.unlock() }; keys[id] = nil }
}
