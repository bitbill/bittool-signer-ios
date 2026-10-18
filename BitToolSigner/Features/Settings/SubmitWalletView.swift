import SwiftUI

/// How to put a wallet on the compatibility list. The app has no network and
/// opens no mail client, so every part of the message is text to copy.
struct SubmitWalletView: View {
    private static let address = "support@bittool.com"
    private static let subject = "Add supported wallet"

    var body: some View {
        List {
            Section {
                Text("Does your wallet read BitTool Signer's QR codes? Send us the details and we will add it to the list. Anyone can submit a wallet, including its own developers.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Email") {
                labelled("To", Self.address, copy: "Copy address")
                labelled("Subject", Self.subject, copy: "Copy address")
            }
            Section {
                ForEach(Self.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Include at least")
            } footer: {
                Text("The app never opens a browser. Copy the address and open it on another device.")
            }
            Section {
                Callout("Being listed is not a review or an endorsement. We do not audit the wallets people submit, and BitTool is not responsible for what happens through them.", tone: .info)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Submit a Wallet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func labelled(_ title: LocalizedStringKey, _ value: String, copy: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            CopyableText(text: value, label: copy, font: .callout)
        }
        .padding(.vertical, 2)
    }

    private struct Item: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private static let items: [Item] = [
        Item(id: "name", title: "Wallet name", detail: "The name as it is published."),
        Item(id: "site", title: "Official website", detail: "The address the wallet itself publishes."),
        Item(id: "icon", title: "App icon", detail: "A link to the image, or attach it. A square icon of at least 512 px."),
        Item(id: "source", title: "Source code", detail: "A link to the repository, if the wallet is open source."),
        Item(id: "formats", title: "QR formats supported",
             detail: "Which of these the wallet reads: Wallet Level, and Coin Level for Bitcoin, EVM, TRON or Solana."),
    ]
}
