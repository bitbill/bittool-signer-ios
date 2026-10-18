import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders QR modules at one pixel each; SwiftUI scales them with nearest-neighbour
/// sampling so edges stay crisp at every size without large bitmaps.
enum QRRenderer {
    // CPU rendering: codes are drawn at one pixel per module, so this is trivial
    // work, and it avoids Metal's first-use pipeline setup in the middle of a push.
    private static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Short payloads get more error correction; dense animated parts stay scannable.
        filter.correctionLevel = text.utf8.count <= 600 ? "M" : "L"
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func images(for frames: [String], priority: TaskPriority = .userInitiated) async -> [UIImage] {
        await Task.detached(priority: priority) {
            frames.compactMap { image(for: $0) }
        }.value
    }
}

/// Static or animated (multi-part BC-UR / BBQR) QR code on a white quiet zone.
struct QRCodeView: View {
    let frames: [String]
    var maxSide: CGFloat = 320
    var interval: Duration = .milliseconds(250)

    @State private var images: [UIImage] = []
    @State private var renderedFrames: [String] = []
    @State private var index = 0
    @State private var paused = false

    private var ready: Bool { renderedFrames == frames && !images.isEmpty }

    /// `initialImages`, rendered ahead of time for exactly these frames, are shown
    /// straight away, so the view never changes during a navigation push.
    init(frames: [String], maxSide: CGFloat = 320, interval: Duration = .milliseconds(250), initialImages: [UIImage]? = nil) {
        self.frames = frames
        self.maxSide = maxSide
        self.interval = interval
        if let initialImages, !frames.isEmpty, initialImages.count == frames.count {
            _images = State(initialValue: initialImages)
            _renderedFrames = State(initialValue: frames)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                if ready, let image = images[safe: index] ?? images.first {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                        .accessibilityLabel(frames.count > 1 ? "Animated QR code, part \(index + 1) of \(frames.count)" : "QR code")
                } else {
                    ProgressView().tint(.gray)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: maxSide)
            .environment(\.colorScheme, .light)

            if frames.count > 1 {
                HStack(spacing: 12) {
                    Button {
                        paused.toggle()
                    } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(paused ? "Play QR animation" : "Pause QR animation")
                    ProgressView(value: Double(index + 1), total: Double(max(1, frames.count)))
                        .frame(maxWidth: 140)
                        .accessibilityHidden(true)
                    Text("\(index + 1)/\(frames.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: frames) {
            guard renderedFrames != frames else { return }
            index = 0
            let rendered = await QRRenderer.images(for: frames)
            guard !Task.isCancelled else { return }
            images = rendered; renderedFrames = frames
        }
        .task(id: frames.count) {
            guard frames.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if !paused && ready { index = (index + 1) % max(1, images.count) }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
