import SwiftUI
import AVFoundation

/// Full-screen camera for signing requests and recovery QR codes. Frames are
/// passed on unchanged; decoding and validation happen in the offline engine.
/// What the scanner is reading; it only changes the wording of scan problems.
enum QRScanPurpose { case signingRequest, recoveryPhrase }

struct QRScannerView: View {
    var title: LocalizedStringKey = "Scan Request"
    var hint: LocalizedStringKey = "Point the camera at the QR code in your other wallet."
    var purpose: QRScanPurpose = .signingRequest
    var progress: Double = 0
    var status: String?
    var error: String?
    var onReset: (() -> Void)?
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var cameraError: String?
    @State private var torchOn = false
    @State private var torchAvailable = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if authorization == .authorized && scenePhase == .active {
                CameraPreview(torchOn: torchOn, purpose: purpose,
                              onScan: { value in cameraError = nil; onScan(value) },
                              onError: { cameraError = $0 },
                              onTorchAvailability: { torchAvailable = $0 })
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            ViewfinderOverlay(progress: progress, active: authorization == .authorized)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack {
                topBar
                Spacer()
                statusPanel
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task {
            if authorization == .notDetermined {
                authorization = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization = AVCaptureDevice.authorizationStatus(for: .video) }
            if phase != .active { torchOn = false }
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .modifier(GlassCircle())
            Spacer()
            Text(title).font(.headline).foregroundStyle(.white)
            Spacer()
            Button { torchOn.toggle() } label: {
                Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel(torchOn ? "Turn off flashlight" : "Turn on flashlight")
            .modifier(GlassCircle())
            .opacity(torchAvailable ? 1 : 0)
            .disabled(!torchAvailable)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var statusPanel: some View {
        VStack(spacing: 12) {
            if authorization == .denied || authorization == .restricted {
                Image(systemName: "camera.fill").font(.title).foregroundStyle(.secondary)
                Text("Camera Access Needed").font(.headline)
                Text("Allow camera access in Settings to scan QR codes, or import the request as a file or pasted text.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { UIApplication.shared.open(url) }
                        .buttonStyle(.borderedProminent).tint(Brand.mint).foregroundStyle(Brand.ink)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange).multilineTextAlignment(.center)
                    .accessibilityIdentifier("scanner.protocolError")
                if let onReset {
                    Button("Scan Again") { onReset() }
                        .buttonStyle(.borderedProminent).tint(Brand.mint).foregroundStyle(Brand.ink)
                        .accessibilityIdentifier("scanner.reset")
                }
            } else {
                if progress > 0 && progress < 1 {
                    ProgressView(value: progress).tint(Brand.mint).frame(maxWidth: 220)
                    Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("scanner.progress")
                }
                (status.map(Text.init(verbatim:)) ?? Text(hint))
                    .font(.subheadline).multilineTextAlignment(.center)
                    .accessibilityIdentifier("scanner.status")
                if let cameraError {
                    Text(cameraError).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .accessibilityIdentifier("scanner.cameraError")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.smooth(duration: 0.2), value: error)
        .animation(.smooth(duration: 0.2), value: progress)
    }
}

private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Dimmed surround with a clear square window, corner brackets and a progress ring.
private struct ViewfinderOverlay: View {
    let progress: Double
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 64, proxy.size.height * 0.5, 340)
            let rect = CGRect(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2 - 20, width: side, height: side)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 28, height: 28), style: .continuous)
                }
                .fill(Color.black.opacity(active ? 0.55 : 0.8), style: FillStyle(eoFill: true))
                Brackets()
                    .stroke(Brand.mint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: rect.width, height: rect.height)
                    .scaleEffect(pulse ? 1.015 : 0.985)
                    .position(x: rect.midX, y: rect.midY)
                if progress > 0 {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .trim(from: 0, to: progress)
                        .stroke(Brand.mint.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: rect.width - 12, height: rect.height - 12)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct Brackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.16, r: CGFloat = 26
        var path = Path()
        // top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        // top-right
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        // bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        // bottom-left
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}

/// Distinguishes unreadable QR payloads from repeated frames without retaining
/// rejected data. Times come from the monotonic system uptime, not the wall clock.
struct QRScanFrameGate {
    enum Issue: Equatable {
        case nonText, empty, tooLarge
        var message: String { message(for: .signingRequest) }

        func message(for purpose: QRScanPurpose) -> String {
            switch (self, purpose) {
            case (.nonText, .signingRequest): "A QR code was found, but it doesn’t contain readable text. Export the request as a file instead."
            case (.empty, .signingRequest): "This QR code is empty. Scan the signing request from your other wallet."
            case (.tooLarge, .signingRequest): "This QR code is too large. Use an animated QR code or export a request file."
            case (.nonText, .recoveryPhrase): "This QR code doesn’t contain readable words. Compact SeedQR isn’t supported; use a QR code with the words or a Standard SeedQR, or type the words."
            case (.empty, .recoveryPhrase): "This QR code is empty. Scan a QR code that contains your recovery phrase."
            case (.tooLarge, .recoveryPhrase): "This QR code is too large to be a recovery phrase."
            }
        }
    }
    enum Outcome: Equatable { case accepted(String), rejected(Issue), throttled }
    private var last: Outcome?
    private var lastTime: TimeInterval?
    static let maximumBytes = 16_384

    mutating func receive(_ value: String?, at time: TimeInterval) -> Outcome {
        let next: Outcome
        if let value {
            if value.utf8.count > Self.maximumBytes { next = .rejected(.tooLarge) }
            else if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next = .rejected(.empty) }
            else { next = .accepted(value) }
        } else { next = .rejected(.nonText) }
        if next == last, let lastTime, time >= lastTime, time - lastTime < 1 { return .throttled }
        last = next; lastTime = time
        return next
    }
}

private struct CameraPreview: UIViewRepresentable {
    let torchOn: Bool
    let purpose: QRScanPurpose
    let onScan: (String) -> Void
    let onError: (String) -> Void
    let onTorchAvailability: (Bool) -> Void

    func makeUIView(context: Context) -> CameraSurface {
        let view = CameraSurface()
        context.coordinator.purpose = purpose
        context.coordinator.onScan = onScan
        context.coordinator.onError = onError
        context.coordinator.onTorchAvailability = onTorchAvailability
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ view: CameraSurface, context: Context) {
        context.coordinator.purpose = purpose
        context.coordinator.onScan = onScan
        context.coordinator.onError = onError
        context.coordinator.onTorchAvailability = onTorchAvailability
        context.coordinator.setTorch(torchOn)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ view: CameraSurface, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "com.bittool.signer.camera", qos: .userInitiated)
        private var frames = QRScanFrameGate()
        private var device: AVCaptureDevice?
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        var purpose: QRScanPurpose = .signingRequest
        var onScan: ((String) -> Void)?
        var onError: ((String) -> Void)?
        var onTorchAvailability: ((Bool) -> Void)?

        func start(in view: CameraSurface) {
            view.preview.session = session
            view.preview.videoGravity = .resizeAspectFill
            queue.async { [self] in
                do {
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            ?? AVCaptureDevice.default(for: .video) else {
                        throw AppIssue.message(String(localized: "No camera is available. Import the request as a file instead.", bundle: AppText.bundle))
                    }
                    let input = try AVCaptureDeviceInput(device: camera)
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    guard session.canAddInput(input) else { session.commitConfiguration(); throw AppIssue.message(String(localized: "The camera is unavailable.", bundle: AppText.bundle)) }
                    session.addInput(input)
                    let output = AVCaptureMetadataOutput()
                    guard session.canAddOutput(output) else { session.commitConfiguration(); throw AppIssue.message(String(localized: "QR scanning is unavailable.", bundle: AppText.bundle)) }
                    session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else {
                        session.commitConfiguration(); throw AppIssue.message(String(localized: "This camera cannot read QR codes. Import a request file instead.", bundle: AppText.bundle))
                    }
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]
                    session.commitConfiguration()
                    try? camera.lockForConfiguration()
                    if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                    if camera.isAutoFocusRangeRestrictionSupported { camera.autoFocusRangeRestriction = .near }
                    camera.unlockForConfiguration()
                    device = camera
                    session.startRunning()
                    let hasTorch = camera.hasTorch && camera.isTorchAvailable
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.onTorchAvailability?(hasTorch)
                        self.observeRotation(of: camera, layer: view.preview)
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { self.onError?(message) }
                }
            }
        }

        @MainActor private func observeRotation(of camera: AVCaptureDevice, layer: AVCaptureVideoPreviewLayer) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: layer)
            rotation = coordinator
            let apply = { [weak layer] (angle: CGFloat) in
                guard let connection = layer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { _, change in
                guard let angle = change.newValue else { return }
                DispatchQueue.main.async { apply(angle) }
            }
        }

