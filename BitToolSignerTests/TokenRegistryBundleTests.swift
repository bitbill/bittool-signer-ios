import CryptoKit
import Foundation
import Testing
import UIKit
@testable import BitToolSigner

/// The bundled token registry and the artwork it points at. Everything here is
/// public metadata; the test is about what the app ships, not about any wallet.
struct TokenRegistryBundleTests {
    private struct File: Decodable {
        let registryVersion: String
        let networks: [TokenRegistryNetwork]
        let assets: [TokenRegistryEntry]
    }

    private func registry() throws -> File {
        let url = try #require(Bundle.main.url(forResource: "token-registry", withExtension: "json"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    @Test func registryCoversEveryNetworkItListsWithTheCountsItClaims() throws {
        let file = try registry()
        #expect(file.assets.count > 3000)
        #expect(file.networks.count == 10)
        var perChain: [String: Int] = [:]
        for asset in file.assets { perChain[asset.chainFamily + ":" + (asset.chainId ?? ""), default: 0] += 1 }
        for network in file.networks {
            #expect(network.tokens == perChain[network.chain], "\(network.key)")
            #expect(!network.name.isEmpty && !network.nativeSymbol.isEmpty)
        }
        // The four EVM networks with wallet-level artwork, plus TRON and Solana.
        #expect(file.networks.compactMap(\.brand).count == 6)
        #expect(file.networks.first { $0.key == "polygon" }?.brand == nil)
    }

    @Test func everyTokenIconResolvesToItsOwnArtwork() throws {
        let file = try registry()
        #expect(TokenIconStore.count > 1500)
        let ids = Set(file.assets.map(\.icon))
        #expect(ids.count == TokenIconStore.count, "the pack must hold exactly the icons the registry uses")
        for icon in ids.prefix(50) {
            let image = try #require(TokenIconStore.image(icon), "\(icon)")
            #expect(image.size.width > 0 && image.size.width <= 128)
        }
    }

    @Test func iconsAreAddressedByTheirContentAndSharedBetweenChains() throws {
        let file = try registry()
        let usdt = try #require(file.assets.first { $0.chainId == "1" && $0.symbol == "USDT" })
        let tronUSDT = try #require(file.assets.first { $0.chainFamily == "tron" && $0.symbol == "USDT" })
        #expect(usdt.icon == tronUSDT.icon, "one image serves the same token on every chain")
        let url = try #require(Bundle.main.url(forResource: "TokenIcons", withExtension: "pack"))
        let index = try JSONDecoder().decode([String: [Int]].self,
                                             from: Data(contentsOf: #require(Bundle.main.url(forResource: "TokenIcons.index", withExtension: "json"))))
        let range = try #require(index[usdt.icon])
        let bytes = try Data(contentsOf: url).subdata(in: range[0] ..< (range[0] + range[1]))
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().hasPrefix(usdt.icon))
    }

    @Test func unknownAndEmptyIconsHaveNoImage() {
        #expect(TokenIconStore.image(nil) == nil)
        #expect(TokenIconStore.image("") == nil)
        #expect(TokenIconStore.image("0000000000000000") == nil)
        #expect(TokenIconStore.image("../../etc/passwd") == nil)
    }
}
