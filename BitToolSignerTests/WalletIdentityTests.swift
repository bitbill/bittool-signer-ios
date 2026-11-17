import Foundation
import CryptoKit
import Testing
@testable import BitToolSigner

/// The KH v2 wallet-identity signature: what a v2 wallet-level pairing code
/// carries, how it is stored, and what happens to a wallet saved before 1.1.0.
/// Public BIP39 fixtures only (docs/kh2_bittool_vectors.json).
@MainActor
struct WalletIdentityTests {
    private let password = "Identity-Password1"
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    /// The published vector for this phrase at m/44'/0'/0'/0/1000000000, epoch 1.
    private let publishedSignature = "IDbq1RPzOmq1q37JrcXcPBa9vVjrpG0B+9/ltJXQjfWlDGoP/gwHDMeGFH5XdL693wnhbeAsBdfRj7x70s94Lm4="
    private let publishedKh2 = "4fb494ddc6dac144c283c3a24f92156937c855a1b2e3997981ef510465d948fc"
    private let publishedAddress = "1N8ju3BdMHttCNBJ4d8v3eCrpzdLk1m9Vo"

    // MARK: - The stored value

    @Test func onlyA65ByteBase64SignatureIsAccepted() throws {
        let valid = try #require(WalletIdentitySignature(epoch: 1, signature: publishedSignature))
        #expect(valid.epoch == 1)
        #expect(valid.signature == publishedSignature)
        #expect(valid.raw as NSDictionary == ["epoch": 1, "signature": publishedSignature] as NSDictionary)
        // A damaged or truncated sidecar reads as "not signed yet", never as a signature.
        for bad: Any? in [nil, "", "not base64", String(publishedSignature.dropLast()),
                          publishedSignature + "A", Data(count: 64).base64EncodedString(),
                          Data(count: 66).base64EncodedString(), 5] {
            #expect(WalletIdentitySignature(epoch: 1, signature: bad) == nil, "\(String(describing: bad))")
        }
        for epoch: Any? in [nil, 0, -1, 1_000_001, "1", 1.5] {
            #expect(WalletIdentitySignature(epoch: epoch, signature: publishedSignature) == nil, "\(String(describing: epoch))")
        }
    }

    // MARK: - The engine operation

    @Test func theEngineReproducesThePublishedVectorAndSignsNothingElse() async throws {
        let engine = SigningEngine()
        let seed = try BIP39Seed.hex(mnemonic: phrase, passphrase: "")
        let result = try await engine.run(operation: "signKhV2", parameters: ["seed": seed, "epoch": 1])
        #expect(result["signature"] as? String == publishedSignature)
        #expect(result["kh2"] as? String == publishedKh2)
        #expect(result["address"] as? String == publishedAddress)
        #expect(result["path"] as? String == "m/44'/0'/0'/0/1000000000")
        #expect(result["message"] as? String == "OwnbitAuth:v2:epoch=1")
        // Nothing in the call can redirect the key or the text that gets signed.
        let redirected = try await engine.run(operation: "signKhV2",
                                              parameters: ["seed": seed, "epoch": 1, "path": "m/44'/0'/0'/0/0",
                                                           "message": "send everything"])
        #expect(redirected["signature"] as? String == publishedSignature)
        #expect(redirected["message"] as? String == "OwnbitAuth:v2:epoch=1")
    }

    // MARK: - A wallet created on 1.1.0

