import SwiftUI

// MARK: - Backup panel

enum BackupFormat: String, CaseIterable, Identifiable {
    case words, qr
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .words ? "Words" : "QR Code" }
}

/// The recovery phrase backup: the words to write down, a plain-text QR code
/// for moving the wallet to another device of your own, 2-of-3 recovery cards,
/// and tips. Everything starts concealed and shows with a single tap. Used when
/// creating a wallet and when showing a saved wallet's phrase.
struct RecoveryBackupPanel: View {
    let words: [String]
    /// Shown under the words once revealed. Setup omits it: the person just typed it.
    var displayedPassphrase = ""
    /// The wallet has a BIP39 passphrase, which neither the QR code nor the cards contain.
    var hasPassphrase = false
    /// Setup shows the tips link in its bottom bar, next to the main action.
    var showsTipsLink = true
    /// A sheet presented by the owner (setup's Security Tips) covers the panel.
    var isCovered = false
    /// Called when the words are shown, in the grid or on the recovery cards.
    var onReveal: () -> Void = {}

    // Words and QR code are revealed separately: seeing the words is no reason
    // to put a scannable copy on screen too.
    @StateObject private var wordsPrivacy = RecoveryPrivacySession()
    @StateObject private var qrPrivacy = RecoveryPrivacySession()
    @State private var format: BackupFormat = .words
    @State private var showingCards = false
    @State private var showingTips = false

