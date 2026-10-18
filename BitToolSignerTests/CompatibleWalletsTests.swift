import Testing
import UIKit
@testable import BitToolSigner

struct CompatibleWalletsTests {
    private var every: [CompatibleWallet] { Chain.allCases.flatMap(CompatibleWallets.all(for:)) + CompatibleWallets.walletLevel }

    @Test func everyListedWalletHasABundledIconAndNoRemovedBrandRemains() {
        for wallet in every {
            #expect(UIImage(named: wallet.asset) != nil, "\(wallet.name) needs \(wallet.asset) in the asset catalog")
            #expect(!wallet.platforms.isEmpty)
        }
        let names = Set(every.map(\.name))
        #expect(!names.contains("Ownbit"))
        #expect(CompatibleWallets.walletLevel.map(\.name) == ["BitTool Wallet"], "BitTool Wallet is the wallet-level default.")
        #expect(!names.contains("Safe"), "Safe has no QR signer since its legacy iOS app was archived.")
    }

    @Test func bitcoinAccountExportsListHDWalletsThatSignByQR() {
        for profile in ["native", "taproot", "nested", "legacy"] {
            let wallets = CompatibleWallets.wallets(chain: .bitcoin, profile: profile, mode: "accountXpub")
            #expect(wallets.allSatisfy { $0.support == .signing })
            #expect(["Sparrow", "BlueWallet", "Nunchuk"].allSatisfy { name in wallets.contains { $0.name == name } })
            // ZEUS's LND wallet has no legacy (P2PKH) addresses.
            #expect(wallets.contains { $0.name == "ZEUS" } == (profile != "legacy"))
        }
        #expect(CompatibleWallets.wallets(chain: .bitcoin, profile: "multisig-native", mode: "accountXpub").allSatisfy { $0.support == .signing })
        #expect(CompatibleWallets.wallets(chain: .bitcoin, profile: "native", mode: "address").allSatisfy { $0.support == .watchOnly })
    }

    @Test func addressExportsAndTronAreWatchOnly() {
        for chain in [Chain.evm, .solana] {
            #expect(CompatibleWallets.wallets(chain: chain, profile: "standard", mode: "address").allSatisfy { $0.support == .watchOnly })
            #expect(CompatibleWallets.wallets(chain: chain, profile: "standard", mode: "wallet").allSatisfy { $0.support == .signing })
        }
        let tron = CompatibleWallets.wallets(chain: .tron, profile: "standard", mode: "address")
        #expect(!tron.isEmpty && tron.allSatisfy { $0.support == .watchOnly })
        // TokenPocket watches TRX and SOL addresses, and signs EVM by EIP-4527 QR.
        #expect(tron.contains { $0.name == "TokenPocket" })
        #expect(CompatibleWallets.wallets(chain: .solana, profile: "standard", mode: "address").contains { $0.name == "TokenPocket" })
        #expect(CompatibleWallets.wallets(chain: .evm, profile: "standard", mode: "wallet").contains { $0.name == "TokenPocket" && $0.support == .signing })
    }

    @Test func settingsListsEachWalletOncePerChainWithSigningFirst() {
        for chain in Chain.allCases {
            let all = CompatibleWallets.all(for: chain)
            #expect(Set(all.map(\.name)).count == all.count)
            let firstWatch = all.firstIndex { $0.support == .watchOnly } ?? all.count
            #expect(all[..<firstWatch].allSatisfy { $0.support == .signing })
        }
    }
}
