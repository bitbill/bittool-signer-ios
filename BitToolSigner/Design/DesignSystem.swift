import SwiftUI
import UIKit

/// Brand and semantic colors. Surfaces use the system grouped palette so the app
/// follows iOS appearance, contrast and Liquid Glass conventions.
enum Brand {
    static let mint = Color(red: 0.702, green: 0.941, blue: 0.780)
    static let ink = Color(red: 0.043, green: 0.122, blue: 0.086)
    /// Label color for content drawn on the accent: white on emerald, ink on mint.
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.043, green: 0.122, blue: 0.086, alpha: 1) : .white })
}

enum Palette {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let raised = Color(uiColor: .tertiarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
}

enum Metrics {
    static let cardRadius: CGFloat = 22
    static let readableWidth: CGFloat = 640
    static let pagePadding: CGFloat = 20
}

extension View {
    /// Keeps long-form content comfortable to read on iPad and landscape layouts.
    func readableWidth(_ width: CGFloat = Metrics.readableWidth) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }

    /// Room under a scrolling list's last row or footer, so the closing
    /// sentence does not end flush against the tab bar.
    func listBottomInset(_ inset: CGFloat = 30) -> some View {
        contentMargins(.bottom, inset, for: .scrollContent)
    }

    func cardBackground(padding: CGFloat = 16, radius: CGFloat = Metrics.cardRadius) -> some View {
        self.padding(padding)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Primary call to action. Liquid Glass on iOS 26, a filled capsule before.
    @ViewBuilder func prominentAction() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        }
    }

    /// Secondary action with the same geometry as `prominentAction`.
    @ViewBuilder func secondaryAction() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}

extension View {
    /// Pins primary actions above the home indicator. iOS 26 uses a safe-area
    /// bar so scroll edge effects blend content under the Liquid Glass buttons.
    /// `bottomPadding` is the gap under the last row. A bar that ends in a
    /// button keeps the default; one that ends in a footnote line (the legal
    /// links on Welcome) can sit closer to the edge.
    @ViewBuilder func bottomActionBar<Bar: View>(maxWidth: CGFloat = Metrics.readableWidth,
                                                 bottomPadding: CGFloat = 8,
                                                 @ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) { bar() }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 8).padding(.bottom, bottomPadding)
                    .readableWidth(maxWidth)
            }
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) { bar() }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 10).padding(.bottom, bottomPadding)
                    .readableWidth(maxWidth)
                    .background(.bar)
            }
        }
    }
}