    var body: some View {
        VStack(spacing: 16) {
            Picker("Backup format", selection: $format.animation(.snappy(duration: 0.25))) {
                ForEach(BackupFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("backup.format")

            switch format {
            case .words:
                ProtectedRecoveryPhrase(words: words, passphrase: displayedPassphrase, privacy: wordsPrivacy, onReveal: onReveal)
                HStack {
                    Spacer()
                    Button { showingCards = true } label: {
                        HStack(spacing: 4) {
                            Text("Recovery Cards")
                            Image(systemName: "arrow.right").imageScale(.small)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityHint("Splits the phrase across three cards. Any two restore it.")
                    .accessibilityIdentifier("backup.cards")
                }
            case .qr:
                RecoveryQRSection(words: words, hasPassphrase: hasPassphrase, privacy: qrPrivacy)
            }

            if showsTipsLink {
                SecurityTipsButton { showingTips = true }
                    .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showingTips) { SecurityTipsSheet() }
        .sheet(isPresented: $showingCards) {
            RecoveryCardsSheet(words: words, hasPassphrase: hasPassphrase, onReveal: onReveal)
        }
        // A sheet does not make the covered view disappear, so its session would
        // keep watching for screenshots. Pause it while covered: the phrase is
        // concealed, and only the sheet on top raises a screenshot warning.
        .onChange(of: covered) { _, isCovered in
            let session = format == .words ? wordsPrivacy : qrPrivacy
            if isCovered { session.stop() } else { session.start() }
        }
    }

    private var covered: Bool { isCovered || showingCards || showingTips }
}

// MARK: - QR code

/// The phrase as a plain-text QR code (the words separated by spaces), for
/// moving this wallet to another device of your own. Any wallet that imports a
/// recovery phrase by scanning can read it. It is a complete copy of the
/// secret, so it starts concealed and is never offered for saving or sharing.
struct RecoveryQRSection: View {
    let words: [String]
    let hasPassphrase: Bool
    @ObservedObject var privacy: RecoveryPrivacySession

    var body: some View {
        VStack(spacing: 16) {
            Callout("This QR code contains your complete recovery phrase in plain text. Use it only in private, to move this wallet to another device of your own. Writing the words down by hand is still the safest backup.")
            if privacy.isRevealed {
                QRCodeView(frames: [words.joined(separator: " ")], maxSide: 250)
                    .accessibilityIdentifier("backup.qr")
                    .transition(.opacity)
                Button { withAnimation { privacy.hide() } } label: {
                    Label("Hide QR Code", systemImage: "eye.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("backup.qr.hide")
            } else {
                Button { withAnimation(.smooth(duration: 0.25)) { _ = privacy.reveal() } } label: {
                    ConcealedQRCode()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show recovery phrase QR code")
                .accessibilityHint("Make sure no one can see your screen")
                .accessibilityIdentifier("backup.qr.reveal")
            }
            Text("This QR code is your recovery phrase. Anyone who scans or photographs it can take all your funds, and no support team will ever ask to see it. Never take a screenshot of it, send it or show it to anyone.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.danger)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            if hasPassphrase {
                Callout("It contains the \(words.count) words only. Your BIP39 passphrase is not included; restoring this wallet also needs the passphrase.", tone: .warning)
            }
        }
        .recoveryPrivacy(privacy)
    }
}

/// A QR-shaped placeholder. It is drawn from a system symbol and contains no
/// recovery material.
private struct ConcealedQRCode: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .fontWeight(.ultraLight)
                .foregroundStyle(Color.black.opacity(0.55))
                .padding(26)
                .blur(radius: 10)
                .accessibilityHidden(true)
            RevealPrompt()
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 250)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .environment(\.colorScheme, .light)
    }
}

/// "Tap to Reveal" badge shared by every concealed backup view.
struct RevealPrompt: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash.fill").font(.title2)
            Text("Tap to Reveal").font(.headline)
            Text("Make sure no one can see your screen.").font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(.primary)
    }
}

// MARK: - Recovery cards (2 of 3)

/// Three cards, each leaving out a third of the words, so that any two restore
/// the phrase and one lost or stolen card alone does not. See `RecoveryCards`.
struct RecoveryCardsSheet: View {
    let words: [String]
    let hasPassphrase: Bool
    var onReveal: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var privacy = RecoveryPrivacySession()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(RecoveryCards.singleCardIsWeak(wordCount: words.count)
                         ? "Keep these three cards in three different places. Any two of them restore the complete recovery phrase, so if one card is lost, the other two can still restore your wallet."
                         : "Keep these three cards in three different places. Any two of them restore the complete recovery phrase, so if one card is lost or stolen, the other two keep your wallet safe and recoverable.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if RecoveryCards.singleCardIsWeak(wordCount: words.count) {
                        Callout(verbatim: weakPhraseWarning, tone: .warning)
                    }
                    if hasPassphrase {
                        Callout("The cards contain the words only. Back up your BIP39 passphrase separately.", tone: .warning)
                    }
                    RecoveryCardsContent(words: words, privacy: privacy, onReveal: onReveal)
                }
                .padding(Metrics.pagePadding)
                .readableWidth()
            }
            .background(Palette.background)
            .navigationTitle("Recovery Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var weakPhraseWarning: String {
        let missing = words.count / RecoveryCards.count
        return String(localized: "With a \(words.count)-word phrase each card shows \(words.count - missing) of the \(words.count) words, and the other \(missing) could be worked out with enough computing power. Guard every card as carefully as the full phrase, or use a 24-word phrase for split backups.", bundle: AppText.bundle)
    }
}

private struct RecoveryCardsContent: View {
    let words: [String]
    @ObservedObject var privacy: RecoveryPrivacySession
    let onReveal: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if privacy.isRevealed {
                ForEach(0..<RecoveryCards.count, id: \.self) { card in
                    RecoveryCardView(words: words, card: card)
                }
                .transition(.opacity)
                Button { withAnimation { privacy.hide() } } label: {
                    Label("Hide Cards", systemImage: "eye.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("cards.hide")
            } else {
                Button { withAnimation(.smooth(duration: 0.25)) { _ = privacy.reveal() } } label: {
                    ConcealedCards(count: words.count)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show recovery cards")
                .accessibilityHint("Make sure no one can see your screen")
                .accessibilityIdentifier("cards.reveal")
            }
        }
        .recoveryPrivacy(privacy, onReveal: onReveal)
    }
}

/// One card: every position, with this card's third of the words left out.
struct RecoveryCardView: View {
    let words: [String]
    let card: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        let layout = WordGridColumns(cellPadding: 8, indexSample: "24.", indexMinWidth: 20)
            .layout(width: gridWidth, words: words + ["xxxx"], dynamicTypeSize: dynamicTypeSize)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Card \(card + 1) of \(RecoveryCards.count)").font(.headline)
                Text("Leaves out words \(omitted)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: layout.columns), spacing: 8) {
                ForEach(words.indices, id: \.self) { position in
                    cell(position, font: layout.wordFont)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("cards.card.\(card)")
    }

    private var omitted: String {
        RecoveryCards.omittedPositions(on: card, wordCount: words.count).map { String($0 + 1) }.joined(separator: ", ")
    }

    @ViewBuilder private func cell(_ position: Int, font: Font) -> some View {
        let shown = RecoveryCards.shows(position, on: card)
        HStack(spacing: 6) {
            Text("\(position + 1).")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            if shown {
                Text(verbatim: words[position])
                    .font(font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            } else {
                Text(verbatim: "xxxx")
                    .font(font.weight(.regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 10)
        .background(shown ? Palette.raised : Palette.raised.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown ? "Word \(position + 1), \(words[position])" : "Word \(position + 1), not on this card")
        .accessibilityIdentifier("cards.card.\(card).word.\(position)")
    }
}

/// Three card-shaped placeholders, containing no recovery material.
private struct ConcealedCards: View {
    let count: Int

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                ForEach(0..<RecoveryCards.count, id: \.self) { card in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Card \(card + 1) of \(RecoveryCards.count)").font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(0..<min(count, 6), id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 8).fill(Palette.raised).frame(height: 26)
                            }
                        }
                    }
                    .padding(12)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .blur(radius: 2.5)
            .accessibilityHidden(true)
            RevealPrompt()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Security tips

struct SecurityTipsButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Security Tips", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("backup.tips")
    }
}

struct SecurityTipsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// One safety tip. The SF Symbol is the identity, so the wording can be
    /// translated without changing what `ForEach` tracks.
    struct Tip: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        init(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) {
            id = symbol; self.title = title; self.detail = detail
        }
    }


