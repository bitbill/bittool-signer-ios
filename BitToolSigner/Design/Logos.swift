import SwiftUI
import CryptoKit

/// Networks with bundled, original vector logos. Other reviewed EVM networks
/// fall back to a neutral badge; logos never load from the network.
enum NetworkBrand: String, CaseIterable, Identifiable, Sendable {
    case bitcoin, ethereum, bnb, arbitrum, base, tron, solana
    var id: String { rawValue }

    var name: String {
        switch self {
        case .bitcoin: "Bitcoin"
        case .ethereum: "Ethereum"
        case .bnb: "BNB Smart Chain"
        case .arbitrum: "Arbitrum One"
        case .base: "Base"
        case .tron: "TRON"
        case .solana: "Solana"
        }
    }

    var shortName: String {
        switch self {
        case .bnb: "BNB Chain"
        case .arbitrum: "Arbitrum"
        default: name
        }
    }

    /// Native asset ticker used for fees and transfers.
    var nativeSymbol: String {
        switch self {
        case .bitcoin: "BTC"
        case .ethereum, .arbitrum, .base: "ETH"
        case .bnb: "BNB"
        case .tron: "TRX"
        case .solana: "SOL"
        }
    }

    var asset: String {
        switch self {
        case .bitcoin: "ChainBitcoin"
        case .ethereum: "ChainEthereum"
        case .bnb: "ChainBNB"
        case .arbitrum: "ChainArbitrum"
        case .base: "ChainBase"
        case .tron: "ChainTron"
        case .solana: "ChainSolana"
        }
    }

    var evmChainID: String? {
        switch self {
        case .ethereum: "1"
        case .bnb: "56"
        case .arbitrum: "42161"
        case .base: "8453"
        default: nil
        }
    }

    static func evm(chainID: String?) -> NetworkBrand? {
        guard let chainID else { return nil }
        return allCases.first { $0.evmChainID == chainID }
    }

    /// Networks that share one EVM account.
    static let evmNetworks: [NetworkBrand] = [.ethereum, .bnb, .arbitrum, .base]
}

extension Chain {
    var primaryNetwork: NetworkBrand {
        switch self {
        case .bitcoin: .bitcoin
        case .evm: .ethereum
        case .tron: .tron
        case .solana: .solana
        }
    }
}

struct NetworkLogo: View {
    let network: NetworkBrand
    var size: CGFloat = 28

    var body: some View {
        Image(network.asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: max(0.5, size / 56)))
            .accessibilityLabel(network.name)
    }
}

struct ChainLogo: View {
    let chain: Chain
    var size: CGFloat = 28
    var body: some View { NetworkLogo(network: chain.primaryNetwork, size: size) }
}

/// A chain family's mark. EVM shows its four headline networks as a 2×2 cluster.
struct ChainGlyph: View {
    let chain: Chain
    var size: CGFloat = 32

    var body: some View {
        if chain == .evm {
            let item = size * 0.5 - 1
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow { NetworkLogo(network: .ethereum, size: item); NetworkLogo(network: .bnb, size: item) }
                GridRow { NetworkLogo(network: .arbitrum, size: item); NetworkLogo(network: .base, size: item) }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("EVM networks")
        } else {
            ChainLogo(chain: chain, size: size)
        }
    }
}

/// Neutral badge for reviewed networks without a bundled logo.
struct GenericNetworkLogo: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .systemGray5))
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Overlapping network logos, each separated by a ring in the surrounding surface color.
struct NetworkLogoStack: View {
    var networks: [NetworkBrand] = NetworkBrand.allCases
    var size: CGFloat = 22
    var ring: Color = Palette.card

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(networks) { network in
                NetworkLogo(network: network, size: size)
                    .padding(max(1.5, size * 0.08))
                    .background(Circle().fill(ring))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(networks.map(\.shortName).joined(separator: ", "))
    }
}

/// Bundled token artwork, identified by the exact registry entry.
struct TokenIcon: View {
    /// Content hash of a bundled icon, from the token registry.
    let icon: String?
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = TokenIconStore.image(icon) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(uiColor: .systemGray5))
                    Text(String(symbol.prefix(3)).uppercased())
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityLabel(symbol)
    }
}

/// A deterministic identity color per wallet key. It helps people recognise the
/// same wallet across Wallets, review and authorization screens. It is a visual
/// aid only: signing always binds to the full key identity.
struct WalletAvatar: View {
    let identity: String
    let name: String
    var size: CGFloat = 44

    private var colors: [Color] {
        let bytes = Array(SHA256.hash(data: Data(identity.utf8)))
        let hue = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 65_535
        let shift = 0.08 + Double(bytes[2]) / 255 * 0.14
        return [Color(hue: hue, saturation: 0.62, brightness: 0.78),
                Color(hue: (hue + shift).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.62)]
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "W"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The app icon tile. Identical artwork is used by the launch screen so the
/// first SwiftUI frame continues the system launch image without a jump.
struct BrandTile: View {
    var size: CGFloat = 88
    var shadow = true
    var body: some View {
        Image("BrandTile").resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(shadow ? 0.16 : 0), radius: size * 0.1, y: size * 0.04)
            .accessibilityHidden(true)
    }
}
