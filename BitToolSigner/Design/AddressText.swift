import SwiftUI

/// Splits public identifiers into short groups for character-by-character
/// comparison. Grouping only changes presentation; copying always uses the
/// original string.
enum AddressFormatter {
    static func groups(_ value: String, size: Int = 4) -> [String] {
        guard size > 0, !value.isEmpty else { return [value] }
        var body = Substring(value)
        var result: [String] = []
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            let prefix = body.prefix(2); body = body.dropFirst(2)
            let first = body.prefix(size); body = body.dropFirst(first.count)
            result.append(String(prefix + first))
        }
        while !body.isEmpty {
            let group = body.prefix(size)
            result.append(String(group))
            body = body.dropFirst(group.count)
        }
        return result
    }

    /// Abbreviation for summaries only. Full values stay available in details.
    static func short(_ value: String, leading: Int = 6, trailing: Int = 4) -> String {
        let hexPrefix = value.hasPrefix("0x") ? 2 : 0
        guard value.count > leading + trailing + hexPrefix + 1 else { return value }
        return String(value.prefix(leading + hexPrefix)) + "…" + String(value.suffix(trailing))
    }

    static func looksLikeAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !trimmed.contains("\n"), (25...90).contains(trimmed.count) else { return false }
        if trimmed.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil { return true }
        if trimmed.range(of: "^T[1-9A-HJ-NP-Za-km-z]{33}$", options: .regularExpression) != nil { return true }
        if trimmed.range(of: "^(bc1|[13])[0-9A-Za-z]{20,87}$", options: .regularExpression) != nil { return true }
        return trimmed.range(of: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", options: .regularExpression) != nil
    }
}

/// A full address in monospaced groups. The first and last groups are
/// emphasised because swapped addresses usually differ there first.
struct AddressText: View {
    let address: String
    var font: Font = .body
    var groupSize = 4

    var body: some View {
        let groups = AddressFormatter.groups(address, size: groupSize)
        groups.enumerated().reduce(Text(verbatim: "")) { text, item in
            let (index, group) = item
            let edge = index == 0 || index == groups.count - 1
            let piece = Text(verbatim: group)
                .fontWeight(edge ? .semibold : .regular)
                .foregroundStyle(edge ? Color.primary : Color.primary.opacity(0.78))
            return index == 0 ? piece : text + Text(verbatim: " ") + piece
        }
        .font(font.monospaced())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(groups.joined(separator: ", "))
    }
}

/// A long hash or identifier in secondary groups of eight.
struct HashText: View {
    let value: String
    var body: some View {
        // Uppercase, like the master fingerprint: both are called a fingerprint
        // and both are read by comparing them against another screen.
        Text(verbatim: AddressFormatter.groups(value.uppercased(), size: 8).joined(separator: " "))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A value that can be copied from a context menu and a trailing button.
struct CopyableAddress: View {
    let address: String
    var font: Font = .body
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AddressText(address: address, font: font)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Clipboard.copy(address); copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : "Copy address")
        }
        .contextMenu {
            Button("Copy Address", systemImage: "doc.on.doc") { Clipboard.copy(address) }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }
}
