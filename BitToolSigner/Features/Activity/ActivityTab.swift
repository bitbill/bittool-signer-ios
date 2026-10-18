import SwiftUI
import UniformTypeIdentifiers

struct ActivityTab: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmClear = false

    private var sections: [(day: Date, receipts: [SigningReceipt])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.receipts) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in (day, grouped[day]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.receipts.isEmpty {
                    ContentUnavailableView {
                        Label("No Signatures Yet", systemImage: "signature")
                    } description: {
                        Text("Signatures you create on this device are listed here. BitTool Signer never broadcasts transactions.")
                    }
                    .background(Palette.background)
                } else {
                    List {
                        ForEach(sections, id: \.day) { section in
                            Section(header: Text(section.day, format: .dateTime.weekday(.wide).month().day().year())) {
                                ForEach(section.receipts) { receipt in
                                    NavigationLink(value: receipt) { ActivityRow(receipt: receipt) }
                                        .accessibilityIdentifier("activity.row")
                                }
                            }
                        }
                        Section {
                        } footer: {
                            Text("A local record of signatures created on this device. Check broadcast and confirmation in your other wallet.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .listBottomInset()
                }
            }
            .navigationTitle("Activity")
            .navigationDestination(for: SigningReceipt.self) { ActivityDetailView(receipt: $0) }
            .toolbar {
                if !store.receipts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { confirmClear = true }
                            .accessibilityIdentifier("activity.clear")
                    }
                }
            }
            .confirmationDialog("Clear all activity?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Activity", role: .destructive) { store.clearHistory() }
            } message: {
                Text("This only removes the local records. It does not affect any transaction.")
            }
            .onChange(of: store.securityEpoch) { _, _ in confirmClear = false }
        }
    }
}

private struct ActivityRow: View {
    let receipt: SigningReceipt
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            ReceiptLogo(receipt: receipt, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(receipt.date, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let summary = receipt.summary, !summary.isEmpty { parts.append(summary) }
        if let id = receipt.walletID { parts.append(store.walletLabel(for: id)) }
        return parts.joined(separator: " · ")
    }
}

private struct ReceiptLogo: View {
    let receipt: SigningReceipt
    var size: CGFloat
    private var brand: NetworkBrand? {
        receipt.chain == .evm ? NetworkBrand.evm(chainID: receipt.chainID) : receipt.chain.primaryNetwork
    }

