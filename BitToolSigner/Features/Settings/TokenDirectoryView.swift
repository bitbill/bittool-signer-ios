import SwiftUI
import Combine

/// Token metadata bundled with the app. The engine uses the same records to
/// show names and decimals offline; this screen only lets people browse them.
struct TokenRegistryEntry: Decodable, Identifiable, Hashable {
    let chainFamily: String
    let chainId: String?
    let assetAddress: String
    let name: String
    let symbol: String
    let decimals: Int
    let icon: String
    let rank: Int?
    var id: String { [chainFamily, chainId ?? "", assetAddress].joined(separator: ":") }
}

/// A network the registry recognises tokens on. Four EVM networks, TRON and
/// Solana have bundled logos; the rest show a neutral badge.
struct TokenRegistryNetwork: Decodable, Identifiable, Hashable {
    let chainFamily: String
    let chainId: String?
    /// Stable slug ("ethereum", "smartchain"), used for identifiers.
    let key: String
    let name: String
    let nativeSymbol: String
    let tokens: Int
    var id: String { key }
    /// The grouping key shared with the asset and contract rows.
    var chain: String { chainFamily + ":" + (chainId ?? "") }
    var brand: NetworkBrand? {
        switch chainFamily {
        case "evm": NetworkBrand.evm(chainID: chainId)
        case "tron": .tron
        case "solana": .solana
        default: nil
        }
    }
    var shortName: String { brand?.shortName ?? name }
}

/// One address in the bundled known-contract library. A record says the
/// deployment was published by the project itself and cross-checked; it never
/// says a request using the address is safe.
struct KnownContractEntry: Decodable, Identifiable, Hashable {
    let chainFamily: String
    let chainId: String?
    let address: String
    let name: String
    /// The project that published it. `protocol` is a Swift keyword in all but
    /// name, so the decoded property reads `project`.
    let project: String
    let category: String
    var id: String { [chainFamily, chainId ?? "", address].joined(separator: ":") }

    private enum CodingKeys: String, CodingKey {
        case chainFamily, chainId, address, name, project = "protocol", category
    }

    var chain: String { chainFamily + ":" + (chainId ?? "") }
    /// Deterministic (CREATE2) deployments carry `*`: the same address on every
    /// EVM network rather than one chain's listing.
    var everyChain: Bool { chainId == "*" }

    /// SF Symbol for the category. Categories come from the library, so an
    /// unknown one from a later import still gets a glyph.
    var systemImage: String {
        switch category {
        case "aggregator": "arrow.triangle.merge"
        case "bridge": "arrow.left.arrow.right"
        case "dex": "arrow.2.squarepath"
        case "infra": "gearshape.2.fill"
        case "lending": "building.columns.fill"
        case "nft": "photo.artframe"
        case "perp": "chart.line.uptrend.xyaxis"
        case "staking": "lock.shield.fill"
        case "token": "circle.hexagongrid.fill"
        case "wallet": "wallet.pass.fill"
        default: "square.grid.2x2.fill"
        }
    }
}

private struct TokenRegistryFile: Decodable {
    let registryVersion: String
    let networks: [TokenRegistryNetwork]
    let assets: [TokenRegistryEntry]
}

private struct KnownContractsFile: Decodable {
    let updated: String
    let contracts: [KnownContractEntry]
}

/// Everything the app recognises offline, read once from the bundle. Both
/// files are public reference data: no wallet or key material is involved.
@MainActor
final class TokenDirectory: ObservableObject {
    @Published private(set) var version = ""
    @Published private(set) var networks: [TokenRegistryNetwork] = []
    @Published private(set) var byNetwork: [String: [TokenRegistryEntry]] = [:]
    @Published private(set) var contractsUpdated = ""
    @Published private(set) var contractsByNetwork: [String: [KnownContractEntry]] = [:]
    @Published private(set) var contractCount = 0
    @Published private(set) var loaded = false

