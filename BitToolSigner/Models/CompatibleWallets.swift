import Foundation

/// Wallets that work with a BitTool Signer export, taken only from primary sources:
/// each wallet's documentation or source code, or the official QR hardware-wallet
/// guide and firmware that use the same formats (researched September 2026;
/// sources in docs/Compatibility.md). Listing a wallet is not a certification: people
/// should always compare the first address in both apps.
struct CompatibleWallet: Identifiable, Hashable {
    enum Support: Hashable {
        /// Imports the export by QR, sends unsigned requests to BitTool Signer by QR
        /// and takes the signature back the same way.
        case signing
        /// Can watch the account or address only. Its own cold-wallet signing,
        /// if any, uses a protocol BitTool Signer does not speak.
        case watchOnly
    }

    let name: String
    let asset: String
    let platforms: String
    let support: Support
    /// The wallet's own site, shown for copying: BitTool Signer never opens a
    /// browser. Each one was checked against the live site (October 2026).
    var site: String { CompatibleWallets.sites[name] ?? "" }
    var id: String { name }
}

enum CompatibleWallets {
    /// Each wallet's own site. Checked against the live site in October 2026;
    /// shown only so someone can copy it and look the wallet up on a device
    /// that has a network. A listing is not a recommendation — see the notice
    /// on the directory page.
    static let sites: [String: String] = [
        "Sparrow": "sparrowwallet.com",
        "BlueWallet": "bluewallet.io",
        "Nunchuk": "nunchuk.io",
        "Bitcoin Keeper": "bitcoinkeeper.app",
        "BULL Bitcoin": "bullbitcoin.com",
        "Specter": "specter.solutions",
        "Bitcoin Safe": "bitcoin-safe.org",
        "ZEUS": "zeusln.com",
        "Electrum": "electrum.org",
        "MetaMask": "metamask.io",
        "Rabby": "rabby.io",
        "imToken": "token.im",
        "TokenPocket": "tokenpocket.pro",
        "Ambire": "ambire.com",
        "OKX Wallet": "web3.okx.com",
        "Trust Wallet": "trustwallet.com",
        "Solflare": "solflare.com",
        "Helium Wallet": "wallet.helium.com",
        "Phantom": "phantom.com",
        "Backpack": "backpack.exchange",
        "Jupiter": "jup.ag",
        "TronLink": "tronlink.org",
        "OneKey": "onekey.so",
        "BitTool Wallet": "bittool.com/wallet",
    ]

    private static func signing(_ name: String, _ asset: String, _ platforms: String) -> CompatibleWallet {
        CompatibleWallet(name: name, asset: asset, platforms: platforms, support: .signing)
    }
    private static func watching(_ name: String, _ asset: String, _ platforms: String) -> CompatibleWallet {
        CompatibleWallet(name: name, asset: asset, platforms: platforms, support: .watchOnly)
    }

    // Bitcoin: `crypto-account` with the account xpub, then `crypto-psbt`.
    static let bitcoinAccount = [
        signing("Sparrow", "wallet_sparrow", "Desktop"),
        signing("BlueWallet", "wallet_bluewallet", "iOS · Android"),
        signing("Nunchuk", "wallet_nunchuk", "iOS · Android"),
        signing("Bitcoin Keeper", "wallet_keeper", "iOS · Android"),
        signing("BULL Bitcoin", "wallet_bull", "iOS · Android"),
        signing("Specter", "wallet_specter", "Desktop"),
        signing("Bitcoin Safe", "wallet_bitcoinsafe", "Desktop"),
    ]
    /// ZEUS reads single-sig accounts through its LND wallet, which has no legacy addresses.
    static let zeus = signing("ZEUS", "wallet_zeus", "iOS · Android")
    static let bitcoinCosigner = [
        signing("Sparrow", "wallet_sparrow", "Desktop"),
        signing("BlueWallet", "wallet_bluewallet", "iOS · Android"),
        signing("Nunchuk", "wallet_nunchuk", "iOS · Android"),
        signing("Bitcoin Keeper", "wallet_keeper", "iOS · Android"),
        signing("Specter", "wallet_specter", "Desktop"),
        signing("Bitcoin Safe", "wallet_bitcoinsafe", "Desktop"),
    ]
    static let bitcoinAddress = [
        watching("BlueWallet", "wallet_bluewallet", "iOS · Android"),
        watching("Electrum", "wallet_electrum", "Desktop · Android"),
    ]

