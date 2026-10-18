import Foundation

enum Chain: String, CaseIterable, Identifiable, Codable, Sendable {
    case bitcoin, evm, tron, solana
    var id: String { rawValue }

    var name: String {
        switch self {
        case .bitcoin: "Bitcoin"
        case .evm: "EVM"
        case .tron: "TRON"
        case .solana: "Solana"
        }
    }

    /// Name used where a chain family is listed on its own.
    var longName: String {
        switch self {
        case .evm: "Ethereum & EVM"
        default: name
        }
    }

    var ticker: String {
        switch self {
        case .bitcoin: "BTC"
        case .evm: "EVM"
        case .tron: "TRX"
        case .solana: "SOL"
        }
    }
}

struct PublicAccount: Identifiable, Hashable {
    let chain: Chain
    let address: String
    let path: String
    let publicKey: String
    let index: Int
    var id: String { chain.rawValue + ":" + path }

    init(_ raw: [String: Any]) {
        chain = Chain(rawValue: raw["chain"] as? String ?? "") ?? .bitcoin
        address = raw["address"] as? String ?? ""
        path = raw["path"] as? String ?? ""
        publicKey = raw["publicKey"] as? String ?? ""
        index = raw["index"] as? Int ?? 0
    }
}

struct ReviewField: Identifiable, Hashable {
    let id: Int
    let label: String
    let value: String

    /// Groups fields such as "Instruction 2 · Recipient" or "Safe: Recipient".
    var group: String? {
        if let range = label.range(of: " · ") { return String(label[..<range.lowerBound]) }
        return nil
    }
    var shortLabel: String {
        if let range = label.range(of: " · ") { return String(label[range.upperBound...]) }
        return label
    }
    var isLong: Bool { value.count > 280 || value.filter { $0 == "\n" }.count > 6 }

    /// The label without any "Instruction 2 · " group or "Call 2: " / "Safe: " prefix, lowercased.
    private var baseLabel: String {
        var base = shortLabel
        if let range = base.range(of: ": ", options: .backwards) { base = String(base[range.upperBound...]) }
        return base.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Token IDs, quantities and item lists. Shown in full as plain monospaced
    /// text: never as an address, never collapsed behind "Show All".
    var isTokenIdentifier: Bool {
        let base = baseLabel
        return base.contains("token id") || base.contains("quantity") || base == "items" || base.hasPrefix("items ")
    }

    /// Fields whose value is a number. A long digit string can pass the
    /// address heuristics (a 25+ digit token ID starting with 1 or 3 matches
    /// the Bitcoin pattern), so these are matched by label, not by value.
    /// All-digit values elsewhere stay addresses: the Solana System Program
    /// ID is 32 ones.
    var holdsNumber: Bool {
        let base = baseLabel
        return isTokenIdentifier || base.contains("amount") || base.contains("allowance")
            || base.contains("raw units") || base.contains("(wei)")
    }

    /// Whether Details should render this value as a copyable address.
    var rendersAsAddress: Bool { !holdsNumber && AddressFormatter.looksLikeAddress(value) }
}

struct ReviewAsset: Codable, Hashable {
    let chainFamily: String
    let chainId: String?
    let assetAddress: String
    let name: String
    let symbol: String
    let decimals: Int
    let tokenProgram: String?
    /// Content hash of the bundled artwork; see TokenIconStore.
    let icon: String
    let rawAmount: String?
    let displayAmount: String?
}

/// Network context reported by the engine for this exact request.
struct ReviewNetwork: Hashable {
    let family: Chain
    let chainID: String?
    let name: String
    let symbol: String?
    var brand: NetworkBrand? {
        switch family {
        case .evm: NetworkBrand.evm(chainID: chainID)
        default: family.primaryNetwork
        }
    }
}

/// What the bundled known-contract library says about the address a request
/// hands assets or authority to. A hit means the deployment was published by
/// the project itself and cross-checked; it never means the request is safe.
/// A miss is normal for a new or private deployment, so it is stated plainly
/// rather than treated as proof of fraud.
struct ReviewContract: Hashable {
    /// What the address is to this request. Unknown roles from a newer engine
    /// fall back to `.contract`, which is the least specific wording.
    enum Role: String, Hashable { case spender, operator_ = "operator", contract }