/// Full-width label used inside `prominentAction()` / `secondaryAction()` buttons.
struct ActionLabel: View {
    let title: Text
    var systemImage: String?
    var busy = false
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: LocalizedStringKey, systemImage: String? = nil, busy: Bool = false, prominent: Bool = true) {
        self.title = Text(title); self.systemImage = systemImage; self.busy = busy; self.prominent = prominent
    }

    init(verbatim title: String, systemImage: String? = nil, busy: Bool = false, prominent: Bool = true) {
        self.title = Text(verbatim: title); self.systemImage = systemImage; self.busy = busy; self.prominent = prominent
    }

    var body: some View {
        ZStack {
            if busy {
                ProgressView().tint(!isEnabled ? Color.secondary : prominent ? Brand.onAccent : .accentColor)
            }
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                title
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .opacity(busy ? 0 : 1)
        }
        .font(.body.weight(.semibold))
        // A disabled prominent button has a pale fill; white text on it would
        // vanish (iOS 17/18 especially), so disabled labels use a gray label color.
        .foregroundStyle(!isEnabled ? AnyShapeStyle(.secondary)
                         : prominent ? AnyShapeStyle(Brand.onAccent) : AnyShapeStyle(.tint))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// A tinted inline message. Tone communicates meaning with color, symbol and text.
struct Callout: View {
    enum Tone { case info, success, warning, danger }
    let tone: Tone
    let text: Text
    var title: Text?

    init(_ text: LocalizedStringKey, title: LocalizedStringKey? = nil, tone: Tone = .info) {
        self.text = Text(text); self.title = title.map { Text($0) }; self.tone = tone
    }

    /// For text the app did not write as a literal: an error returned by the
    /// engine, or a value read from a request.
    init(verbatim text: String, title: String? = nil, tone: Tone = .info) {
        self.text = Text(verbatim: text); self.title = title.map { Text(verbatim: $0) }; self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .info: .accentColor
        case .success: Palette.success
        case .warning: Palette.warning
        case .danger: Palette.danger
        }
    }
    private var symbol: String {
        switch tone {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).imageScale(.medium)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let title { title.font(.subheadline.weight(.semibold)) }
                text.font(.subheadline).foregroundStyle(title == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Compact status capsule, e.g. "Decoded locally" or "High risk".
struct StatusPill: View {
    let label: Text
    let systemImage: String
    var color: Color = .accentColor

    init(text: LocalizedStringKey, systemImage: String, color: Color = .accentColor) {
        label = Text(text); self.systemImage = systemImage; self.color = color
    }

    /// For text the app did not write as a literal, such as a stored receipt's
    /// own wording.
    init(verbatim text: String, systemImage: String, color: Color = .accentColor) {
        label = Text(verbatim: text); self.systemImage = systemImage; self.color = color
    }

    var body: some View {
        Label { label } icon: { Image(systemName: systemImage) }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

/// Large illustrated header used by empty states, onboarding and success pages.
struct SymbolHero: View {
    let systemImage: String
    var color: Color = .accentColor
    var size: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.12)).frame(width: size * 1.7, height: size * 1.7)
            Circle().strokeBorder(color.opacity(0.18), lineWidth: 1).frame(width: size * 2.2, height: size * 2.2)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(color)
                .symbolRenderingMode(.monochrome)
                .symbolEffect(.bounce, value: appeared && !reduceMotion)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .accessibilityHidden(true)
        .onAppear { appeared = true }
    }
}

/// Numbered row used for short instructional sequences.
struct StepRow: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14))
                Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)).foregroundStyle(.tint)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityElement(children: .combine)
    }
}

/// Monospaced key/value line used in compact verification cards.
struct DetailLine: View {
    let label: LocalizedStringKey
    let text: Text
    var monospaced = true

    /// A value the app did not write as a literal: an address, a digest, a
    /// version read off disk.
    init(label: LocalizedStringKey, value: String, monospaced: Bool = true) {
        self.label = label; text = Text(verbatim: value); self.monospaced = monospaced
    }

    /// Prose that belongs in the same two-line layout.
    init(label: LocalizedStringKey, prose: LocalizedStringKey) {
        self.label = label; text = Text(prose); monospaced = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            text
                .font(monospaced ? .footnote.monospaced() : .footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Copies public text without cross-device Handoff and clears it after a while.
enum Clipboard {
    static func copy(_ text: String, expiresAfter seconds: TimeInterval = 120) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)])
    }
}

/// Transient confirmation shown after copying.
/// A short confirmation that slides up from the bottom and is announced to VoiceOver.
struct StatusToast: ViewModifier {
    let message: LocalizedStringKey
    let announcement: String
    var systemImage = "checkmark.circle.fill"
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isPresented {
                Label(message, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        AccessibilityNotification.Announcement(announcement).post()
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation { isPresented = false }
                    }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.spring(duration: 0.3), value: isPresented)
        .sensoryFeedback(.success, trigger: isPresented) { _, new in new }
    }
}

extension View {
    func copiedToast(_ isPresented: Binding<Bool>) -> some View {
        modifier(StatusToast(message: "Copied", announcement: "Copied", isPresented: isPresented))
    }
    func statusToast(_ message: LocalizedStringKey, announcement: String, isPresented: Binding<Bool>) -> some View {
        modifier(StatusToast(message: message, announcement: announcement, isPresented: isPresented))
    }
}
