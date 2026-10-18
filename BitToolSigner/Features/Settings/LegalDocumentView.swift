import SwiftUI

/// Terms of Use and Privacy Policy, shipped with the app and shown in it.
/// BitTool Signer opens no web pages, so these never leave the device.
enum LegalDocument: String, Identifiable, CaseIterable {
    case terms, privacy

    var id: String { rawValue }
    var title: String { self == .terms ? "Terms of Use" : "Privacy Policy" }
    var resource: String { self == .terms ? "TERMS_OF_USE" : "PRIVACY_POLICY" }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @State private var blocks: [Block] = []

    /// One rendered piece of the document.
    struct Block: Identifiable {
        enum Kind { case version, heading, bullet, paragraph }
        let id: Int
        let kind: Kind
        let text: String
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .version:
                        Text(block.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .heading:
                        Text(block.text)
                            .font(.headline)
                            .padding(.top, 8)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(block.text)
                        }
                        .font(.callout)
                    case .paragraph:
                        Text(block.text).font(.callout)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.pagePadding)
            .readableWidth()
        }
        .background(Palette.background)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legal." + document.rawValue)
        .task(id: document) { blocks = Self.blocks(of: document) }
    }

    /// Plain text with "## " headings and "- " bullets. A blank line ends a block,
    /// so a paragraph may be wrapped over several lines, with any line endings. The
    /// first line repeats the title shown in the navigation bar and is dropped.
    static func blocks(of document: LegalDocument) -> [Block] {
        guard let url = Bundle.main.url(forResource: document.resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [Block(id: 0, kind: .paragraph, text: "This document is missing from the app bundle.")]
        }
        return blocks(of: text, title: document.title)
    }

    static func blocks(of text: String, title: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Block(id: blocks.count, kind: .paragraph, text: paragraph.joined(separator: " ")))
            paragraph = []
        }
        // Empty subsequences are kept: a blank line is what ends a paragraph.
        let lines = text.split(maxSplits: .max, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) + [""] {
            // The first two lines are the title (shown in the navigation bar) and
            // the version, which stand alone even though no blank line separates them.
            if line == title, blocks.isEmpty, paragraph.isEmpty { continue }
            if line.hasPrefix("Version "), blocks.isEmpty, paragraph.isEmpty {
                blocks.append(Block(id: blocks.count, kind: .version, text: line)); continue
            }
            if line.isEmpty { flushParagraph() }
            else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(Block(id: blocks.count, kind: .heading, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(Block(id: blocks.count, kind: .bullet, text: String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }
}

/// The same documents from the welcome screen, which has no navigation stack.
struct LegalDocumentSheet: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LegalDocumentView(document: document)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("legal.done")
                    }
                }
        }
    }
}
