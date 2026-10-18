import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Collects QR frames for one request. Each new frame is handed to the engine's
/// scan session once, in order; frames arriving during a decode are queued so
/// fast animated codes never lose parts.
@MainActor
final class ScanSession: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var received = 0
    @Published private(set) var processing = false
    @Published var error: String?
    private var seen = Set<String>()
    private var queue: [String] = []
    private var token = UUID()
    private var ready = false
    private var onComplete: (@MainActor () -> Void)?

    var status: String? {
        if processing && received == 1 { return "Reading request…" }
        if received > 1 && progress < 1 { return "Keep the animated code in view · \(received) parts" }
        return nil
    }

    func start(store: AppStore) {
        reset()
        let id = token
        Task {
            do {
                try await store.beginScan()
                guard token == id else { return }
                ready = true
                // Frames seen while the session was starting are processed now.
                if let onComplete { drain(store: store, completed: onComplete) }
            } catch {
                if token == id { self.error = error.localizedDescription }
            }
        }
    }

    func stop(store: AppStore) {
        reset()
        Task { await store.endScan() }
    }

    func reset() {
        token = UUID(); seen = []; queue = []; progress = 0; received = 0
        processing = false; error = nil; ready = false; onComplete = nil
    }

    func receive(_ frame: String, store: AppStore, completed: @escaping @MainActor () -> Void) {
        guard error == nil, store.review == nil, seen.insert(frame).inserted else { return }
        onComplete = completed
        received += 1
        queue.append(frame)
        drain(store: store, completed: completed)
    }

    private func drain(store: AppStore, completed: @escaping @MainActor () -> Void) {
        guard ready, !processing, error == nil, !queue.isEmpty else { return }
        let frame = queue.removeFirst()
        processing = true
        let id = token, epoch = store.securityEpoch
        Task { @MainActor in
            let outcome: Result<Double, Error>
            do { outcome = .success(try await store.receive(frame: frame)) }
            catch { outcome = .failure(error) }
            guard token == id else { return }
            processing = false
            guard epoch == store.securityEpoch else {
                // Interrupted by backgrounding: retry this part with the next frame.
                queue.insert(frame, at: 0); return
            }
            switch outcome {
            case .success(let value):
                progress = max(progress, value)
                if store.review != nil { completed() } else { drain(store: store, completed: completed) }
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                self.error = error.localizedDescription
                queue = []
            }
        }
    }
}

struct ScanTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.hasSignedResponse {
                    SignatureResultView()
                } else if store.review != nil {
                    RequestReviewView()
                } else {
                    ScanHomeView()
                }
            }
            .animation(.smooth(duration: 0.3), value: store.review?.requestHash)
            .animation(.smooth(duration: 0.3), value: store.hasSignedResponse)
        }
    }
}

