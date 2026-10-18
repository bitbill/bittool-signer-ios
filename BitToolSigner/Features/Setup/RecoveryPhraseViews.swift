import SwiftUI

/// A recovery phrase that starts concealed. While concealed, the words are not
/// in the view hierarchy or accessibility tree at all (not merely blurred).
/// Tapping the placeholder shows them at once; the owner keeps the privacy
/// session so it can outlive a switch between backup formats.
struct ProtectedRecoveryPhrase: View {
    let words: [String]
    var passphrase = ""
    @ObservedObject var privacy: RecoveryPrivacySession
    var onReveal: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            if privacy.isRevealed {
                RecoveryWordGrid(words: words)
                    .transition(.opacity)
                if !passphrase.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("BIP39 passphrase · back up separately", systemImage: "key")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: passphrase)
                            .font(.body.monospaced())
                            .accessibilityIdentifier("recovery.passphrase")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground(padding: 14, radius: 16)
                }
                Button { withAnimation { privacy.hide() } } label: {
                    Label("Hide Recovery Phrase", systemImage: "eye.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("recovery.hide")
            } else {
                Button { withAnimation(.smooth(duration: 0.25)) { _ = privacy.reveal() } } label: {
                    ConcealedPhrase(count: words.count)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show recovery phrase")
                .accessibilityHint("Make sure no one can see your screen")
                .accessibilityIdentifier("recovery.reveal")
            }
        }
        .recoveryPrivacy(privacy, onReveal: onReveal)
        .onChange(of: words) { _, _ in privacy.hide() }
        .onChange(of: passphrase) { _, _ in privacy.hide() }
    }
}

/// Layout for recovery word grids: how many columns (three at most) and ONE word
/// size for every cell, so that each word is shown in full and all words look
/// the same. The size is the text style's size (Dynamic Type), reduced just
/// enough for the widest word to fit; below 80% the grid uses fewer columns
/// instead. Letting each cell shrink on its own made long words smaller than
/// short ones, and a cell that could not shrink enough cut its word off.
struct WordGridColumns {
    var cellPadding: CGFloat
    /// The widest index label, such as "24" or "24.".
    var indexSample: String
    var indexStyle: UIFont.TextStyle = .caption2
    var indexMinWidth: CGFloat = 0
    var spacing: CGFloat = 6
    static let gridSpacing: CGFloat = 8
    static let minimumScale: CGFloat = 0.8
    /// Rounding in SwiftUI's layout can leave a word a point short of its width.
    static let safetyMargin: CGFloat = 3

    struct Layout: Equatable {
        let columns: Int
        /// Point size of the monospaced semibold word font, shared by all cells.
        let wordSize: CGFloat
        var wordFont: Font { .system(size: wordSize, weight: .semibold, design: .monospaced) }
    }

    func layout(width: CGFloat, words: [String], dynamicTypeSize: DynamicTypeSize) -> Layout {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let base = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
        guard width > 0 else { return Layout(columns: dynamicTypeSize.isAccessibilitySize ? 2 : 3, wordSize: base) }
        let wordFont = UIFont.monospacedSystemFont(ofSize: base, weight: .semibold)
        let indexSize = UIFont.preferredFont(forTextStyle: indexStyle, compatibleWith: traits).pointSize
        let indexFont = UIFont.monospacedDigitSystemFont(ofSize: indexSize, weight: .regular)
        let widest = words.map { ceil(($0 as NSString).size(withAttributes: [.font: wordFont]).width) }.max() ?? 0
        let index = max(indexMinWidth, ceil((indexSample as NSString).size(withAttributes: [.font: indexFont]).width))
        for columns in [3, 2, 1] {
            let cell = (width - Self.gridSpacing * CGFloat(columns - 1)) / CGFloat(columns)
            let available = cell - 2 * cellPadding - index - spacing - Self.safetyMargin
            let scale = widest > 0 ? min(1, available / widest) : 1
            if scale >= Self.minimumScale || columns == 1 {
                // Round down to a half point so the chosen size never overshoots.
                return Layout(columns: columns, wordSize: max(1, (base * scale * 2).rounded(.down) / 2))
            }
        }
        return Layout(columns: 1, wordSize: base)
    }