    private let tips: [Tip] = [
        Tip("pencil.and.list.clipboard", "Write it on paper",
         "Copy every word by hand, in order. Keep the paper somewhere safe from fire and water, apart from this device."),
        Tip("eye.slash", "Keep it offline",
         "Never take a screenshot or photo of the words, and never store them in notes, email, messages or cloud storage."),
        Tip("qrcode", "The QR code is the phrase",
         "Anyone who scans or photographs it can take your funds. Show it only in private, to move this wallet to another device of your own."),
        Tip("rectangle.split.3x1", "Recovery cards: any two restore",
         "Keep the three cards in three different places. One card alone does not hold the full phrase, but it shows two thirds of the words; with a 12- or 15-word phrase the rest can be guessed with enough computing power, so hide every card."),
        Tip("person.2.slash", "Never share it",
         "Anyone with these words can take your funds from any device. No one from BitTool Signer will ever ask for them."),
        Tip("exclamationmark.shield", "Never type it into a website",
         "Only enter your recovery phrase into a wallet you trust, on a device you control, when you restore it."),
        Tip("key", "Back up any passphrase separately",
         "If this wallet uses a BIP39 passphrase, the words alone cannot restore it."),
        Tip("lock", "Your password is not a backup",
         "The wallet password only unlocks the copy on this device. The words restore the wallet anywhere."),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(tips) { tip in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tip.title).font(.headline)
                            Text(tip.detail).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    } icon: {
                        Image(systemName: tip.id).foregroundStyle(.tint)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listBottomInset()
            .navigationTitle("Security Tips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Backup check

/// Fill-in check, grid part: every position, masked except for a few blanks.
/// Tapping an empty blank makes it the next to fill; tapping a filled blank
/// takes its word out again.
struct BackupVerificationGrid: View {
    let verification: BackupVerification
    let onSelect: (Int) -> Void
    let onClear: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        let layout = WordGridColumns(cellPadding: 8, indexSample: "24.", indexStyle: .caption1)
            .layout(width: gridWidth, words: verification.chips.map(\.word) + ["••••••"], dynamicTypeSize: dynamicTypeSize)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: layout.columns), spacing: 8) {
            ForEach(0..<verification.wordCount, id: \.self) { position in
                Group {
                    if verification.isBlank(position) { blank(position, font: layout.wordFont) } else { masked(position, font: layout.wordFont) }
                }
                .id(BackupVerificationGrid.scrollID(position))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    static func scrollID(_ position: Int) -> String { "verification.cell.\(position)" }

    /// Hidden cells use the grid's shared word font, so every cell in the check looks alike.
    private func masked(_ position: Int, font: Font) -> some View {
        HStack(spacing: 6) {
            Text("\(position + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(verbatim: "••••••").font(font).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).frame(minHeight: 42)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Word \(position + 1), hidden")
    }

    private func blank(_ position: Int, font: Font) -> some View {
        let word = verification.word(at: position)
        let active = verification.activePosition == position
        return Button { word == nil ? onSelect(position) : onClear(position) } label: {
            HStack(spacing: 6) {
                Text("\(position + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(verbatim: word ?? "")
                    .font(font)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).frame(minHeight: 42)
            .background(active ? Color.accentColor.opacity(0.1) : Palette.background,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color.accentColor : word == nil ? Color.secondary.opacity(0.45) : Color.accentColor.opacity(0.4),
                              lineWidth: active ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: active)
        .accessibilityLabel("Word \(position + 1)")
        .accessibilityValue(word ?? (active ? "Empty, next to fill" : "Empty"))
        .accessibilityHint(word == nil ? "Fills this blank next" : "Removes this word")
        .accessibilityIdentifier("verification.slot.\(position)")
    }
}

/// Fill-in check, word part: the missing words, shuffled. Kept in the bottom
/// bar so they stay reachable while the grid scrolls.
struct BackupVerificationChips: View {
    let verification: BackupVerification
    let onPlace: (Int) -> Void

    var body: some View {
        CenteredFlowLayout(spacing: 8) {
            ForEach(verification.chips) { chip in
                let placed = verification.isPlaced(chip)
                Button { onPlace(chip.id) } label: {
                    Text(verbatim: chip.word)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(placed ? 0.15 : 0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(placed ? 0.3 : 1)
                .disabled(placed || verification.activePosition == nil)
                .sensoryFeedback(.selection, trigger: placed)
                .accessibilityLabel(chip.word)
                .accessibilityValue(placed ? "Placed" : "Available")
                .accessibilityIdentifier("verification.chip.\(chip.id)")
            }
        }
        .privacySensitive()
    }
}

/// Wraps its children into centered rows.
struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