    // EVM: `crypto-hdkey` (EIP-4527), then `eth-sign-request` / `eth-signature`.
    static let evmAccount = [
        signing("MetaMask", "wallet_metamask", "Extension · iOS · Android"),
        signing("Rabby", "wallet_rabby", "Extension · iOS · Android"),
        signing("imToken", "wallet_imtoken", "iOS · Android"),
        signing("TokenPocket", "wallet_tokenpocket", "iOS · Android"),
        signing("Ambire", "wallet_ambire", "Extension"),
    ]
    static let evmAddress = [
        watching("Rabby", "wallet_rabby", "Extension · iOS · Android"),
        watching("TokenPocket", "wallet_tokenpocket", "iOS · Android"),
        watching("OKX Wallet", "wallet_okx", "iOS · Android · Extension"),
        watching("Trust Wallet", "wallet_trust", "iOS · Android"),
    ]

    // Solana: `crypto-multi-accounts`, then `sol-sign-request` / `sol-signature`.
    static let solanaAccount = [
        signing("Solflare", "wallet_solflare", "Extension · iOS · Android"),
        signing("Helium Wallet", "wallet_helium", "iOS · Android"),
    ]
    static let solanaAddress = [
        watching("Phantom", "wallet_phantom", "Extension · iOS · Android"),
        watching("Backpack", "wallet_backpack", "Extension"),
        watching("Jupiter", "wallet_jupiter", "Extension · iOS · Android"),
        watching("OKX Wallet", "wallet_okx", "iOS · Android · Extension"),
        watching("TokenPocket", "wallet_tokenpocket", "iOS · Android"),
    ]

    // TRON: address only. No mainstream wallet currently sends TRON transactions
    // to a QR signer in the `tron-sign-request` format.
    static let tronAddress = [
        watching("TokenPocket", "wallet_tokenpocket", "iOS · Android · Extension"),
        watching("TronLink", "wallet_tronlink", "iOS · Android"),
        watching("OKX Wallet", "wallet_okx", "iOS · Android"),
        watching("OneKey", "wallet_onekey", "iOS · Android"),
    ]

    // Wallet level: one `bittool-signer-wallet` v1 QR for all four chains (docs/Wallet-Pairing-v1.md).
    // BitTool Wallet (BITTOOL PTE. LTD.) is the wallet this format is designed with.
    static let walletLevel = [
        signing("BitTool Wallet", "wallet_bittool", "iOS · Android"),
    ]

    /// Wallets for one export on the Connect page.
    static func wallets(chain: Chain, profile: String, mode: String) -> [CompatibleWallet] {
        switch chain {
        case .bitcoin:
            if profile.hasPrefix("multisig-") { return bitcoinCosigner }
            if mode == "address" { return bitcoinAddress }
            return profile == "legacy" ? bitcoinAccount : bitcoinAccount + [zeus]
        case .evm:
            return mode == "address" ? evmAddress : evmAccount
        case .solana:
            return mode == "address" ? solanaAddress : solanaAccount
        case .tron:
            return tronAddress
        }
    }

    /// Every wallet the app lists anywhere, in one alphabetical directory.
    /// A wallet that both signs and watches is listed once, as a signer.
    static var directory: [CompatibleWallet] {
        let lists = [walletLevel, bitcoinAccount, [zeus], bitcoinCosigner, bitcoinAddress,
                     evmAccount, evmAddress, solanaAccount, solanaAddress, tronAddress]
        var best: [String: CompatibleWallet] = [:]
        for wallet in lists.joined() {
            if let existing = best[wallet.name], existing.support == .signing { continue }
            best[wallet.name] = wallet
        }
        return best.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every listed wallet for a chain, signing wallets first, without duplicates.
    static func all(for chain: Chain) -> [CompatibleWallet] {
        let lists: [[CompatibleWallet]] = switch chain {
        case .bitcoin: [bitcoinAccount, [zeus], bitcoinCosigner, bitcoinAddress]
        case .evm: [evmAccount, evmAddress]
        case .solana: [solanaAccount, solanaAddress]
        case .tron: [tronAddress]
        }
        var seen = Set<String>(), result: [CompatibleWallet] = []
        for wallet in lists.joined() where seen.insert(wallet.name).inserted { result.append(wallet) }
        return result
    }
}