    @Test func aNewWalletSignsItsIdentityAtCreationAndNeverAsksAgain() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _, _) = try store(in: directory)
        let wallet = try await store.createWallet(name: "Signed at creation", mnemonic: phrase,
                                                 passphrase: "", password: password)
        #expect(store.hasWalletIdentity(wallet.id))
        #expect(store.walletIdentities[wallet.id] == WalletIdentitySignature(epoch: 1, signature: publishedSignature))
        // The pairing code is version 2 and carries that signature.
        let pairing = try await store.walletPairing(walletID: wallet.id)
        #expect(pairing.json.contains("\"version\" : 2"))
        #expect(pairing.json.contains(publishedSignature))
        #expect(pairing.json.contains("\"khEpoch\" : 1"))
        #expect(pairing.frames.count >= 2)
        // The identity is not offered as a receive address.
        #expect(!pairing.firstAddresses.contains { $0.address == publishedAddress })
        // It survives a reload: the signature is stored, not recomputed per call.
        await store.reload()
        #expect(store.hasWalletIdentity(wallet.id))
    }

    // MARK: - A wallet saved before 1.1.0

    @Test func anOlderWalletHasNoCodeUntilItsPasswordIsEnteredOnce() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault, repository, wallet, indexBefore) = try await preUpgradeWallet(in: directory)

        // Ready to pair at coin level, but no wallet-level code yet.
        #expect(store.metadataStatus(for: wallet.id) == .ready)
        #expect(!store.hasWalletIdentity(wallet.id))
        await #expect(throws: (any Error).self) { try await store.walletPairing(walletID: wallet.id) }

        // A wrong password changes nothing.
        await #expect(throws: (any Error).self) {
            try await store.authorizeWalletIdentity(walletID: wallet.id, password: "Wrong-Password1")
        }
        #expect(!store.hasWalletIdentity(wallet.id))

        // The right password signs the identity once, and the code appears.
        try await store.authorizeWalletIdentity(walletID: wallet.id, password: password)
        #expect(store.walletIdentities[wallet.id]?.signature == publishedSignature)
        let pairing = try await store.walletPairing(walletID: wallet.id)
        #expect(pairing.json.contains(publishedSignature))

        // Only the signature was added: the stored public index is unchanged.
        let key = try #require(try await vault.publicDataKey(createIfMissing: false))
        let snapshot = await repository.snapshot(walletID: wallet.id, key: key)
        #expect(snapshot.identity?.signature == publishedSignature)
        #expect(snapshot.metadata?.walletKeyId == store.publicMetadata(for: wallet.id)?.walletKeyId)
        #expect(snapshot.metadata?.jsonData == indexBefore)
    }

    @Test func rebuildingThePublicIndexSignsTheIdentityInTheSamePass() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _, _, wallet, _) = try await preUpgradeWallet(in: directory)
        #expect(!store.hasWalletIdentity(wallet.id))
        // Repair asks for the password and already derives from the seed, so it
        // fills the signature in rather than leaving a second prompt behind.
        try await store.completeSetup(walletID: wallet.id, password: password)
        #expect(store.walletIdentities[wallet.id]?.signature == publishedSignature)
    }

    @Test func aStoredSignatureNeverOutlivesTheKeysItWasCheckedAgainst() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault, repository) = try store(in: directory)
        let wallet = try await store.createWallet(name: "Signed at creation", mnemonic: phrase,
                                                  passphrase: "", password: password)
        #expect(store.hasWalletIdentity(wallet.id))
        let key = try #require(try await vault.publicDataKey(createIfMissing: false))
        let index = try #require(store.publicMetadata(for: wallet.id))
        // Writing the index without a signature drops the stored one, because the
        // two come from the same seed and must not disagree.
        try await repository.save(index, walletID: wallet.id, key: key)
        #expect(await repository.snapshot(walletID: wallet.id, key: key).identity == nil)
        // A signature cannot be filed for a wallet that has no public index.
        await #expect(throws: (any Error).self) {
            try await repository.saveIdentity(try #require(WalletIdentitySignature(epoch: 1, signature: publishedSignature)),
                                              walletID: UUID(), key: key)
        }
    }

    // MARK: - Helpers

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bittool-signer-identity-\(UUID())")
    }

    private func store(in directory: URL) throws -> (AppStore, WalletVault, PublicWalletRepository) {
        let vault = WalletVault(directory: directory.appendingPathComponent("Vaults"), deviceKeys: SessionDeviceKeys())
        let repository = PublicWalletRepository(directory: directory.appendingPathComponent("PublicWallets"))
        return (AppStore(vault: vault, engine: SigningEngine(), publicRepository: repository, storageDirectory: directory),
                vault, repository)
    }

    /// A wallet whose sidecar holds a public index and no identity signature —
    /// exactly what BitTool Signer 1.0.0 wrote. Returns the stored index bytes so
    /// a later assertion can show they were not rewritten.
    private func preUpgradeWallet(in directory: URL) async throws
    -> (AppStore, WalletVault, PublicWalletRepository, VaultMetadata, Data) {
        let (store, vault, repository) = try store(in: directory)
        let wallet = try await vault.create(name: "Saved by 1.0.0", mnemonic: phrase, password: password)
        await store.reload()
        let raw = try await SigningEngine().run(operation: "derivePublicIndex",
                                                parameters: ["seed": try BIP39Seed.hex(mnemonic: phrase, passphrase: "")])
        let index = try WalletPublicMetadata(raw)
        let key = try #require(try await vault.publicDataKey(createIfMissing: true))
        try await repository.save(index, walletID: wallet.id, displayName: "Saved by 1.0.0", key: key)
        await store.reload()
        return (store, vault, repository, wallet, index.jsonData)
    }
}
