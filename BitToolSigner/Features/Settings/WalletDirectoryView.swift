import SwiftUI

/// Every wallet the app names anywhere, with its site to copy. BitTool Signer
/// never opens a browser, so the site is text, not a link.
///
/// The notice at the top is the point of the page: these wallets support — or
/// say they support — BitTool Signer's QR formats, and anyone may claim that.
/// Nothing here is a security review.
struct WalletDirectoryView: View {
    private let wallets = CompatibleWallets.directory

    var body: some View {
        List {
            Section {
                Callout("Every wallet here supports, or says it supports, BitTool Signer's QR codes. Anyone can submit a wallet and claim that. We have not fully verified these claims and we do not audit, endorse or vouch for any of these wallets.", tone: .warning)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Callout("This page is information only. Check any wallet yourself before trusting it with money. BitTool is not responsible for anything that happens through another wallet — bugs, hacks, scams or losses of any kind.", tone: .info)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section {
                ForEach(wallets) { wallet in
                    row(wallet)
                }
            } header: {
                Text("\(wallets.count) wallets")
            } footer: {
                Text("The app never opens a browser. Copy the address and open it on another device.")
            }
            Section {
                NavigationLink { SubmitWalletView() } label: {
                    Label("Submit a Wallet", systemImage: "envelope")
                }
                .accessibilityIdentifier("directory.submit")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Wallets")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ wallet: CompatibleWallet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                WalletAppIcon(asset: wallet.asset, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(wallet.name).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(wallet.platforms).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SupportBadge(support: wallet.support)
            }
            CopyableText(text: wallet.site, label: "Copy address")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("directory.wallet." + wallet.name)
    }
}

/// What BitTool Signer can do with the wallet: sign through it, or only let it
/// watch an address.
private struct SupportBadge: View {
    let support: CompatibleWallet.Support

    var body: some View {
        switch support {
        case .signing:
            badge("Watch and sign by QR", "qrcode.viewfinder", Palette.success)
        case .watchOnly:
            badge("Watch only", "eye", Color.secondary)
        }
    }

    private func badge(_ title: LocalizedStringKey, _ symbol: String, _ color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line of plain text with a copy button, for anything that is not an address
/// (a site, an email) and so should not be grouped into address quads.
struct CopyableText: View {
    let text: String
    var label: LocalizedStringKey = "Copied"
    var font: Font = .footnote
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: text)
                .font(font.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Clipboard.copy(text); copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : label)
        }
    }
}
