import SwiftUI
import UniformTypeIdentifiers

struct SignatureResultView: View {
    @EnvironmentObject private var store: AppStore
    @State private var exporting = false
    @State private var exportError: String?
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Palette.success)
                        .symbolEffect(.bounce, value: appeared)
                        .accessibilityHidden(true)
                    Text("Signature Created").font(.title2.weight(.bold))
                        .accessibilityIdentifier("signature.title")
                    Text("Scan this code with the wallet that created the request.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
                if !store.signatureFrames.isEmpty {
                    QRCodeView(frames: store.signatureFrames, maxSide: 340)
                }
                if let review = store.review {
                    HStack(spacing: 12) {
                        if let asset = review.asset {
                            TokenIcon(icon: asset.icon, symbol: asset.symbol, size: 32)
                        } else if let brand = review.network?.brand {
                            NetworkLogo(network: brand, size: 32)
                        } else {
                            ChainLogo(chain: review.chain, size: 32)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(review.title).font(.subheadline.weight(.semibold))
                            if !review.summary.isEmpty {
                                Text(review.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .cardBackground(padding: 14)
                }
                if store.signaturePayload != nil || !store.signatureText.isEmpty { resultDetails }
                Callout("Signing doesn’t send anything. Your other wallet broadcasts the transaction, and it is only final once confirmed on the network.")
                if let exportError { Callout(verbatim: exportError, tone: .danger) }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 20)
            .readableWidth(560)
        }
        .background(Palette.background)
        .navigationTitle("Signature")
        .navigationBarTitleDisplayMode(.inline)
        .bottomActionBar(maxWidth: 560) {
            Button { withAnimation { store.clearRequest() } } label: { ActionLabel("Done", systemImage: "checkmark") }
                .prominentAction()
                .accessibilityIdentifier("signature.done")
        }
        .fileExporter(isPresented: $exporting, document: SignedResponseDocument(text: store.signatureText),
                      contentType: .plainText, defaultFilename: "bittool-signer-signature") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .sensoryFeedback(.success, trigger: appeared)
        .onAppear { appeared = true }
    }
}

extension SignatureResultView {
    /// What the QR carries (for reference) and the file export, kept out of the
    /// main action bar: Done is the one primary action.
    private var resultDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let view = store.signaturePayload {
                DetailLine(label: "Format", value: view.summary, monospaced: false)
                PayloadDisclosure(verbatim: view.title, text: view.text,
                                  notes: view.isPSBT ? ["psbt_base64 is the exact PSBT this QR code carries; decoded is read from it for reference."] : [],
                                  identifier: "signature.payload")
                Divider()
            }
            Button { exporting = true } label: {
                Label("Export as File", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(store.signatureText.isEmpty)
            .accessibilityIdentifier("signature.export")
        }
        .cardBackground()
    }
}

struct SignedResponseDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