    var body: some View {
        if let brand {
            NetworkLogo(network: brand, size: size)
        } else {
            GenericNetworkLogo(size: size)
        }
    }
}

/// One signature as it was made: the metadata, the request that went in and the
/// signature that came out. The request is reviewed again on this device rather
/// than replayed from a stored summary, so the decoded fields are the same ones
/// the review screen showed, and the signature can be handed back to the wallet
/// that asked for it.
struct ActivityDetailView: View {
    let receipt: SigningReceipt
    @EnvironmentObject private var store: AppStore
    @State private var decoded: TransactionReview?
    @State private var decodeError: String?
    @State private var showingQR = false
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    ReceiptLogo(receipt: receipt, size: 56)
                    Text(receipt.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                    if let summary = receipt.summary, !summary.isEmpty {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    receipt.resultType.map { StatusPill(verbatim: $0, systemImage: "checkmark.seal.fill", color: Palette.success) }
                        ?? StatusPill(text: "Signature created", systemImage: "checkmark.seal.fill", color: Palette.success)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Date", value: receipt.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Network", value: receipt.networkName ?? receipt.chain.name)
                if let id = receipt.walletID {
                    LabeledContent("Wallet", value: store.wallet(id) == nil ? "Deleted wallet" : store.walletLabel(for: id))
                }
                if let fingerprint = receipt.masterFingerprint ?? receipt.walletID.flatMap({ store.publicMetadata(for: $0)?.masterFingerprint }) {
                    LabeledContent("Fingerprint", value: fingerprint.uppercased())
                }
                if let risk = receipt.riskLevel, risk != "normal" {
                    LabeledContent("Risk", value: risk == "high" ? "High" : "Warnings shown")
                }
            }
            Section {
                HashText(value: receipt.requestHash)
            } header: {
                Text("Request fingerprint")
            } footer: {
                Text("BitTool Signer does not broadcast. Whether this transaction was sent or confirmed is only known to your other wallet and the network.")
            }
            input
            output
            if !receipt.hasPayloads {
                Section {
                } footer: {
                    Text("The request and signature are kept for the \(SigningReceipt.payloadRetention) most recent signatures. This one is older, so only its summary remains.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listBottomInset()
        .navigationTitle("Signature")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: receipt.id) { await decode() }
        .sheet(isPresented: $showingQR) {
            SignatureQRSheet(receipt: receipt)
        }
        .fileExporter(isPresented: $exporting, document: SignedResponseDocument(text: receipt.responseText ?? ""),
                      contentType: .plainText, defaultFilename: "bittool-signer-signature") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    // MARK: Input

    @ViewBuilder private var input: some View {
        if let json = receipt.requestJSON {
            Section {
                if let decoded {
                    ForEach(Self.essentials(of: decoded)) { line in
                        LabeledContent(line.label) { Text(verbatim: line.value).multilineTextAlignment(.trailing) }
                    }
                    NavigationLink {
                        SignedRequestView(review: decoded, title: receipt.title)
                    } label: {
                        Label("All Decoded Fields", systemImage: "list.bullet.rectangle.portrait")
                    }
                    .accessibilityIdentifier("activity.decoded")
                } else if let decodeError {
                    Label(decodeError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Palette.warning)
                } else {
                    HStack(spacing: 10) { ProgressView(); Text("Decoding again…").foregroundStyle(.secondary) }
                }
                PayloadDisclosure(title: "Request Payload", text: json, identifier: "activity.request")
            } header: {
                Text("Input")
            } footer: {
                Text("The exact request that was signed. It is decoded again on this device, and its fingerprint must still match the one above.")
            }
        }
    }

    /// The few decoded facts worth repeating in a list row. Everything else is
    /// one tap away, whole, in All Decoded Fields.
    struct Essential: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let value: String
    }

    static func essentials(of review: TransactionReview) -> [Essential] {
        var lines = [Essential(id: "action", label: "Action", value: review.display?.action ?? review.title)]
        if let display = review.display {
            if let amount = display.amount {
                lines.append(Essential(id: "amount", label: "Amount",
                                       value: [amount, display.symbol].compactMap { $0 }.joined(separator: " ")))
            }
            if let counterparty = display.counterparty {
                // The engine's own caption ("Spender", "Operator", "To").
                lines.append(Essential(id: "counterparty", label: LocalizedStringKey(display.counterpartyLabel ?? "To"),
                                       value: AddressFormatter.short(counterparty, leading: 6, trailing: 6)))
            }
            if let fee = display.fee {
                // The same distinction the pre-sign review makes: an energy
                // budget is not a ceiling on the whole fee, so the history
                // never captions it as one either.
                let energy = display.feeKind == "energyBudget"
                lines.append(Essential(id: "fee", label: energy ? "Energy budget" : "Network fee",
                                       value: energy ? ReviewText.shortDecimal(fee) : fee))
            }
        }
        return lines
    }

    // MARK: Output

    @ViewBuilder private var output: some View {
        if receipt.responseText != nil || receipt.responseFrames?.isEmpty == false {
            Section {
                if receipt.responseFrames?.isEmpty == false {
                    Button { showingQR = true } label: {
                        Label("Show QR Code", systemImage: "qrcode")
                    }
                    .accessibilityIdentifier("activity.showQR")
                }
                if let text = receipt.responseText, !text.isEmpty {
                    Button { exporting = true } label: {
                        Label("Export as File", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("activity.export")
                    PayloadDisclosure(title: "Signature Payload", text: text, identifier: "activity.signature")
                }
                if let exportError {
                    Text(verbatim: exportError).font(.footnote).foregroundStyle(Palette.danger)
                }
            } header: {
                Text("Output")
            } footer: {
                Text("The signature exactly as it was produced. Showing it again creates nothing new: the same code can be scanned by the wallet that made the request.")
            }
        }
    }

    private func decode() async {
        guard let json = receipt.requestJSON, decoded == nil else { return }
        do { decoded = try await store.review(storedRequest: json, expecting: receipt.requestHash) }
        catch {
            if !(error is CancellationError) { decodeError = error.localizedDescription }
        }
    }
}

/// The stored request reviewed again, laid out exactly as the review screen
/// lays it out. Nothing here can be signed: it is a record, not a request.
private struct SignedRequestView: View {
    let review: TransactionReview
    let title: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ReviewSummaryCard(review: review)
                if let contract = review.contract, !ReviewSummaryCard.showsNotice(for: review) {
                    ContractNotice(contract: contract)
                }
                ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                    Callout(verbatim: warning, tone: warning.uppercased().hasPrefix("HIGH") ? .danger : .warning)
                }
                ReviewDetailsCard(fields: review.fields)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 20)
            .readableWidth()
        }
        .background(Palette.background)
        .navigationTitle("Signed Request")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The signature QR again, for a wallet that did not finish scanning it.
private struct SignatureQRSheet: View {
    let receipt: SigningReceipt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    QRCodeView(frames: receipt.responseFrames ?? [], maxSide: 320)
                        .padding(.top, 8)
                    Callout("This is the signature that was already created. Scanning it again signs nothing new.")
                }
                .padding(Metrics.pagePadding)
                .readableWidth(520)
            }
            .background(Palette.background)
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