    let address: String
    let role: Role
    let known: Bool
    /// Present only when `known`.
    var name: String?
    var project: String?
    var category: String?
    /// A deterministic (CREATE2) deployment that has the same address on every
    /// EVM network, so the listing is not tied to one chain.
    var everyChain = false
    /// Set when the address is not in the contract library but is a token in
    /// the bundled token registry, e.g. "Tether USD (USDT)". The registry
    /// already identified it, so it is not presented as unknown.
    var token: String?

    /// "Uniswap · infra", or just whichever part the library carries.
    var subtitle: String? {
        let parts = [project, category].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Parses the engine's `review.contract`. A record without an address is
    /// no record at all; anything unparseable degrades to the unlisted case
    /// rather than claiming a contract is known.
    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any],
              let address = ReviewDisplay.boundedValue(raw["address"]) else { return nil }
        self.address = address
        role = Role(rawValue: raw["role"] as? String ?? "") ?? .contract
        name = ReviewDisplay.boundedValue(raw["name"])
        // "Known" without a name says nothing a person could check, so it is
        // not presented as a hit.
        known = (raw["known"] as? Bool ?? false) && name != nil
        guard known else {
            name = nil
            token = ReviewDisplay.boundedValue(raw["token"])
            return
        }
        project = ReviewDisplay.boundedValue(raw["protocol"])
        category = ReviewDisplay.boundedValue(raw["category"])
        everyChain = raw["everyChain"] as? Bool ?? false
    }
}

/// What an NFT-aware review is about. The engine sets it only for NFT flows.
/// An unknown value from another engine version is ignored (nil) together
/// with every other NFT key, which keeps the generic layout.
enum ReviewAssetKind: String, Hashable, Sendable {
    /// The method only exists for NFTs, or the NFT status is proven.
    case nft
    /// Ambiguous: a selector shared by ERC-20 and ERC-721, or a 0-decimal SPL transfer of 1.
    case nftOrToken
    /// ERC-1155. IDs may be fungible, so it is never presented as an NFT.
    case multiToken
    /// A marketplace order signature (Seaport, LooksRare, Blur).
    case nftOrder

    /// SF Symbol for the summary glyph. No artwork is ever fetched.
    var systemImage: String {
        switch self {
        case .nft, .nftOrToken: "photo.artframe"
        case .multiToken: "square.stack.3d.up.fill"
        case .nftOrder: "tag.fill"
        }
    }
}

/// One labelled list of a marketplace order ("You give", "You receive", "Also paid out").
struct ReviewFlowSection: Identifiable, Hashable {
    enum Kind: String, Hashable { case give, receive, others }
    let kind: Kind
    let lines: [String]
    var id: String { kind.rawValue }

    var systemImage: String {
        switch kind {
        case .give: "arrow.up.right"
        case .receive: "arrow.down.left"
        case .others: "arrow.triangle.branch"
        }
    }
}

/// Structured headline produced by the engine from the parsed signing bytes.
struct ReviewDisplay: Hashable {
    let action: String
    let amount: String?
    let symbol: String?
    let headline: String?
    let counterpartyLabel: String?
    let counterparty: String?
    let fee: String?
    /// What `fee` means. Absent is a ceiling on the whole network fee; TRON's
    /// fee_limit caps only the energy a contract call may burn, which is not
    /// the same promise and must not be captioned as one.
    var feeKind: String? = nil
    let note: String?
    // NFT flows only. Absent (nil / empty) for every other request.
    var assetKind: ReviewAssetKind? = nil
    var assetContract: String? = nil
    var assetContractLabel: String? = nil
    var tokenId: String? = nil
    var give: [String] = []
    var receive: [String] = []
    var others: [String] = []
}

extension ReviewDisplay {
    static let maxListLines = 32
    static let maxStringLength = 300
    static let defaultAssetContractLabel = "NFT contract (not verified)"