        func setTorch(_ on: Bool) {
            queue.async { [weak self] in
                guard let device = self?.device, device.hasTorch, device.isTorchAvailable,
                      (device.torchMode == .on) != on, (try? device.lockForConfiguration()) != nil else { return }
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            }
        }

        func stop() {
            onScan = nil; onError = nil; onTorchAvailability = nil
            rotationObservation?.invalidate(); rotationObservation = nil; rotation = nil
            queue.async { [session, device] in
                if let device, device.torchMode == .on, (try? device.lockForConfiguration()) != nil {
                    device.torchMode = .off; device.unlockForConfiguration()
                }
                session.stopRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            let codes = metadataObjects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }.filter { $0.type == .qr }
            guard !codes.isEmpty else { return }
            // Prefer readable codes when several are in view: a binary code must
            // not hide a readable request later in the metadata array.
            let readable = codes.compactMap(\.stringValue)
            let values: [String?] = readable.isEmpty ? [nil] : readable.map(Optional.some)
            for value in values {
                switch frames.receive(value, at: ProcessInfo.processInfo.systemUptime) {
                case .accepted(let text): onScan?(text)
                case .rejected(let issue): onError?(issue.message(for: purpose))
                case .throttled: break
                }
            }
        }
    }
}

private final class CameraSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
