import Foundation
import Combine
import UIKit

protocol OfflineSigningEngine: Sendable {
    func run(operation: String, parameters: [String: Any]) async throws -> [String: Any]
    func releaseWarmContext() async
}
extension OfflineSigningEngine {
    func releaseWarmContext() async {}
}
extension SigningEngine: OfflineSigningEngine {}

/// Wallet identity and page routes are explicit. This store has no active wallet,
/// unlocked wallet, reusable signing authorization, or retained clear secret.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var wallets: [VaultMetadata] = []
    @Published private(set) var isLoading = true
    @Published private(set) var walletLoadSucceeded = false
    @Published private(set) var publicWallets: [UUID: WalletPublicMetadata] = [:]
    @Published private(set) var metadataStatuses: [UUID: PublicMetadataStatus] = [:]
    @Published private(set) var duplicateWalletIDs: Set<UUID> = []
    @Published private(set) var review: TransactionReview?
    @Published private(set) var plan: SigningPlan?
    @Published private(set) var matchingError: String?
    @Published private(set) var completedTaskIDs: Set<String> = []
    @Published private(set) var signatureFrames: [String] = []
    @Published private(set) var signatureText = ""
    /// What the signature QR carries, decoded back from its frames by the engine.
    @Published private(set) var signaturePayload: QRPayloadView?
    @Published private(set) var receipts: [SigningReceipt] = []
    @Published private(set) var busy = false
    @Published private(set) var securityEpoch = UUID()
    @Published private(set) var navigationResetEpoch = UUID()
    @Published var error: String?
    let vault: WalletVault
    let engine: any OfflineSigningEngine
    let publicRepository: PublicWalletRepository
    private let receiptURL: URL
    private var sensitiveEpoch = UUID()
    private var requestEpoch = UUID()
    private var reloadEpoch = UUID()
    private var hasStartedReload = false
    private var signingOperation: UUID?
    private var pendingRequestData: Data?
    private var previousResultData: Data?
    private var creatingWallet = false
    private struct WalletCollectionSnapshot: Equatable {
        let walletIDs: Set<UUID>
        let indexes: [UUID: Data]
    }
    private var planWalletSnapshot: WalletCollectionSnapshot?
    /// Connect's opening QR for each wallet, prepared after the wallets load so the
    /// first push into Connect has no engine, CoreImage or layout work left to do.
    /// Public data only, in memory; cleared by suspend() and when wallets reload.
    private var connectPrefetch: [UUID: PreparedConnect] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchAllowed = false
    private var walletCollectionSnapshot: WalletCollectionSnapshot {
        WalletCollectionSnapshot(walletIDs: Set(wallets.map(\.id)), indexes: publicWallets.mapValues(\.jsonData))
    }
    var hasSignedResponse: Bool { !signatureFrames.isEmpty || !signatureText.isEmpty }
    var pendingTasks: [SigningTask] { plan?.tasks.filter { !completedTaskIDs.contains($0.id) } ?? [] }
    var hasIncompleteWallets: Bool { wallets.contains { publicWallets[$0.id] == nil } }

    init(vault: WalletVault = WalletVault(), engine: any OfflineSigningEngine = SigningEngine(),
         publicRepository: PublicWalletRepository? = nil, storageDirectory: URL? = nil) {
        self.vault = vault; self.engine = engine
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = storageDirectory ?? support.appendingPathComponent("BitToolSigner", isDirectory: true)
        receiptURL = directory.appendingPathComponent("receipts.json")
        self.publicRepository = publicRepository ?? PublicWalletRepository(directory: directory.appendingPathComponent("PublicWallets"))
        Task {
            // An explicit reload immediately after initialization must not be
            // superseded by this later-scheduled bootstrap load.
            if !hasStartedReload { await reload() }
        }
    }

    // Recovery views use these epochs to discard late secret results.
    // There is deliberately no foreground idle timer or wallet-unlock lifetime.
    func beginSensitiveSession() { sensitiveEpoch = UUID() }
    func endSensitiveSession() { sensitiveEpoch = UUID() }
    func suspend() {
        securityEpoch = UUID(); sensitiveEpoch = UUID(); requestEpoch = UUID()
        signingOperation = nil; busy = false
        clearConnectPrefetch()
        Task { [engine] in await engine.releaseWarmContext() }
        if review != nil, plan == nil, matchingError == nil {
            matchingError = "Matching interrupted. Try again."
        }
    }
    func clearRequest() {
        requestEpoch = UUID(); signingOperation = nil; busy = false
        review = nil; plan = nil; matchingError = nil; completedTaskIDs = []
        planWalletSnapshot = nil
        pendingRequestData = nil; previousResultData = nil; signatureFrames = []; signatureText = ""; signaturePayload = nil
    }
    private func invalidateMatching() {
        // A fixed plan cannot silently acquire or drop wallets. Clear every
        // partial signature and require public rematching plus fresh passwords.
        suspend()
        plan = nil; planWalletSnapshot = nil; completedTaskIDs = []
        previousResultData = nil; signatureFrames = []; signatureText = ""; signaturePayload = nil
        matchingError = "Wallet information changed. Match this request again."
    }
    private func requireSession(_ epoch: UUID, requestID: UUID? = nil) throws {
        try Task.checkCancellation()
        guard epoch == securityEpoch, requestID == nil || requestID == requestEpoch else { throw CancellationError() }
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppIssue.message(String(localized: "Invalid local document.", bundle: AppText.bundle)) }
        return value
    }
    private func frozen(_ raw: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(raw) else { throw AppIssue.message(String(localized: "Invalid request format.", bundle: AppText.bundle)) }
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        guard data.count <= 1_048_576 else { throw AppIssue.message(String(localized: "Request exceeds the supported size.", bundle: AppText.bundle)) }
        return data
    }
    func reload() async {
        hasStartedReload = true
        let loading = UUID(); reloadEpoch = loading
        do {
            let originals = try await vault.list()
            var displayed: [VaultMetadata] = [], indexes: [UUID: WalletPublicMetadata] = [:]
            var statuses: [UUID: PublicMetadataStatus] = [:]
            let key = originals.isEmpty ? nil : try? await vault.publicDataKey(createIfMissing: false)
            for wallet in originals {
                let snapshot = await publicRepository.snapshot(walletID: wallet.id, key: key)
                displayed.append(VaultMetadata(id: wallet.id, name: snapshot.displayName ?? wallet.name, createdAt: wallet.createdAt))
                indexes[wallet.id] = snapshot.metadata; statuses[wallet.id] = snapshot.status
            }
            guard loading == reloadEpoch else { return }
            wallets = displayed; publicWallets = indexes; metadataStatuses = statuses
            clearConnectPrefetch(); scheduleConnectPrefetch()
            walletLoadSucceeded = true
            let grouped = Dictionary(grouping: indexes.keys, by: { indexes[$0]?.walletKeyId ?? "" })
            duplicateWalletIDs = Set(grouped.values.filter { $0.count > 1 }.flatMap { $0 })
            if plan != nil, !hasSignedResponse, planWalletSnapshot != walletCollectionSnapshot {
                invalidateMatching()
            }
            loadReceipts()
        } catch { if loading == reloadEpoch { walletLoadSucceeded = false; self.error = error.localizedDescription } }
        if loading == reloadEpoch { isLoading = false }
    }
    func publicMetadata(for id: UUID) -> WalletPublicMetadata? { publicWallets[id] }
    func metadataStatus(for id: UUID) -> PublicMetadataStatus { metadataStatuses[id] ?? .needsCompletion }
    func walletLabel(for id: UUID) -> String { wallets.first { $0.id == id }?.name ?? "Wallet" }
    /// Stable seed for the wallet's identity color; never used for signing decisions.
    func avatarIdentity(for id: UUID) -> String { publicWallets[id]?.walletKeyId ?? id.uuidString }
    func wallet(_ id: UUID) -> VaultMetadata? { wallets.first { $0.id == id } }
    /// The wallet's BIP32 master fingerprint as people see it (and as pairing QR
    /// codes export it). Display only: signing never relies on it.
    func fingerprint(for id: UUID) -> String {
        publicWallets[id]?.masterFingerprint.uppercased() ?? "Setup required"
    }
    func generateMnemonic(wordCount: Int) async throws -> String {
        let epoch = securityEpoch, sensitive = sensitiveEpoch
        try Task.checkCancellation()
        let result = try await engine.run(operation: "mnemonic", parameters: ["entropy": SecureRandom.entropyHex(wordCount: wordCount)])
        try requireSession(epoch)
        guard sensitive == sensitiveEpoch else { throw CancellationError() }
        guard let words = result["mnemonic"] as? String ?? result["value"] as? String else { throw AppIssue.message(String(localized: "Unable to generate recovery phrase.", bundle: AppText.bundle)) }
        return words
    }
    /// Validates a canonical phrase (generated, or already chosen on import) in
    /// any of the ten BIP39 languages, including its checksum.
    @discardableResult
    func validateMnemonic(_ phrase: String) async throws -> BIP39Mnemonic.Canonical {
        try Task.checkCancellation()
        return try BIP39Mnemonic.validatedCanonical(phrase)
    }

    @discardableResult
    func createWallet(name: String, mnemonic: String, passphrase: String, password: String) async throws -> VaultMetadata {
        guard !creatingWallet else { throw AppIssue.message(String(localized: "A wallet is already being saved.", bundle: AppText.bundle)) }
        creatingWallet = true; defer { creatingWallet = false }
        let epoch = securityEpoch
        guard passphrase.utf8.count <= 1024 else { throw AppIssue.message(String(localized: "The BIP39 passphrase exceeds 1,024 UTF-8 bytes.", bundle: AppText.bundle)) }
        // The vault always stores the canonical words the seed is derived from.
        let mnemonic = try await validateMnemonic(mnemonic).phrase
        let raw = try await engine.run(operation: "derivePublicIndex", parameters: ["seed": try BIP39Seed.hex(mnemonic: mnemonic, passphrase: passphrase)])
        try requireSession(epoch)
        let index = try WalletPublicMetadata(raw)
        await reload()
        try requireSession(epoch)
        guard walletLoadSucceeded else { throw AppIssue.message(String(localized: "The existing wallet collection could not be read. Retry before adding a wallet.", bundle: AppText.bundle)) }
        guard !publicWallets.values.contains(where: { $0.walletKeyId == index.walletKeyId }) else {
            throw AppIssue.message(String(localized: "This recovery phrase and passphrase already belong to an existing wallet.", bundle: AppText.bundle))
        }
        // Prepare the public sidecar first. It is invisible without a committed
        // vault. A crash cannot leave a visible new wallet with missing setup.
        let id = UUID()
        guard let key = try await vault.publicDataKey(createIfMissing: true) else { throw VaultError.deviceKeyUnavailable }
        try await publicRepository.save(index, walletID: id, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines), key: key)
        let metadata: VaultMetadata
        do {
            try requireSession(epoch)
            metadata = try await vault.create(name: name, mnemonic: mnemonic, passphrase: passphrase, password: password, id: id)
        } catch {
            try? await publicRepository.remove(walletID: id)
            throw error
        }
        // Persistence is the success boundary. A background transition during
        // the commit must not invite a second import of the same wallet.
        await reload()
        return metadata
    }

    func completeSetup(walletID: UUID, password: String) async throws {
        guard wallets.contains(where: { $0.id == walletID }) else { throw VaultError.walletNotFound }
        let epoch = securityEpoch, sensitive = sensitiveEpoch
        let raw = try await authenticatedPublicIndex(walletID: walletID, password: password, epoch: epoch)
        try requireSession(epoch)
        guard sensitive == sensitiveEpoch else { throw CancellationError() }
        let index = try WalletPublicMetadata(raw)
        // Password authorization may repair an inconsistent public cache. The
        // encrypted wallet, never the old cache, is the identity authority.
        guard let key = try await vault.publicDataKey(createIfMissing: true) else { throw VaultError.deviceKeyUnavailable }
        try await publicRepository.save(index, walletID: walletID, displayName: walletLabel(for: walletID), key: key)
        await reload()
        // Existing duplicate encrypted records are preserved and reported; the
        // resolver rejects an ambiguous identity instead of deleting user data.
    }

    private func authenticatedPublicIndex(walletID: UUID, password: String, epoch: UUID) async throws -> [String: Any] {
        let secret = try await vault.unlock(id: walletID, password: password)
        try requireSession(epoch)
        return try await engine.run(operation: "derivePublicIndex", parameters: ["seed": try BIP39Seed.hex(mnemonic: secret.mnemonic, passphrase: secret.passphrase)])
    }

    func renameWallet(walletID: UUID, name: String) async throws {
        guard wallets.contains(where: { $0.id == walletID }) else { throw VaultError.walletNotFound }
        guard let key = try await vault.publicDataKey(createIfMissing: false) else {
            throw AppIssue.message(String(localized: "Repair this wallet before renaming it.", bundle: AppText.bundle))
        }
        try await publicRepository.rename(walletID: walletID, name: name, key: key)
        await reload()
    }
    func addresses(walletID: UUID, chain: Chain, profile: String = "native", start: Int = 0, count: Int = 20) async throws -> [PublicAccount] {
        guard let metadata = publicWallets[walletID] else { throw AppIssue.message(String(localized: "Wallet setup required.", bundle: AppText.bundle)) }
        let result = try await engine.run(operation: "derivePublicAddresses", parameters: ["publicIndex": metadata.raw, "chain": chain.rawValue, "profile": profile, "start": start, "count": count])
        guard let addresses = result["addresses"] as? [[String: Any]] else { throw AppIssue.message(String(localized: "Unable to derive public addresses.", bundle: AppText.bundle)) }
        return addresses.map(PublicAccount.init)
    }
    func pairing(walletID: UUID, chain: Chain, profile: String = "native", outputMode: String = "accountXpub", index: Int = 0) async throws -> PairingPayload {
        guard let metadata = publicWallets[walletID] else { throw AppIssue.message(String(localized: "Wallet setup required.", bundle: AppText.bundle)) }
        let result = try await engine.run(operation: "createPublicPairing", parameters: ["publicIndex": metadata.raw, "chain": chain.rawValue, "profile": profile, "outputMode": outputMode, "index": index])
        return try PairingPayload(result)
    }

    /// What Coin Level opens on once it is chosen: Bitcoin, Native SegWit, account xpub.
    nonisolated static let defaultConnectProfile = "native"
    nonisolated static let defaultConnectMode = "accountXpub"

    /// A wallet's opening Connect QR — the wallet-level one — with its images.
    struct PreparedConnect {
        let payload: WalletPairingPayload
        let images: [UIImage]
    }

    /// The prepared opening QR for `walletID`, if the prefetch has finished.
    func preparedConnect(walletID: UUID) -> PreparedConnect? { connectPrefetch[walletID] }

    /// RootView allows the prefetch only while the app is active, unlocked, not
    /// captured and showing wallets.
    func setConnectPrefetch(allowed: Bool) {
        prefetchAllowed = allowed
        if allowed { scheduleConnectPrefetch() } else { prefetchTask?.cancel(); prefetchTask = nil }
    }

    private func clearConnectPrefetch() {
        prefetchTask?.cancel(); prefetchTask = nil
        connectPrefetch = [:]
    }

    private func scheduleConnectPrefetch() {
        guard prefetchAllowed, walletLoadSucceeded else { return }
        prefetchTask?.cancel()
        prefetchTask = Task(priority: .utility) { [weak self] in
            // Let launch, unlock or the foreground transition finish first.
            try? await Task.sleep(for: .milliseconds(600))
            await self?.prefetchConnectPairings()
        }
    }

    private func prefetchConnectPairings() async {
        for wallet in wallets where connectPrefetch[wallet.id] == nil && metadataStatus(for: wallet.id) == .ready {
            guard !Task.isCancelled, let index = publicWallets[wallet.id]?.jsonData else { return }
            let epoch = securityEpoch
            guard let payload = try? await walletPairing(walletID: wallet.id) else { continue }
            let images = await QRRenderer.images(for: payload.frames, priority: .utility)
            // Discard a result that outlived a lock, background or wallet change.
            guard !Task.isCancelled, epoch == securityEpoch, publicWallets[wallet.id]?.jsonData == index,
                  images.count == payload.frames.count else { return }
            connectPrefetch[wallet.id] = PreparedConnect(payload: payload, images: images)
        }
    }

    /// One QR for all chain families (`bittool-signer-wallet` v1), public data only.
    /// BitTool Signer offers one wallet-level form: the account-level (`full`) payload.
    func walletPairing(walletID: UUID) async throws -> WalletPairingPayload {
        guard let metadata = publicWallets[walletID] else { throw AppIssue.message(String(localized: "Wallet setup required.", bundle: AppText.bundle)) }
        let result = try await engine.run(operation: "createWalletPairing", parameters: ["publicIndex": metadata.raw, "mode": "full"])
        return try WalletPairingPayload(result)
    }

    private var scanFrames: [String] = []
    private var incrementalScan = false

    /// Starts assembling one QR request. Real engines keep the parts in a
    /// dedicated context; other engines fall back to batch decoding.
    func beginScan() async throws {
        scanFrames = []
        if let incremental = engine as? IncrementalQREngine {
            try await incremental.beginScanSession(); incrementalScan = true
        } else { incrementalScan = false }
    }

    func endScan() async {
        scanFrames = []
        if incrementalScan, let incremental = engine as? IncrementalQREngine { await incremental.endScanSession() }
        incrementalScan = false
    }

    /// Adds one scanned frame; returns progress, and prepares review when complete.
    func receive(frame: String) async throws -> Double {
        guard incrementalScan, let incremental = engine as? IncrementalQREngine else {
            if !scanFrames.contains(frame) { scanFrames.append(frame) }
            return try await receive(frames: scanFrames)
        }
        clearRequest()
        let epoch = securityEpoch, incoming = requestEpoch
        let decoded = try await incremental.scan(frame: frame)
        try requireSession(epoch, requestID: incoming)
        if decoded["complete"] as? Bool == true, let request = decoded["request"] as? [String: Any] { try await prepare(request) }
        return decoded["progress"] as? Double ?? (review == nil ? 0 : 1)
    }

    func receive(frames: [String]) async throws -> Double {
        clearRequest()
        let epoch = securityEpoch, incoming = requestEpoch
        guard frames.count <= 2048, frames.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576 else { throw AppIssue.message(String(localized: "QR transfer is too large.", bundle: AppText.bundle)) }
        let decoded = try await engine.run(operation: "decodeQR", parameters: ["frames": frames])
        try requireSession(epoch, requestID: incoming)
        if decoded["complete"] as? Bool == true, let request = decoded["request"] as? [String: Any] { try await prepare(request) }
        return decoded["progress"] as? Double ?? (review == nil ? 0 : 1)
    }
    func importPayload(_ text: String) async throws {
        clearRequest()
        let epoch = securityEpoch, incoming = requestEpoch
        guard text.utf8.count <= 262_144 else { throw AppIssue.message(String(localized: "Text payload exceeds 256 KB.", bundle: AppText.bundle)) }
        let decoded = try await engine.run(operation: "decodePayload", parameters: ["payload": text])
        try requireSession(epoch, requestID: incoming)
        guard decoded["complete"] as? Bool == true, let request = decoded["request"] as? [String: Any] else { throw AppIssue.message(String(localized: "The request is incomplete. Import all QR frames.", bundle: AppText.bundle)) }
        try await prepare(request)
    }
    func prepare(_ request: [String: Any]) async throws {
        clearRequest()
        let epoch = securityEpoch, preparing = requestEpoch
        let data = try frozen(request), immutable = try object(data)
        let result = try await engine.run(operation: "review", parameters: ["request": immutable])
        try requireSession(epoch, requestID: preparing)
        let reviewed = TransactionReview(result)
        guard reviewed.requestHash.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              result["chain"] as? String == immutable["chain"] as? String,
              Chain(rawValue: result["chain"] as? String ?? "") != nil,
              !reviewed.fields.isEmpty else { throw AppIssue.message(String(localized: "Missing or invalid transaction commitment.", bundle: AppText.bundle)) }
        pendingRequestData = data; review = reviewed
        guard result["canSign"] as? Bool == true else { matchingError = "Unsupported signing protocol"; return }
        let collection = walletCollectionSnapshot
        let candidates: [[String: Any]] = wallets.map { wallet in
            var candidate: [String: Any] = ["localWalletId": wallet.id.uuidString]
            if let index = publicWallets[wallet.id] { candidate["publicIndex"] = index.raw }
            else { candidate["publicMetadataStatus"] = metadataStatus(for: wallet.id).rawValue }
            return candidate
        }
        do {
            let resolved = try await engine.run(operation: "resolveSigningPlan", parameters: ["request": immutable, "wallets": candidates])
            try requireSession(epoch, requestID: preparing)
            guard collection == walletCollectionSnapshot else {
                matchingError = "Wallet information changed. Match this request again."; return
            }
            guard resolved["status"] as? String == "ready" else {
                matchingError = resolved["message"] as? String ?? "No matching wallet"; return
            }
            let fixed = try SigningPlan(resolved, expectedRequestHash: reviewed.requestHash)
            guard fixed.tasks.allSatisfy({ publicWallets[$0.walletID]?.walletKeyId == $0.walletKeyId }) else { throw AppIssue.message(String(localized: "Invalid signing wallet identity.", bundle: AppText.bundle)) }
            plan = fixed; planWalletSnapshot = collection; matchingError = nil
            // The plan's review adds facts proven with the matched wallets' public
            // keys (e.g. verified Bitcoin change) for the same request commitment.
            if let planReview = resolved["review"] as? [String: Any] {
                let refined = TransactionReview(planReview)
                if refined.requestHash == reviewed.requestHash, refined.chain == reviewed.chain, !refined.fields.isEmpty { review = refined }
            }
        } catch {
            try requireSession(epoch, requestID: preparing)
            matchingError = error.localizedDescription
        }
    }

    func retryMatching() async throws {
        guard plan == nil, !hasSignedResponse, review != nil, let data = pendingRequestData else {
            throw AppIssue.message(String(localized: "No interrupted or unmatched request to retry.", bundle: AppText.bundle))
        }
        try await prepare(object(data))
    }

    func sign(taskID: String, password: String, riskAcknowledged: Bool = false) async throws {
        guard !busy, !hasSignedResponse else { throw AppIssue.message(String(localized: "This signing request is already being processed.", bundle: AppText.bundle)) }
        if let plan, planWalletSnapshot != walletCollectionSnapshot || plan.tasks.contains(where: { duplicateWalletIDs.contains($0.walletID) }) {
            invalidateMatching()
            throw AppIssue.message(String(localized: "Wallet information changed. Match this request again.", bundle: AppText.bundle))
        }
        guard matchingError == nil, let plan, let task = pendingTasks.first, task.id == taskID,
              let data = pendingRequestData, let approved = review, approved.requestHash == plan.requestHash,
              publicWallets[task.walletID]?.walletKeyId == task.walletKeyId else { throw AppIssue.message(String(localized: "No matching signing task. Review the request again.", bundle: AppText.bundle)) }
        let epoch = securityEpoch, signingRequest = requestEpoch, operation = UUID()
        signingOperation = operation; busy = true
        defer { if signingOperation == operation { signingOperation = nil; busy = false } }
        try requireSession(epoch, requestID: signingRequest)
        let request = try object(data)
        let result = try await authenticatedSignature(task: task, password: password, request: request, plan: plan,
                                                      epoch: epoch, requestID: signingRequest, riskAcknowledged: riskAcknowledged)
        try requireSession(epoch, requestID: signingRequest)
        guard result["requestHash"] as? String == plan.requestHash,
              result["planHash"] as? String == plan.planHash,
              result["taskId"] as? String == taskID else { throw AppIssue.message(String(localized: "Request changed. Review the transaction again.", bundle: AppText.bundle)) }
        let resultData = try frozen(result)
        let finalTask = pendingTasks.count == 1
        var encoded: [String: Any]?
        if finalTask {
            encoded = try await engine.run(operation: "encodeResponse", parameters: ["request": request, "result": result])
            try requireSession(epoch, requestID: signingRequest)
            let frames = encoded?["frames"] as? [String] ?? []
            let text = encoded?["text"] as? String ?? frames.joined(separator: "\n")
            guard !frames.isEmpty || !text.isEmpty else { throw AppIssue.message(String(localized: "Unable to encode signature response.", bundle: AppText.bundle)) }
            signatureFrames = frames; signatureText = text
            signaturePayload = encoded.flatMap { QRPayloadView($0) }
        }
        previousResultData = resultData; completedTaskIDs.insert(taskID)
        // What went in and what came out, both public. The request is kept as
        // the canonical JSON the engine reviewed, so Activity can review it
        // again; the response is kept as its frames and text, so the signature
        // can be shown and exported again without another signing operation.
        appendReceipt(SigningReceipt(id: UUID(), date: Date(), chain: task.chain, title: approved.title,
                                     requestHash: plan.requestHash, walletID: task.walletID,
                                     walletKeyID: task.walletKeyId, masterFingerprint: publicWallets[task.walletID]?.masterFingerprint,
                                     resultType: finalTask ? "Signature created" : "Partial signature created",
                                     summary: String(approved.summary.prefix(160)), networkName: approved.networkName,
                                     chainID: approved.network?.chainID, riskLevel: approved.riskLevel.rawValue,
                                     requestJSON: SigningReceipt.stored(String(data: data, encoding: .utf8)),
                                     responseFrames: finalTask ? SigningReceipt.stored(signatureFrames) : nil,
                                     responseText: finalTask ? SigningReceipt.stored(signatureText) : nil))
    }

    /// Keep clear credentials out of QR encoding and journal persistence scopes.
    /// Swift/JS copies cannot be promised perfect zeroization; nothing is cached
    /// for another operation. The engine independently checks every planned key.
    private func authenticatedSignature(task: SigningTask, password: String, request: [String: Any], plan: SigningPlan,
                                        epoch: UUID, requestID: UUID, riskAcknowledged: Bool) async throws -> [String: Any] {
        let secret = try await vault.unlock(id: task.walletID, password: password)
        try requireSession(epoch, requestID: requestID)
        var parameters: [String: Any] = ["request": request, "plan": plan.raw, "taskId": task.id,
                                         "seed": try BIP39Seed.hex(mnemonic: secret.mnemonic, passphrase: secret.passphrase),
                                         "riskAcknowledged": riskAcknowledged]
        if let previousResultData { parameters["previousResult"] = try object(previousResultData) }
        return try await engine.run(operation: "signPlanTask", parameters: parameters)
    }

    func reveal(walletID: UUID, password: String) async throws -> VaultSecret {
        let epoch = securityEpoch, sensitive = sensitiveEpoch
        let secret = try await vault.unlock(id: walletID, password: password)
        try requireSession(epoch)
        guard sensitive == sensitiveEpoch else { throw CancellationError() }
        return secret
    }
    /// The wallet this exact recovery phrase and BIP39 passphrase already
    /// belong to, if any. Public derivation only: nothing here reads a vault,
    /// asks for a password or returns a secret.
    func existingWallet(mnemonic: String, passphrase: String) async throws -> UUID? {
        let epoch = securityEpoch
        let canonical = try await validateMnemonic(mnemonic).phrase
        let raw = try await engine.run(operation: "derivePublicIndex", parameters: ["seed": try BIP39Seed.hex(mnemonic: canonical, passphrase: passphrase)])
        try requireSession(epoch)
        let key = try WalletPublicMetadata(raw).walletKeyId
        return publicWallets.first { $0.value.walletKeyId == key }?.key
    }

    /// Re-encrypts a wallet under a new password, authorized by its own recovery
    /// phrase rather than by the password nobody remembers. The phrase must
    /// derive this very wallet, which is checked here before anything is
    /// written: without that check, one wallet's phrase could overwrite
    /// another's stored secret.
    func resetPassword(walletID: UUID, mnemonic: String, passphrase: String, newPassword: String) async throws {
        guard let existing = publicWallets[walletID] else { throw AppIssue.message(String(localized: "This wallet needs repair before its password can be reset.", bundle: AppText.bundle)) }
        let epoch = securityEpoch
        let canonical = try await validateMnemonic(mnemonic).phrase
        let raw = try await engine.run(operation: "derivePublicIndex", parameters: ["seed": try BIP39Seed.hex(mnemonic: canonical, passphrase: passphrase)])
        try requireSession(epoch)
        let derived = try WalletPublicMetadata(raw)
        guard derived.walletKeyId == existing.walletKeyId else {
            throw AppIssue.message(String(localized: "This recovery phrase belongs to a different wallet.", bundle: AppText.bundle))
        }
        try await vault.resetPassword(id: walletID, mnemonic: canonical, passphrase: passphrase, newPassword: newPassword)
        // The password that was authorizing this session is gone.
        suspend()
        await reload()
    }

    /// Only the password that opens the vault changes. Keys, the wallet ID,
    /// public data, reviewed requests and navigation all stay valid.
    func changePassword(walletID: UUID, current: String, new: String) async throws {
        try Task.checkCancellation()
        try await vault.changePassword(id: walletID, currentPassword: current, newPassword: new)
    }
    func deleteWallet(walletID: UUID, password: String) async throws {
        try Task.checkCancellation()
        // The vault verifies the password before removing anything, so a wrong
        // password leaves every session intact and its error reaches the sheet.
        do { try await vault.delete(id: walletID, password: password) }
        catch { await reload(); throw error }
        suspend()
        do { try await publicRepository.remove(walletID: walletID) }
        catch { self.error = "The encrypted wallet was deleted, but its public cache could not be removed." }
        clearRequest(); navigationResetEpoch = UUID()
        await reload()
    }
    func clearHistory() {
        do { try saveReceipts([]); receipts = [] }
        catch { reportReceiptWriteFailure() }
    }
    private func loadReceipts() {
        receipts = []
        do { receipts = try readReceipts() }
        catch { self.error = "The local activity record could not be read." }
    }
    private func readReceipts() throws -> [SigningReceipt] {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.receiptFileLimit,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw AppIssue.message(String(localized: "Invalid activity record.", bundle: AppText.bundle)) }
        let loaded = try JSONDecoder().decode([SigningReceipt].self, from: Data(contentsOf: receiptURL))
        guard loaded.count <= 100, loaded.allSatisfy({ $0.title.count <= 200 && ($0.summary?.count ?? 0) <= 200
            && $0.requestHash.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
            && SigningReceipt.stored($0.requestJSON) == $0.requestJSON
            && SigningReceipt.stored($0.responseText) == $0.responseText
            && SigningReceipt.stored($0.responseFrames) == $0.responseFrames }) else { throw AppIssue.message(String(localized: "Invalid activity record.", bundle: AppText.bundle)) }
        return loaded
    }
    private func appendReceipt(_ receipt: SigningReceipt) {
        do {
            // Payloads are kept for the most recent signatures only; older
            // records keep everything else and lose only their payloads.
            var updated = Array(([receipt] + (try readReceipts())).prefix(100))
                .enumerated().map { $0.offset < SigningReceipt.payloadRetention ? $0.element : $0.element.withoutPayloads }
            // A file over the read limit would be rejected on the next launch,
            // losing the whole history. Rather than risk that, drop payloads
            // from the oldest records until what will be written fits.
            while try JSONEncoder().encode(updated).count > Self.receiptFileLimit,
                  let oldest = updated.lastIndex(where: { $0.hasPayloads }) {
                updated[oldest] = updated[oldest].withoutPayloads
            }
            try saveReceipts(updated); receipts = updated
        } catch { reportReceiptWriteFailure() }
    }

    /// What `readReceipts` accepts: 100 records, of which at most
    /// `payloadRetention` carry payloads of `payloadLimit` each, plus room for
    /// their metadata and JSON encoding.
    static let receiptFileLimit = 2_097_152

    /// Reviews a request kept in Activity again. It never touches the pending
    /// request, never matches a wallet and never needs a password: `review` is
    /// a function of the request alone, and the request is public. The result
    /// must still commit to the same fingerprint, which makes the stored copy
    /// self-checking.
    func review(storedRequest json: String, expecting requestHash: String) async throws -> TransactionReview {
        guard let data = json.data(using: .utf8), data.count <= SigningReceipt.payloadLimit else {
            throw AppIssue.message(String(localized: "The stored request could not be read.", bundle: AppText.bundle))
        }
        let result = try await engine.run(operation: "review", parameters: ["request": try object(data)])
        let reviewed = TransactionReview(result)
        guard reviewed.requestHash.caseInsensitiveCompare(requestHash) == .orderedSame, !reviewed.fields.isEmpty else {
            throw AppIssue.message(String(localized: "The stored request does not match this signature's fingerprint.", bundle: AppText.bundle))
        }
        return reviewed
    }
    private func saveReceipts(_ records: [SigningReceipt]) throws {
        var directory = receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(records).write(to: receiptURL, options: [.atomic, .completeFileProtection])
        var file = receiptURL; try file.setResourceValues(values)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func reportReceiptWriteFailure() { error = "The local activity record could not be saved. Any completed signature remains available." }
}