    /// Contracts listed for every EVM network at one deterministic address.
    /// They are not a network of their own, so they get their own row.
    static let everyEVMChain = "evm:*"

    var everyChainContracts: [KnownContractEntry] { contractsByNetwork[Self.everyEVMChain] ?? [] }

    func load() async {
        guard !loaded else { return }
        let bundled = await Task.detached { () -> (TokenRegistryFile?, KnownContractsFile?) in
            func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
                guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                      let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(type, from: data)
            }
            return (read("token-registry", as: TokenRegistryFile.self),
                    read("known-contracts", as: KnownContractsFile.self))
        }.value
        if let file = bundled.0 {
            var grouped: [String: [TokenRegistryEntry]] = [:]
            for entry in file.assets {
                grouped[entry.chainFamily + ":" + (entry.chainId ?? ""), default: []].append(entry)
            }
            // The file is already ordered by network, then rank; keep that order.
            version = file.registryVersion; networks = file.networks; byNetwork = grouped
        }
        if let file = bundled.1 {
            var grouped: [String: [KnownContractEntry]] = [:]
            for entry in file.contracts { grouped[entry.chain, default: []].append(entry) }
            // Within a network, by project then name: a long list is read by eye.
            for key in grouped.keys {
                grouped[key]?.sort { ($0.project, $0.name) < ($1.project, $1.name) }
            }
            contractsUpdated = file.updated; contractsByNetwork = grouped
            contractCount = file.contracts.count
        }
        loaded = true
    }

    func tokens(for network: TokenRegistryNetwork) -> [TokenRegistryEntry] { byNetwork[network.chain] ?? [] }
    func contracts(for network: TokenRegistryNetwork) -> [KnownContractEntry] { contractsByNetwork[network.chain] ?? [] }
}

