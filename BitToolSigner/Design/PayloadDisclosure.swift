import SwiftUI

/// Collapsed developer view of what a QR code carries (Connect and signature
/// results). Copying uses Clipboard (this device only, expires), so the text is
/// not selectable into the general pasteboard.
struct PayloadDisclosure: View {
    /// Engine-provided titles pass through unchanged; literals are localised.
    let title: LocalizedStringKey

    init(title: LocalizedStringKey, text: String, notes: [String] = [], identifier: String) {
        self.title = title; self.text = text; self.notes = notes; self.identifier = identifier
    }

    init(verbatim title: String, text: String, notes: [String] = [], identifier: String) {
        self.title = LocalizedStringKey(title); self.text = text; self.notes = notes; self.identifier = identifier
    }
    let text: String
    /// Short explanations shown above the payload when it is expanded.
    var notes: [String] = []
    var identifier = "payload"
    @State private var expanded = false
    @State private var copied = false

    /// A signed PSBT can be very large; only this much is laid out.
    static let displayLimit = 30_000
    private var truncated: Bool { text.count > Self.displayLimit }

    /// The capped text with break opportunities inside very long runs (a PSBT's
    /// Base64, long hex), so wrapping stays cheap. Copy always uses `text`.
    private var displayText: String {
        let shown = truncated ? String(text.prefix(Self.displayLimit)) + "\n…" : text
        guard shown.utf8.count > 2_000 else { return shown }
        return shown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.count > 120 else { return String(line) }
            var out = "", run = 0
            out.reserveCapacity(line.count + line.count / 64)
            for character in line {
                out.append(character)
                run = character == " " ? 0 : run + 1
                if run == 64 { out.append("\u{200B}"); run = 0 }
            }
            return out
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityValue(expanded ? "Shown" : "Hidden")
            .accessibilityIdentifier(identifier + "Toggle")

            if expanded {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: displayText)
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier)
                if truncated {
                    Text("Showing the first \(Self.displayLimit.formatted()) of \(text.count.formatted()) characters. Copy includes everything.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Clipboard.copy(text); copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Payload", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier(identifier + "Copy")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