    func count(width: CGFloat, words: [String], dynamicTypeSize: DynamicTypeSize) -> Int {
        layout(width: width, words: words, dynamicTypeSize: dynamicTypeSize).columns
    }
}

/// Placeholder with the phrase's shape, containing no recovery material. Its
/// columns follow a reference 8-letter word, not the actual words.
private struct ConcealedPhrase: View {
    let count: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        let columns = WordGridColumns(cellPadding: 10, indexSample: "24", indexMinWidth: 18)
            .count(width: gridWidth, words: ["wwwwwwww"], dynamicTypeSize: dynamicTypeSize)
        ZStack {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: 6) {
                        Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(minWidth: 18, alignment: .trailing)
                        RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: .systemFill)).frame(height: 10)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 13)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .blur(radius: 2)
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Image(systemName: "eye.slash.fill").font(.title2)
                Text("Tap to Reveal").font(.headline)
                Text("Make sure no one can see your screen.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(.primary)
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct RecoveryWordGrid: View {
    let words: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        let layout = WordGridColumns(cellPadding: 10, indexSample: "24", indexMinWidth: 18)
            .layout(width: gridWidth, words: words, dynamicTypeSize: dynamicTypeSize)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: layout.columns), spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    Text(verbatim: word)
                        .font(layout.wordFont)
                        .lineLimit(1)
                        // Safety net only: the shared size already fits every word.
                        .minimumScaleFactor(0.9)
                }
                // Fill the cell without a trailing Spacer, whose extra HStack gap
                // would take width from the word.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 11)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("recovery.word.\(index)")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// Plain multiline input for restoring a phrase: no password AutoFill, no
/// autocorrection or capitalization, and Writing Tools off. The system
/// keyboard stays selectable so Chinese, Japanese and Korean phrases can be
/// typed with Apple's input methods. Third-party keyboards are rejected
/// app-wide by the app delegate.
struct RecoveryPhraseInput: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Enter your words separated by spaces")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8).padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            editor
                .textContentType(nil)
                .keyboardType(.default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 132)
                .accessibilityLabel("Recovery phrase")
                .accessibilityIdentifier("recovery.input.visible")
        }
        .font(.body.monospaced())
        .padding(10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .privacySensitive()
        .recoveryScreenshotWarning()
    }

    @ViewBuilder private var editor: some View {
        if #available(iOS 18.0, *) {
            TextEditor(text: $text).writingToolsBehavior(.disabled)
        } else {
            TextEditor(text: $text)
        }
    }
}

/// Live word count, detected language and dictionary check, shown above the
/// phrase editor so it stays visible while the keyboard is up.
struct RecoveryPhraseStatus: View {
    let text: String

    var body: some View {
        let draft = RecoveryPhraseDraft(text)
        let indicator = HStack(spacing: 6) {
            Image(systemName: draft.unknownWords.isEmpty ? (draft.looksComplete ? "checkmark.circle.fill" : "text.word.spacing") : "exclamationmark.circle.fill")
                .foregroundStyle(draft.unknownWords.isEmpty ? (draft.looksComplete ? Palette.success : Color.secondary) : Palette.danger)
                .accessibilityHidden(true)
            Text(status(draft))
                .font(.footnote)
                .foregroundStyle(draft.unknownWords.isEmpty ? Color.secondary : Palette.danger)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // Side by side when it fits; the status moves below at large text sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text("Recovery phrase").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                indicator
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery phrase").font(.subheadline.weight(.semibold))
                indicator
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recovery.status")
    }

    /// Built outside a `Text` literal, so it is localized against the chosen
    /// language's bundle rather than a `LocalizedStringKey`.
    private func status(_ draft: RecoveryPhraseDraft) -> String {
        if !draft.unknownWords.isEmpty {
            let words = draft.unknownWords.prefix(2).map { "“\($0)”" }.joined(separator: ", ")
            return String(localized: "Unknown: \(words)", bundle: AppText.bundle)
        }
        let count: String
        switch draft.words.count {
        case 0: return String(localized: "12–24 words · any BIP39 language", bundle: AppText.bundle)
        case 1: count = String(localized: "1 word", bundle: AppText.bundle)
        default: count = String(localized: "\(draft.words.count) words", bundle: AppText.bundle)
        }
        guard let language = draft.language, language != .english || draft.looksComplete else { return count }
        return count + " · " + language.displayName
    }
}

/// Dictionary completions for the word being typed, in the detected language.
struct RecoveryPhraseAssistant: View {
    @Binding var text: String