/// What this app recognises without a network: the networks it reviews, the
/// tokens it can name, and the contract addresses its library identifies.
struct TokenDirectoryView: View {
    @StateObject private var directory = TokenDirectory()

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    NetworkLogo(network: .bitcoin, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bitcoin").font(.body)
                        Text("BTC · Single-sig and multisig").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(directory.networks) { network in
                    NavigationLink {
                        NetworkReferenceView(title: Text(verbatim: network.shortName),
                                             tokens: directory.tokens(for: network),
                                             contracts: directory.contracts(for: network))
                    } label: {
                        HStack(spacing: 14) {
                            if let brand = network.brand {
                                NetworkLogo(network: brand, size: 32)
                            } else {
                                GenericNetworkLogo(size: 32)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(network.name).font(.body)
                                summary(for: network).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("network." + network.key)
                }
            } header: {
                Text("Networks")
            } footer: {
                Text("Recognized tokens are shown with their name, icon and decimals when you review a request, entirely offline. Unknown tokens are shown by contract address with raw amounts. A listed token is not an endorsement. Registry \(directory.version).")
            }

            if !directory.everyChainContracts.isEmpty {
                Section {
                    NavigationLink {
                        NetworkReferenceView(title: Text("All EVM networks"), tokens: [],
                                             contracts: directory.everyChainContracts)
                    } label: {
                        HStack(spacing: 14) {
                            GenericNetworkLogo(size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All EVM networks").font(.body)
                                Text("\(directory.everyChainContracts.count) contracts at the same address on every network")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("contracts.everyChain")
                } header: {
                    Text("Known Public Contracts")
                } footer: {
                    contractsFooter
                }
            }
        }
        .listStyle(.insetGrouped)
        .listBottomInset()
        .navigationTitle("Networks, Tokens & Contracts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await directory.load() }
    }

    private var contractsFooter: Text {
        Text("\(directory.contractCount) contract addresses published by the projects themselves. When a request authorizes one of them, the review names it; when it authorizes an address that is not listed, the review says so. A listing identifies a deployment. It is not a judgement about the request. Updated \(directory.contractsUpdated).")
    }

    /// "ETH · 1,234 tokens · 329 contracts", leaving out whichever is zero and
    /// staying on one line. What "recognized" and "known" mean is in the
    /// section footers rather than repeated on every row. Built as Text so
    /// each part resolves in the chosen language.
    private func summary(for network: TokenRegistryNetwork) -> Text {
        var text = Text(verbatim: network.nativeSymbol)
        let tokens = directory.tokens(for: network).count
        let contracts = directory.contracts(for: network).count
        if tokens > 0 { text = text + Text(verbatim: " · ") + Text("\(tokens) tokens") }
        if contracts > 0 { text = text + Text(verbatim: " · ") + Text("\(contracts) contracts") }
        return text
    }
}

/// One network's offline reference data: the tokens the app can name and the
/// contracts its library identifies. Only the lists that have entries are
/// offered, so a contracts-only page carries no picker.
private struct NetworkReferenceView: View {
    let title: Text
    let tokens: [TokenRegistryEntry]
    let contracts: [KnownContractEntry]
    @State private var showsContracts: Bool
    @State private var query = ""

    init(title: Text, tokens: [TokenRegistryEntry], contracts: [KnownContractEntry]) {
        self.title = title; self.tokens = tokens; self.contracts = contracts
        _showsContracts = State(initialValue: tokens.isEmpty)
    }

    private var both: Bool { !tokens.isEmpty && !contracts.isEmpty }
    private var text: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var filteredTokens: [TokenRegistryEntry] {
        guard !text.isEmpty else { return tokens }
        return tokens.filter {
            $0.symbol.lowercased().contains(text) || $0.name.lowercased().contains(text)
                || $0.assetAddress.lowercased().hasPrefix(text)
        }
    }

    private var filteredContracts: [KnownContractEntry] {
        guard !text.isEmpty else { return contracts }
        return contracts.filter {
            $0.name.lowercased().contains(text) || $0.project.lowercased().contains(text)
                || $0.category.lowercased().contains(text) || $0.address.lowercased().contains(text)
        }
    }

    private var isEmpty: Bool { showsContracts ? filteredContracts.isEmpty : filteredTokens.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if both {
                Picker("", selection: $showsContracts) {
                    Text("\(tokens.count) Tokens").tag(false)
                    Text("\(contracts.count) Contracts").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 8)
                .accessibilityIdentifier("reference.picker")
            }
            List {
                if showsContracts {
                    ForEach(filteredContracts) { ContractRow(contract: $0) }
                } else {
                    ForEach(filteredTokens) { TokenRow(token: $0) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .background(Palette.background)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: showsContracts ? Text("Name, project or address") : Text("Symbol, name or address"))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TokenRow: View {
    let token: TokenRegistryEntry

    var body: some View {
        HStack(spacing: 12) {
            TokenIcon(icon: token.icon, symbol: token.symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: token.symbol).font(.body.weight(.semibold))
                    Text(verbatim: token.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(AddressFormatter.short(token.assetAddress, leading: 8, trailing: 6))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(token.decimals) dp").font(.caption2).foregroundStyle(.tertiary)
                .accessibilityLabel("\(token.decimals) decimals")
        }
        .contextMenu {
            Button("Copy Contract Address", systemImage: "doc.on.doc") { Clipboard.copy(token.assetAddress) }
        }
    }
}

/// A library entry: what it is, who published it, and the address itself.
/// Nothing here is verified at review time beyond the address matching.
private struct ContractRow: View {
    let contract: KnownContractEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: contract.systemImage)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: contract.name).font(.body.weight(.semibold)).lineLimit(2)
                Text(verbatim: contract.project + " · " + contract.category)
                    .font(.caption).foregroundStyle(.secondary)
                Text(AddressFormatter.short(contract.address, leading: 8, trailing: 6))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Copy Contract Address", systemImage: "doc.on.doc") { Clipboard.copy(contract.address) }
        }
    }
}