    /// Parses the engine's `review.display`. The original keys keep their
    /// lenient parsing; the NFT keys are type-checked and size-bounded, and
    /// are read only together with a recognised `assetKind` (fail closed).
    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any], let action = raw["action"] as? String else { return nil }
        self.init(action: action, amount: raw["amount"] as? String,
                  symbol: raw["symbol"] as? String,
                  headline: raw["headline"] as? String,
                  counterpartyLabel: raw["counterpartyLabel"] as? String,
                  counterparty: raw["counterparty"] as? String,
                  fee: raw["fee"] as? String,
                  note: raw["note"] as? String)
        feeKind = raw["feeKind"] as? String
        assetKind = (raw["assetKind"] as? String).flatMap(ReviewAssetKind.init(rawValue:))
        // No or unknown kind: nothing NFT-specific is shown, not even a contract box.
        guard assetKind != nil else { return }
        assetContract = Self.boundedValue(raw["assetContract"])
        assetContractLabel = Self.boundedValue(raw["assetContractLabel"])
        tokenId = Self.boundedValue(raw["tokenId"])
        give = Self.boundedLines(raw["give"])
        receive = Self.boundedLines(raw["receive"])
        others = Self.boundedLines(raw["others"])
    }

    /// An identifier is shown whole or not at all: never cut to fit.
    static func boundedValue(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.count <= maxStringLength else { return nil }
        return string
    }

    /// A list is all strings or ignored. More than 32 lines end in a "+N more"
    /// line; the full values stay in Details.
    static func boundedLines(_ value: Any?) -> [String] {
        guard let strings = value as? [Any], strings.allSatisfy({ $0 is String }) else { return [] }
        let lines = strings.compactMap { $0 as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(boundedLine)
        guard lines.count > maxListLines else { return lines }
        let shown = lines.prefix(maxListLines - 1)
        return Array(shown) + ["+\(lines.count - shown.count) more (see Details)"]
    }

    /// An over-long line is cut in the middle: the start (the amount) and the
    /// end (the recipient and its "(unrecognised recipient)" tag) both stay.
    static func boundedLine(_ line: String) -> String {
        guard line.count > maxStringLength else { return line }
        let head = (maxStringLength - 1) / 2
        return String(line.prefix(head)) + "…" + String(line.suffix(maxStringLength - 1 - head))
    }

    var isNFT: Bool { assetKind != nil }

    var assetContractCaption: String { assetContractLabel ?? Self.defaultAssetContractLabel }

    /// The value may be an ERC-20 amount or allowance rather than a token ID,
    /// so the ambiguous case never calls it just a token ID.
    /// Whether the value may be an ERC-20 amount rather than a token ID.
    var tokenIDIsAmbiguous: Bool { assetKind == .nftOrToken }

    /// The full token ID when the headline and amount do not already show it
    /// as "#<id>", e.g. "NFT #79233663…80642508 (77 digits)".
    var summaryTokenID: String? {
        guard isNFT, let tokenId else { return nil }
        let shown = [headline, amount].compactMap { $0 }.contains { Self.text($0, showsTokenID: tokenId) }
        return shown ? nil : tokenId
    }

    /// Whether the summary shows the contract / token ID box.
    var showsAssetBox: Bool { isNFT && (assetContract != nil || summaryTokenID != nil) }

    /// Non-empty order lists in reading order.
    var flowSections: [ReviewFlowSection] {
        guard isNFT else { return [] }
        return [ReviewFlowSection(kind: .give, lines: give), ReviewFlowSection(kind: .receive, lines: receive),
                ReviewFlowSection(kind: .others, lines: others)].filter { !$0.lines.isEmpty }
    }

    /// True when `text` shows the whole ID the way the engine writes IDs:
    /// "#<id>" not followed by another digit. "#12345" does not show token
    /// 1234, and neither do counts or decimals ("Give 2 items", "0.95").
    static func text(_ text: String, showsTokenID id: String) -> Bool {
        guard !id.isEmpty else { return false }
        let needle = "#" + id
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            if range.upperBound == text.endIndex || !text[range.upperBound].isASCIIDigit { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// VoiceOver reads a long ID in groups of four instead of as one huge number.
    static func spokenTokenID(_ id: String) -> String {
        id.count > 12 ? AddressFormatter.groups(id, size: 4).joined(separator: ", ") : id
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

enum DecodeStatus: String {
    case fullyDecoded, partiallyDecoded, opaque
}

enum RiskLevel: String {
    case normal, warning, high
}

struct TransactionReview {
    let chain: Chain
    let title: String
    let summary: String
    let fields: [ReviewField]
    let warnings: [String]
    let requestHash: String
    let asset: ReviewAsset?
    let decodeStatus: DecodeStatus
    let riskLevel: RiskLevel
    let network: ReviewNetwork?
    let display: ReviewDisplay?
    /// What the bundled library says about the address this request authorizes.
    let contract: ReviewContract?

    /// Explicit per-request consent is required for incompletely decoded or
    /// high-risk requests. It never overrides structural or identity checks.
    var requiresAcknowledgement: Bool { decodeStatus != .fullyDecoded || riskLevel == .high }

    var networkName: String {
        if let network { return network.name }
        return fields.first { $0.label == "Network" }?.value ?? chain.name
    }

    init(_ raw: [String: Any]) {
        chain = Chain(rawValue: raw["chain"] as? String ?? "") ?? .bitcoin
        title = raw["title"] as? String ?? "Review request"
        summary = raw["summary"] as? String ?? ""
        fields = (raw["fields"] as? [[String: Any]] ?? []).enumerated().map { offset, field in
            ReviewField(id: offset, label: field["label"] as? String ?? "", value: String(describing: field["value"] ?? ""))
        }
        warnings = raw["warnings"] as? [String] ?? []
        requestHash = raw["requestHash"] as? String ?? ""
        decodeStatus = DecodeStatus(rawValue: raw["decodeStatus"] as? String ?? "") ?? .opaque
        riskLevel = RiskLevel(rawValue: raw["riskLevel"] as? String ?? "") ?? (warnings.isEmpty ? .normal : .warning)
        if let rawAsset = raw["asset"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: rawAsset) {
            asset = try? JSONDecoder().decode(ReviewAsset.self, from: data)
        } else { asset = nil }
        if let rawNetwork = raw["network"] as? [String: Any], let name = rawNetwork["name"] as? String {
            network = ReviewNetwork(family: chain, chainID: rawNetwork["chainId"] as? String,
                                    name: name, symbol: rawNetwork["symbol"] as? String)
        } else { network = nil }
        display = ReviewDisplay(raw["display"])
        contract = ReviewContract(raw["contract"])
    }
}

/// Local record of a signature created on this device. It never stores secrets
/// and never claims broadcast or confirmation. The most recent records also keep
/// what went in and what came out — both public data — so Activity can show the
/// request again and hand the signature back to the wallet that asked for it.
struct SigningReceipt: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let chain: Chain
    let title: String
    let requestHash: String
    var walletID: UUID? = nil
    var walletKeyID: String? = nil
    var masterFingerprint: String? = nil
    var resultType: String? = nil
    var summary: String? = nil
    var networkName: String? = nil
    var chainID: String? = nil
    var riskLevel: String? = nil
    /// The exact request that was reviewed and signed, as canonical JSON.
    /// Reviewing it again rebuilds every decoded field offline, and the result's
    /// hash has to equal `requestHash`, so the stored copy checks itself.
    var requestJSON: String? = nil
    /// The frames the signature QR showed, so it can be shown again when the
    /// other wallet did not finish scanning it.
    var responseFrames: [String]? = nil
    /// What the file export writes: the signature response as text.
    var responseText: String? = nil

    /// Whether anything beyond the summary was kept for this signature.
    var hasPayloads: Bool { requestJSON != nil || responseText != nil || responseFrames?.isEmpty == false }

    /// Limits for one record. A payload larger than this is not kept: the
    /// record still exists, it just carries its summary alone.
    static let payloadLimit = 32_768
    /// How many of the most recent signatures keep their payloads.
    static let payloadRetention = 25

    /// The same record with its payloads dropped, used to age older entries out.
    var withoutPayloads: SigningReceipt {
        var copy = self
        copy.requestJSON = nil; copy.responseFrames = nil; copy.responseText = nil
        return copy
    }

    /// A payload worth storing: present, non-empty and within the limit.
    static func stored(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= payloadLimit else { return nil }
        return text
    }

    static func stored(_ frames: [String]?) -> [String]? {
        guard let frames, !frames.isEmpty, frames.count <= 2_048,
              frames.reduce(0, { $0 + $1.utf8.count }) <= payloadLimit else { return nil }
        return frames
    }
}

enum AppIssue: LocalizedError, Equatable {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}

enum PublicMetadataStatus: String, Codable, Sendable { case ready, needsCompletion, invalid }

/// A frozen, public-only document. Secrets never belong in this cache. The
/// signing engine re-derives and checks its keys after every password approval.
struct WalletPublicMetadata: Sendable {
    let jsonData: Data
    let walletKeyId: String
    let masterFingerprint: String
    var version: Int { 2 }
    var raw: [String: Any] { (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] ?? [:] }

    init(_ raw: [String: Any]) throws {
        guard raw["version"] as? Int == 1,
              let key = raw["walletKeyId"] as? String, Self.isHex(key, bytes: 32),
              let fingerprint = raw["masterFingerprint"] as? String, Self.isHex(fingerprint, bytes: 4),
              let bitcoin = raw["bitcoinPublicNodes"] as? [[String: Any]], bitcoin.count == 6,
              let evm = raw["evmAccountNode"] as? [String: Any],
              let tron = raw["tronAccountNode"] as? [String: Any],
              let tronAddresses = raw["tronAddressIndex"] as? [[String: Any]], tronAddresses.count == 100,
              let solana = raw["solanaPublicKeys"] as? [[String: Any]], solana.count == 3,
              Self.publicOnly(raw) else { throw AppIssue.message(String(localized: "Invalid public wallet data. Repair this wallet.", bundle: AppText.bundle)) }
        let expectedBTC = Set(["m/84'/0'/0'", "m/86'/0'/0'", "m/49'/0'/0'", "m/44'/0'/0'", "m/48'/0'/0'/2'", "m/48'/0'/0'/1'"])
        guard Set(bitcoin.compactMap { $0["originPath"] as? String }) == expectedBTC,
              evm["originPath"] as? String == "m/44'/60'/0'",
              tron["originPath"] as? String == "m/44'/195'/0'",
              (bitcoin + [evm, tron]).allSatisfy(Self.validNode),
              Set(solana.compactMap { $0["path"] as? String }) == Set(["m/44'/501'/0'/0'", "m/44'/501'/0'", "m/44'/501'"]),
              solana.allSatisfy({ Self.validAddress($0, keyBytes: 32) }),
              Set(tronAddresses.compactMap { $0["index"] as? Int }) == Set(0..<100),
              tronAddresses.allSatisfy({ item in
                  guard let index = item["index"] as? Int else { return false }
                  return item["path"] as? String == "m/44'/195'/0'/0/\(index)" && Self.validAddress(item, keyBytes: 33)
              }) else { throw AppIssue.message(String(localized: "Public wallet data is incomplete or inconsistent.", bundle: AppText.bundle)) }
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        guard data.count <= 262_144 else { throw AppIssue.message(String(localized: "Public wallet data is too large.", bundle: AppText.bundle)) }
        jsonData = data; walletKeyId = key.lowercased(); masterFingerprint = fingerprint.lowercased()
    }

    /// First receive address for each chain family, for summaries.
    var evmAddress: String? { (raw["evmDefaultAddress"] as? [String: Any])?["address"] as? String }

    private static func isHex(_ value: String, bytes: Int) -> Bool {
        value.count == bytes * 2 && value.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil
    }
    private static func validNode(_ node: [String: Any]) -> Bool {
        guard let key = node["publicKey"] as? String, let code = node["chainCode"] as? String,
              let fingerprint = node["parentFingerprint"] as? String,
              let depth = node["depth"] as? Int, let xpub = node["xpub"] as? String else { return false }
        return isHex(key, bytes: 33) && (key.hasPrefix("02") || key.hasPrefix("03")) && isHex(code, bytes: 32)
            && isHex(fingerprint, bytes: 4) && (3...4).contains(depth) && xpub.hasPrefix("xpub") && xpub.count < 120
    }
    private static func validAddress(_ item: [String: Any], keyBytes: Int) -> Bool {
        guard let key = item["publicKey"] as? String, let address = item["address"] as? String else { return false }
        return isHex(key, bytes: keyBytes) && !address.isEmpty && address.count <= 128
    }
    private static func publicOnly(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= 12 else { return false }
        if let object = value as? [String: Any] {
            let forbidden = Set(["mnemonic", "seed", "privatekey", "privateextendedkey", "password", "passphrase", "xprv", "secret"])
            return object.allSatisfy { !forbidden.contains($0.key.lowercased()) && publicOnly($0.value, depth: depth + 1) }
        }
        if let values = value as? [Any] { return values.count <= 256 && values.allSatisfy { publicOnly($0, depth: depth + 1) } }
        if let string = value as? String { return string.utf8.count <= 2048 && !string.hasPrefix("xprv") }
        return value is NSNumber || value is NSNull
    }
}

/// BitTool Signer wallet-level pairing (`bittool-signer-wallet` v1): one QR for every
/// chain family. `json` is the developer view of the exact encoded object.
struct WalletPairingPayload: Equatable {
    struct Line: Equatable, Identifiable {
        let chain: String
        /// Which account within the chain: a Bitcoin script type ("native",
        /// "taproot", "nested", "legacy") or a Solana preset. A chain can now
        /// contribute several lines, so the id has to include it — keying on
        /// `chain` alone made SwiftUI draw the first Bitcoin row four times.
        let profile: String
        let address: String
        let path: String
        var id: String { chain + "/" + profile }
    }
    let frames: [String]
    let text: String
    let mode: String
    let payloadBytes: Int
    let firstAddresses: [Line]
    let json: String

    init(_ raw: [String: Any]) throws {
        let frames = raw["frames"] as? [String] ?? []
        guard !frames.isEmpty, let payload = raw["payload"] as? [String: Any],
              JSONSerialization.isValidJSONObject(payload) else { throw AppIssue.message(String(localized: "Unable to encode the wallet pairing.", bundle: AppText.bundle)) }
        self.frames = frames
        text = raw["text"] as? String ?? frames.joined(separator: "\n")
        mode = raw["mode"] as? String ?? ""
        payloadBytes = raw["payloadBytes"] as? Int ?? 0
        firstAddresses = (raw["verify"] as? [[String: Any]] ?? []).compactMap { item in
            guard let chain = item["chain"] as? String, let address = item["address"] as? String, let path = item["path"] as? String else { return nil }
            return Line(chain: chain, profile: item["profile"] as? String ?? "standard", address: address, path: path)
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        json = String(decoding: data, as: UTF8.self)
    }
}

struct PairingPayload: Equatable {
    let frames: [String]
    let text: String
    let address: String
    let path: String
    let outputMode: String
    let note: String?
    /// What the QR code carries, decoded back from its frames by the engine.
    let payloadView: QRPayloadView?

    init(_ raw: [String: Any]) throws {
        let frames = raw["frames"] as? [String] ?? []
        guard !frames.isEmpty else { throw AppIssue.message(String(localized: "Unable to encode public wallet information.", bundle: AppText.bundle)) }
        self.frames = frames; text = raw["text"] as? String ?? frames.joined(separator: "\n")
        address = raw["address"] as? String ?? ""; path = raw["path"] as? String ?? ""
        outputMode = raw["outputMode"] as? String ?? ""; note = raw["note"] as? String
        payloadView = QRPayloadView(raw)
    }
}

/// Developer view of exactly what a QR code carries. The engine decodes it again
/// from the frames it produced (describeQR in engine/protocols.js): registry field
/// names, byte strings as hex, tags as one-key objects; a plain-text QR code (an
/// address) is its own payload.
struct QRPayloadView: Equatable {
    enum Format: String { case json, hex, text }
    let format: Format
    let text: String
    let byteCount: Int
    let qrType: String?
    private let bbqrEncoding: String?

    var title: String {
        switch format {
        case .json: "Payload (JSON)"
        case .hex: "Payload (Hex)"
        case .text: "Payload (Text)"
        }
    }

    /// The transport, e.g. "ur:crypto-account · CBOR · 162 bytes".
    var summary: String {
        let bytes = "\(byteCount.formatted()) bytes"
        switch qrType {
        case "bbqr-psbt": return "BBQr · PSBT (\(bbqrEncoding == "H" ? "hex" : "Base32")) · \(bytes)"
        case "psbt-base64": return "Plain text · PSBT Base64 · \(bytes)"
        case "psbt-hex": return "Plain text · PSBT hex · \(bytes)"
        case nil, "address": return "Plain text · \(bytes)"
        case let type?: return "ur:\(type) · CBOR · \(bytes)"
        }
    }

    var isPSBT: Bool { ["crypto-psbt", "psbt", "bbqr-psbt", "psbt-base64", "psbt-hex"].contains(qrType ?? "") }

    /// Nil when the engine sent no payload view, so the disclosure is hidden.
    init?(_ raw: [String: Any]) {
        guard let format = (raw["payloadFormat"] as? String).flatMap(Format.init(rawValue:)) else { return nil }
        switch format {
        case .json:
            guard let object = raw["payload"] as? [String: Any], let json = Self.prettyJSON(object) else { return nil }
            text = json
        case .hex, .text:
            guard let value = raw["payload"] as? String, !value.isEmpty else { return nil }
            text = value
        }
        self.format = format
        byteCount = raw["payloadBytes"] as? Int ?? text.utf8.count
        qrType = raw["type"] as? String
        let first = (raw["frames"] as? [String])?.first ?? ""
        bbqrEncoding = first.hasPrefix("B$") && first.count > 2 ? String(first[first.index(first.startIndex, offsetBy: 2)]) : nil
    }

    /// Pretty, key-sorted JSON, formatted like the wallet-level payload.
    static func prettyJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

struct SigningTask: Identifiable {
    let id: String
    let walletID: UUID
    let walletKeyId: String
    let chain: Chain
    let paths: [String]
    let publicKeys: [String]
    let addresses: [String]
    let inputs: [Int]
    let signerSlot: Int?
    var displayAddresses: [String] { distinctValues(addresses) }
    var displayPaths: [String] { distinctValues(paths) }
    private func distinctValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    init(_ raw: [String: Any]) throws {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let walletID = UUID(uuidString: raw["localWalletId"] as? String ?? ""),
              let key = raw["walletKeyId"] as? String, key.count == 64,
              let chain = Chain(rawValue: raw["chain"] as? String ?? ""),
              let paths = raw["paths"] as? [String], !paths.isEmpty,
              let publicKeys = raw["publicKeys"] as? [String], publicKeys.count == paths.count else {
            throw AppIssue.message(String(localized: "Invalid signing plan.", bundle: AppText.bundle))
        }
        self.id = id; self.walletID = walletID; walletKeyId = key
        self.chain = chain; self.paths = paths; self.publicKeys = publicKeys
        addresses = raw["addresses"] as? [String] ?? []; inputs = raw["inputs"] as? [Int] ?? []
        signerSlot = (raw["targets"] as? [[String: Any]])?.first?["signerSlot"] as? Int
    }
}

struct SigningPlan {
    let requestHash: String
    let planHash: String
    let tasks: [SigningTask]
    private let jsonData: Data
    var raw: [String: Any] { (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] ?? [:] }
    init(_ raw: [String: Any], expectedRequestHash: String) throws {
        guard raw["status"] as? String == "ready", raw["requestHash"] as? String == expectedRequestHash,
              let planHash = raw["planHash"] as? String,
              planHash.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              let tasks = raw["tasks"] as? [[String: Any]], !tasks.isEmpty, tasks.count <= 64 else {
            throw AppIssue.message(String(localized: "Invalid signing plan.", bundle: AppText.bundle))
        }
        self.tasks = try tasks.map(SigningTask.init)
        guard Set(self.tasks.map(\.id)).count == self.tasks.count else { throw AppIssue.message(String(localized: "Duplicate signing task.", bundle: AppText.bundle)) }
        requestHash = expectedRequestHash; self.planHash = planHash
        jsonData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    }
}