    var body: some View {
        let draft = RecoveryPhraseDraft(text)
        let list = BIP39.wordlist(draft.language ?? .english)
        let suggestions = draft.partialWord.map { list.suggestions(for: $0, limit: 5) } ?? []
        let completed = draft.partialWord.map { list.contains($0) } ?? false
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if draft.language?.isChinese == true {
                    Text("Each Chinese word is one character").font(.footnote).foregroundStyle(.secondary)
                } else if suggestions.isEmpty || (completed && suggestions.count == 1) {
                    if !completed {
                        Text(draft.partialWord == nil ? "Type a word to see suggestions" : "No matching word")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(suggestions, id: \.self) { word in
                        Button { complete(with: word) } label: {
                            Text(verbatim: word).font(.subheadline.monospaced().weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Palette.raised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Insert \(word)")
                        .accessibilityIdentifier("suggestion." + word)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Replaces the word being typed with the canonical word (including any accents).
    private func complete(with word: String) {
        guard let range = text.range(of: "[^\\s,，、]+$", options: .regularExpression) else { return }
        text.replaceSubrange(range, with: word + " ")
    }
}

// MARK: - Privacy modifiers

private struct RecoveryPrivacyModifier: ViewModifier {
    @ObservedObject var session: RecoveryPrivacySession
    let onReveal: () -> Void
    @State private var presentedPrompt: RecoveryPrivacySession.Prompt?

    func body(content: Content) -> some View {
        content
            .privacySensitive()
            .onAppear { presentedPrompt = nil; session.start() }
            .onDisappear { session.stop(); presentedPrompt = nil }
            .onChange(of: session.isRevealed) { _, revealed in if revealed { onReveal() } }
            // UIKit can reset an alert binding while SwiftUI is updating its
            // presentation. Keep that bookkeeping in State, not the publisher
            // that synchronously revokes permission to display secret content.
            .onChange(of: session.prompt) { _, prompt in presentedPrompt = prompt }
            .alert(item: $presentedPrompt) { _ in
                Alert(
                    title: Text(RecoveryCopy.screenshotTitle),
                    message: Text("The phrase is hidden again, but the screenshot may already contain it. Delete it from Photos, Recently Deleted and any synced copies, and keep a written backup offline."),
                    dismissButton: .default(Text("OK")) { session.acknowledgeWarning() }
                )
            }
    }
}

extension View {
    func recoveryPrivacy(_ session: RecoveryPrivacySession, onReveal: @escaping () -> Void = {}) -> some View {
        modifier(RecoveryPrivacyModifier(session: session, onReveal: onReveal))
    }
}

enum RecoveryCopy {
    static let screenshotTitle = "Screenshot Detected"
}

/// Warns after a screenshot of directly visible recovery material. It cannot
/// undo the screenshot; the content's visibility is left unchanged.
@MainActor
private struct RecoveryScreenshotWarningModifier: ViewModifier {
    @StateObject private var session = RecoveryScreenshotSession()
    @State private var presentedWarning: RecoveryScreenshotSession.Warning?
    let onScreenshot: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .privacySensitive()
            .onAppear { presentedWarning = nil; session.start(onScreenshot: onScreenshot) }
            .onDisappear { session.stop(); presentedWarning = nil }
            .onChange(of: session.warning) { _, warning in presentedWarning = warning }
            .alert(item: $presentedWarning) { warning in
                Alert(
                    title: Text(RecoveryCopy.screenshotTitle),
                    message: Text("The screenshot may contain your recovery phrase or some of its words. Delete it from Photos, Recently Deleted and any synced copies, and keep a written backup offline."),
                    dismissButton: .default(Text("OK")) { session.acknowledge(warning) }
                )
            }
    }
}

extension View {
    @MainActor
    func recoveryScreenshotWarning(onScreenshot: @escaping @MainActor () -> Void = {}) -> some View {
        modifier(RecoveryScreenshotWarningModifier(onScreenshot: onScreenshot))
    }
}