struct ScanHomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: AppRouter
    @State private var handledScanRequest = 0
    @StateObject private var session = ScanSession()
    @State private var scanning = false
    @State private var pasting = false
    @State private var importing = false
    @State private var error: String?
    @State private var busy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                scanCard
                HStack(spacing: 12) {
                    optionTile("Paste Request", "doc.on.clipboard", id: "signing.paste") { pasting = true }
                    optionTile("Import File", "doc.badge.plus", id: "signing.file") { importing = true }
                }
                if let error { Callout(verbatim: error, tone: .danger) }
                VStack(alignment: .leading, spacing: 16) {
                    Text("How signing works").font(.headline)
                    StepRow(number: 1, title: "Scan", detail: "Your watch-only wallet shows the unsigned request as a QR code.", systemImage: "qrcode.viewfinder")
                    StepRow(number: 2, title: "Review", detail: "BitTool Signer decodes it and finds the matching wallet on this device.", systemImage: "text.magnifyingglass")
                    StepRow(number: 3, title: "Authorize", detail: "Enter that wallet’s password to sign.", systemImage: "lock.fill")
                    StepRow(number: 4, title: "Return", detail: "Scan the signature back. Your other wallet broadcasts it.", systemImage: "arrow.uturn.left")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground(padding: 18)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .background(Palette.background)
        .navigationTitle("Scan")
        .fullScreenCover(isPresented: $scanning, onDismiss: { session.stop(store: store) }) {
            QRScannerView(progress: session.progress, status: session.status, error: session.error,
                          onReset: { session.start(store: store) }) { frame in
                session.receive(frame, store: store) { scanning = false }
            }
            .onAppear { session.start(store: store) }
        }
        .sheet(isPresented: $pasting) { PasteRequestSheet() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText, .json], allowsMultipleSelection: false) { result in
            importFile(result)
        }
        .onChange(of: store.securityEpoch) { _, _ in busy = false }
        // Asked for from elsewhere (the Wallets toolbar): open the camera, not
        // just this page. The tab's content is built the first time it is
        // shown, which is after the request was made, so `onChange` alone would
        // miss it: the token is reconciled on appear as well.
        .onAppear { openCameraIfAsked() }
        .onChange(of: router.scanRequest) { _, _ in openCameraIfAsked() }
    }

    /// Opens the camera once per request from elsewhere, never while a request
    /// is already being reviewed.
    private func openCameraIfAsked() {
        guard router.scanRequest != handledScanRequest else { return }
        handledScanRequest = router.scanRequest
        guard store.review == nil, !scanning else { return }
        error = nil
        scanning = true
    }

    private var scanCard: some View {
        Button {
            error = nil; scanning = true
        } label: {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 128, height: 128)
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 62, weight: .regular))
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                }
                .padding(.top, 8)
                VStack(spacing: 6) {
                    Text("Scan a Signing Request").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text("Show the unsigned transaction or message as a QR code in your other wallet.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label("Open Camera", systemImage: "camera.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: Capsule())
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityLabel("Scan signing request")
        .accessibilityIdentifier("signing.scan")
    }

    private func optionTile(_ title: LocalizedStringKey, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        .disabled(busy)
        .accessibilityIdentifier(id)
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 512_000 else { throw AppIssue.message(String(localized: "This file is larger than 512 KB.", bundle: AppText.bundle)) }
            let data = try Data(contentsOf: url)
            let text: String
            if data.starts(with: [0x70, 0x73, 0x62, 0x74, 0xff]) { text = data.base64EncodedString() }
            else if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
            else { throw AppIssue.message(String(localized: "Choose a PSBT file or a text file containing a UR request.", bundle: AppText.bundle)) }
            submit(text)
        } catch { self.error = error.localizedDescription }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        busy = true; error = nil
        let epoch = store.securityEpoch
        Task {
            do { try await store.importPayload(text) }
            catch { if epoch == store.securityEpoch, !(error is CancellationError) { self.error = error.localizedDescription } }
            busy = false
        }
    }
}

/// Subtle press feedback for large tappable cards.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct PasteRequestSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var payload = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Paste a PSBT (Base64 or hex) or a UR signing request. Multi-part UR requests can be pasted one part per line.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $payload)
                        .font(.footnote.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(10)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityIdentifier("signing.payload")
                    Button {
                        if let text = UIPasteboard.general.string { payload = text }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .font(.subheadline.weight(.semibold))
                    if let error { Callout(verbatim: error, tone: .danger) }
                }
                .padding(Metrics.pagePadding)
            }
            .background(Palette.background)
            .bottomActionBar {
                Button(action: submit) { ActionLabel("Review Request", busy: busy) }
                    .prominentAction()
                    .disabled(busy || payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("signing.decode")
            }
            .navigationTitle("Paste Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { payload = ""; dismiss() } }
            }
        }
        .onChange(of: store.securityEpoch) { _, _ in busy = false }
    }

    private func submit() {
        guard !busy else { return }
        busy = true; error = nil
        let text = payload, epoch = store.securityEpoch
        Task {
            do {
                try await store.importPayload(text)
                payload = ""; dismiss()
            } catch {
                if epoch == store.securityEpoch, !(error is CancellationError) { self.error = error.localizedDescription }
            }
            busy = false
        }
    }
}
