import SwiftUI

/// Summary → warnings → signing wallet → full details → authorize.
/// Everything shown is produced by the engine from the exact bytes to be signed.
struct RequestReviewView: View {
    @EnvironmentObject private var store: AppStore
    @State private var riskAccepted = false
    @State private var authorizing: SigningTask?
    @State private var confirmReject = false
    @State private var retrying = false
    @State private var retryError: String?

    var body: some View {
        if let review = store.review {
            ScrollView {
                VStack(spacing: 16) {
                    ReviewSummaryCard(review: review)
                    // The summary already shows the notice when the authorized
                    // address is the one in its counterparty box; a token
                    // transfer authorizes the token contract instead, which is
                    // a different address and gets its own card.
                    if let contract = review.contract, !ReviewSummaryCard.showsNotice(for: review) {
                        ContractNotice(contract: contract)
                    }
                    if !review.warnings.isEmpty { warnings(review) }
                    signingWallets(review)
                    ReviewDetailsCard(fields: review.fields)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Request fingerprint").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HashText(value: review.requestHash)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 20)
                .readableWidth()
            }
            .background(Palette.background)
            .navigationTitle("Review Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject", role: .destructive) {
                        if store.completedTaskIDs.isEmpty { reject() } else { confirmReject = true }
                    }
                    .accessibilityIdentifier("signing.reject")
                }
            }
            .bottomActionBar { signBar(review) }
            .confirmationDialog("Discard partial signatures?", isPresented: $confirmReject, titleVisibility: .visible) {
                Button("Reject Request", role: .destructive, action: reject)
            } message: {
                Text("Signatures already created for this request will be discarded.")
            }
            .sheet(item: $authorizing) { task in
                AuthorizeSheet(task: task, riskAcknowledged: riskAccepted) { riskAccepted = false }
            }
            .onChange(of: store.securityEpoch) { _, _ in riskAccepted = false; authorizing = nil }
            .onChange(of: review.requestHash) { _, _ in riskAccepted = false }
        }
    }

    private func reject() {
        riskAccepted = false
        withAnimation { store.clearRequest() }
    }

    // MARK: Sections

    private func warnings(_ review: TransactionReview) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                Callout(verbatim: warning, tone: isSevere(warning) ? .danger : .warning)
            }
        }
    }

    private func isSevere(_ warning: String) -> Bool {
        let upper = warning.uppercased()
        return upper.hasPrefix("HIGH RISK") || upper.hasPrefix("UNLIMITED") || upper.hasPrefix("HIGH FEE")
    }

    @ViewBuilder private func signingWallets(_ review: TransactionReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((store.plan?.tasks.count ?? 0) > 1 ? "Signing Wallets" : "Signing Wallet")
                .font(.headline)
            if let message = store.matchingError {
                VStack(alignment: .leading, spacing: 10) {
                    Label(ReviewText.phrase(message), systemImage: "xmark.octagon.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("signing.matchError")
                    Text(explanation(for: message))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.plan == nil && !store.hasSignedResponse && canRetry(message) {
                        Button {
                            retry()
                        } label: {
                            Label(retrying ? "Matching…" : "Match Again", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                        }
                        .disabled(retrying)
                        .accessibilityIdentifier("signing.retryMatch")
                    }
                    if let retryError { Text(retryError).font(.footnote).foregroundStyle(Palette.danger) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Palette.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            } else if let plan = store.plan {
                ForEach(plan.tasks) { task in
                    let fields = store.review?.fields ?? []
                    TaskCard(task: task, done: store.completedTaskIDs.contains(task.id),
                             showsAddress: !fields.contains { $0.label == "Requested signer" },
                             showsPath: !fields.contains { $0.label == "Derivation path" && $0.value.hasPrefix("m/") })
                }
                if plan.tasks.count > 1 {
                    Text("Each wallet signs with its own password. The final signature appears after every wallet has signed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding the matching wallet…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            }
        }
    }

    private func canRetry(_ message: String) -> Bool {
        message.contains("interrupted") || message.contains("changed")
    }

    private func explanation(for message: String) -> LocalizedStringKey {
        switch message {
        case "No matching wallet":
            return "This request does not belong to any wallet on this device. Check that you scanned the request for this wallet."
        case "Missing signer information":
            return "The request does not say which key should sign. Export it again from your other wallet with its account details."
        case "Ambiguous wallet match":
            return "More than one saved wallet matches. Delete the duplicate wallet, then scan again."
        case "Wallet setup required":
            return "A wallet needs repair before it can be matched. Open it in Wallets and repair its data."
        case "Unsupported signing protocol":
            return "BitTool Signer can show this request but cannot sign this kind of request."
        default:
            return "This request cannot be signed. Nothing has been signed."
        }
    }

    /// Compact per-request consent shown directly above the Sign button.
    private func acknowledgement(_ review: TransactionReview) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { riskAccepted.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: riskAccepted ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(riskAccepted ? Palette.warning : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.decodeStatus == .fullyDecoded ? "I understand the risks of this request" : "I understand this request can’t be fully verified")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(review.decodeStatus == .fullyDecoded ? "Read every warning above before signing." : "Some effects couldn’t be decoded on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: riskAccepted)
        .accessibilityValue(riskAccepted ? "Checked" : "Not checked")
        .accessibilityAddTraits(riskAccepted ? .isSelected : [])
        .accessibilityIdentifier("signing.risk")
    }

    @ViewBuilder private func signBar(_ review: TransactionReview) -> some View {
        if let task = store.pendingTasks.first, store.matchingError == nil {
            let blocked = review.requiresAcknowledgement && !riskAccepted
            if review.requiresAcknowledgement { acknowledgement(review) }
            if let total = store.plan?.tasks.count, total > 1 {
                Text("Signature \(store.completedTaskIDs.count + 1) of \(total)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            Button { authorizing = task } label: {
                ActionLabel("Sign with \(store.walletLabel(for: task.walletID))", systemImage: "signature", busy: store.busy)
            }
            .prominentAction()
            .disabled(blocked || store.busy)
            .accessibilityIdentifier("signing.authorize")
        } else if store.matchingError != nil {
            Button {} label: { ActionLabel("Cannot Sign", systemImage: "xmark.circle", prominent: false) }
                .secondaryAction()
                .disabled(true)
                .accessibilityIdentifier("signing.authorize")
        }
    }

    private func retry() {
        retrying = true; retryError = nil
        let epoch = store.securityEpoch
        Task {
            do { try await store.retryMatching() }
            catch { if epoch == store.securityEpoch, !(error is CancellationError) { retryError = error.localizedDescription } }
            retrying = false
        }
    }
}

// MARK: - Summary

struct ReviewSummaryCard: View {
    let review: TransactionReview

    /// The engine's structured display is authoritative. Field heuristics are
    /// only a fallback for results that carry no display at all, and never
    /// combine values from different instructions.
    private var counterparty: (label: String, value: String)? { Self.counterparty(of: review) }

    static func counterparty(of review: TransactionReview) -> (label: String, value: String)? {
        if let display = review.display {
            guard let value = display.counterparty else { return nil }
            return (display.counterpartyLabel ?? "To", value)
        }
        let candidates = review.fields.filter { ["Recipient", "Spender", "Operator"].contains($0.shortLabel) && AddressFormatter.looksLikeAddress($0.value) }
        guard candidates.count == 1, let field = candidates.first else { return nil }
        return (field.shortLabel == "Recipient" ? "To" : field.shortLabel, field.value)
    }

    /// Whether the summary's counterparty box is the one showing the
    /// known-contract notice, so it is not also shown as a separate card.
    static func showsNotice(for review: TransactionReview) -> Bool {
        guard let contract = review.contract, let counterparty = counterparty(of: review) else { return false }
        return counterparty.value.caseInsensitiveCompare(contract.address) == .orderedSame
    }

    private var amountText: String? {
        guard let display = review.display, let amount = display.amount else { return nil }
        return [amount, display.symbol].compactMap { $0 }.joined(separator: " ")
    }

    private var textHeadline: String? {
        if let display = review.display { return display.amount == nil ? display.headline : nil }
        return review.summary.isEmpty ? nil : review.summary
    }

    /// NFT amounts and headlines carry token IDs and raw-unit prices, so they
    /// are never cut off. Other reviews keep their existing limits.
    static func amountLineLimit(_ display: ReviewDisplay?) -> Int? { display?.isNFT == true ? nil : 2 }
    static func headlineLineLimit(_ display: ReviewDisplay?) -> Int? { display?.isNFT == true ? nil : 8 }

    var body: some View {
        VStack(spacing: 14) {
            // Side by side when they fit; stacked at large text sizes rather than truncated.
            ViewThatFits(in: .horizontal) {
                HStack {
                    networkBadge
                    Spacer(minLength: 8)
                    decodeBadge
                }
                VStack(alignment: .leading, spacing: 8) {
                    networkBadge
                    decodeBadge
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            icon
                .padding(.top, 4)
            VStack(spacing: 6) {
                Text(verbatim: ReviewText.phrase(review.display?.action ?? review.title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let amountText {
                    Text(verbatim: amountText)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .lineLimit(Self.amountLineLimit(review.display))
                        // NFT order prices can be 78 raw digits: they wrap instead of being cut off.
                        .fixedSize(horizontal: false, vertical: review.display?.isNFT == true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("review.headline")
                }
                if let secondary = review.display?.amount != nil ? review.display?.headline : nil {
                    Text(verbatim: ReviewText.headline(secondary)).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let textHeadline {
                    Text(verbatim: ReviewText.headline(textHeadline))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(Self.headlineLineLimit(review.display))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("review.headline")
                }
            }
            if let display = review.display, display.showsAssetBox {
                assetBox(display)
            }
            if let sections = review.display?.flowSections, !sections.isEmpty {
                flowBox(sections)
            }
            if let counterparty {
                VStack(spacing: 6) {
                    Text(verbatim: ReviewText.phrase(counterparty.label)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    AddressText(address: counterparty.value, font: .callout)
                        .multilineTextAlignment(.center)
                    if Self.showsNotice(for: review), let contract = review.contract {
                        ContractNotice(contract: contract, compact: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            if let note = review.display?.note {
                Label(note, systemImage: "checkmark.shield.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.success)
            }
            if let fee = review.display?.fee {
                // An energy budget is not a ceiling on the whole fee, so it is
                // never captioned as one.
                let shown = ReviewText.shortDecimal(fee)
                Text(review.display?.feeKind == "energyBudget"
                     ? "Energy budget up to \(shown) · total fee not known offline"
                     : "Network fee up to \(shown)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if review.riskLevel == .high {
                StatusPill(text: "High risk", systemImage: "exclamationmark.shield.fill", color: Palette.danger)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// Which asset the request moves: the contract, then the full token ID
    /// when the headline abbreviates it. Nothing here is verified offline.
    private func assetBox(_ display: ReviewDisplay) -> some View {
        VStack(spacing: 10) {
            if let contract = display.assetContract {
                VStack(spacing: 6) {
                    Text(verbatim: display.assetContractCaption)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    AddressText(address: contract, font: .callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.assetContract")
            }
            if let tokenID = display.summaryTokenID {
                if display.assetContract != nil { Divider() }
                VStack(spacing: 6) {
                    Text(display.tokenIDCaption)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: tokenID)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel(ReviewDisplay.spokenTokenID(tokenID))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.tokenId")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Marketplace order effects as labelled lists. Lines wrap at every text
    /// size; each list is read by VoiceOver as one element.
    private func flowBox(_ sections: [ReviewFlowSection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections) { section in
                if section.id != sections.first?.id { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.systemImage).foregroundStyle(section.tint)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.flow.\(section.id)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        if let asset = review.asset {
            TokenIcon(icon: asset.icon, symbol: asset.symbol, size: 60)
        } else if let kind = review.display?.assetKind {
            NFTGlyph(kind: kind, size: 60)
        } else if let brand = review.network?.brand ?? (review.chain == .evm ? nil : review.chain.primaryNetwork) {
            NetworkLogo(network: brand, size: 60)
        } else if review.chain == .evm {
            GenericNetworkLogo(size: 60)
        }
    }

    private var networkBadge: some View {
        HStack(spacing: 6) {
            if let brand = review.network?.brand {
                NetworkLogo(network: brand, size: 18)
            } else if review.chain != .evm {
                ChainLogo(chain: review.chain, size: 18)
            } else {
                GenericNetworkLogo(size: 18)
            }
            Text(review.networkName).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Palette.raised, in: Capsule())
    }

    private var decodeBadge: some View {
        switch review.decodeStatus {
        case .fullyDecoded:
            StatusPill(text: review.decodeStatus.label, systemImage: "checkmark.seal.fill", color: Palette.success)
        case .partiallyDecoded:
            StatusPill(text: review.decodeStatus.label, systemImage: "exclamationmark.triangle.fill", color: Palette.warning)
        case .opaque:
            StatusPill(text: review.decodeStatus.label, systemImage: "questionmark.diamond.fill", color: Palette.danger)
        }
    }
}

private extension ReviewFlowSection {
    var tint: Color {
        switch kind {
        case .give: Palette.warning
        case .receive: .accentColor
        case .others: .secondary
        }
    }
}

/// How a review's own vocabulary reads. The model keeps the facts; the wording
/// lives here, where a LocalizedStringKey literal is what Xcode extracts.
extension DecodeStatus {
    var label: LocalizedStringKey {
        switch self {
        case .fullyDecoded: "Decoded on device"
        case .partiallyDecoded: "Partially decoded"
        case .opaque: "Not decoded"
        }
    }
}

extension ReviewFlowSection {
    var title: LocalizedStringKey {
        switch kind {
        case .give: "You give"
        case .receive: "You receive"
        case .others: "Also paid out"
        }
    }
}

extension ReviewAssetKind {
    /// Read out by VoiceOver in place of the glyph.
    var accessibilityLabel: LocalizedStringKey {
        switch self {
        case .nft: "NFT"
        case .nftOrToken: "NFT or token"
        case .multiToken: "ERC-1155 token"
        case .nftOrder: "NFT order"
        }
    }
}

extension ReviewDisplay {
    /// The value may be an ERC-20 amount or allowance rather than a token ID,
    /// so the ambiguous case never calls it just a token ID.
    var tokenIDCaption: LocalizedStringKey { tokenIDIsAmbiguous ? "Token ID or raw amount" : "Token ID" }
}

private extension ReviewContract.Role {
    /// Caption when the library identifies the address.
    var knownTitle: LocalizedStringKey {
        switch self {
        case .spender: "Known public contract (spender)"
        case .operator_: "Known public contract (operator)"
        case .contract: "Known public contract"
        }
    }

    /// Caption when it does not.
    var unknownTitle: LocalizedStringKey {
        switch self {
        case .spender: "Spender is not a known contract"
        case .operator_: "Operator is not a known contract"
        case .contract: "Contract is not in the known list"
        }
    }

    /// How the address itself is labelled in the card.
    var addressCaption: LocalizedStringKey {
        switch self {
        case .spender: "Spender"
        case .operator_: "Operator"
        case .contract: "Contract"
        }
    }
}

/// What the bundled known-contract library says about the address a request
/// authorizes. A listing identifies a deployment; it never endorses a request,
/// so a hit is amber, never green. An address that is not listed is stated as
/// not listed, which is ordinary for a new or private deployment, and is only
/// coloured as a risk where it is one: a spender or operator being authorized.
struct ContractNotice: View {
    let contract: ReviewContract
    /// Inside the summary's counterparty box the address is already on screen,
    /// so the notice is one line under it instead of a card of its own.
    var compact = false

    private enum Kind { case known, token, unlistedSpender, unlisted }

    private var kind: Kind {
        if contract.known { return .known }
        if contract.token != nil { return .token }
        return contract.role == .contract ? .unlisted : .unlistedSpender
    }

    private var color: Color {
        switch kind {
        case .known: Palette.warning
        case .token: .accentColor
        case .unlistedSpender: Palette.danger
        case .unlisted: .secondary
        }
    }

    private var symbol: String {
        switch kind {
        case .known: "checkmark.seal.fill"
        case .token: "info.circle.fill"
        case .unlistedSpender: "exclamationmark.triangle.fill"
        case .unlisted: "questionmark.circle.fill"
        }
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .known: contract.role.knownTitle
        case .token: "Recognized token contract"
        case .unlistedSpender, .unlisted: contract.role.unknownTitle
        }
    }

    /// The identification, when there is one. The unlisted cases carry no
    /// detail here: the engine's own warning says what to do about it.
    private var detail: String? {
        switch kind {
        case .known: [contract.name, contract.subtitle].compactMap { $0 }.joined(separator: " — ")
        case .token: contract.token
        case .unlistedSpender, .unlisted: nil
        }
    }

    var body: some View {
        if compact { line } else { card }
    }

    /// One line under an address that is already shown.
    private var line: some View {
        VStack(spacing: 2) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if contract.everyChain { everyChainNote }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review.contractNotice")
    }

    /// A card of its own, for an authorized address the summary does not show
    /// (a token transfer authorizes the token contract, not the recipient).
    private var card: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).imageScale(.medium)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(verbatim: detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(contract.role.addressCaption)
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    AddressText(address: contract.address, font: .footnote)
                }
                if contract.everyChain { everyChainNote }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review.contractNotice")
    }

    private var everyChainNote: some View {
        Text("Same address on every EVM network.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Offline NFT mark: artwork is never fetched. The rounded square sets it
/// apart from circular token and network logos. An ambiguous NFT-or-token
/// request carries a warning-coloured question-mark badge.
struct NFTGlyph: View {
    let kind: ReviewAssetKind
    var size: CGFloat = 60

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color.accentColor.opacity(0.14))
            .overlay {
                Image(systemName: kind.systemImage)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .overlay(alignment: .bottomTrailing) {
                if kind == .nftOrToken {
                    Image(systemName: "questionmark")
                        .font(.system(size: size * 0.2, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.38, height: size * 0.38)
                        .background(Circle().fill(Palette.warning))
                        .padding(max(1.5, size * 0.04))
                        .background(Circle().fill(Palette.card))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityLabel)
    }
}

// MARK: - Details

struct ReviewDetailsCard: View {
    let fields: [ReviewField]
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details").font(.headline).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.element.id) { offset, field in
                    row(field)
                    if offset < fields.count - 1 { Divider().padding(.vertical, 10) }
                }
            }
            .cardBackground()
        }
    }

    /// How a Details value is drawn. Decided by label first, then by value.
    enum RowStyle: Equatable {
        /// A copyable, grouped address.
        case address
        /// Token IDs, quantities and item lists: whole, plain and wrapping.
        case identifier
        /// Long text collapsed behind "Show All".
        case collapsible
        case text
    }

    static func rowStyle(_ field: ReviewField) -> RowStyle {
        if field.rendersAsAddress { return .address }
        if field.isTokenIdentifier && field.value.count <= 4_096 { return .identifier }
        return field.isLong ? .collapsible : .text
    }

    @ViewBuilder private func row(_ field: ReviewField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: ReviewText.label(field.label)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch Self.rowStyle(field) {
            case .address:
                CopyableAddress(address: field.value, font: .footnote)
            case .identifier:
                // Never styled as an address, never collapsed.
                Text(verbatim: field.value)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .collapsible:
                let open = expanded.contains(field.id)
                Text(verbatim: open ? field.value : String(field.value.prefix(280)) + "…")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(open ? "Show Less" : "Show All") {
                    withAnimation(.snappy) { if open { expanded.remove(field.id) } else { expanded.insert(field.id) } }
                }
                .font(.footnote.weight(.semibold))
            case .text:
                Text(verbatim: field.value)
                    .font(looksTechnical(field.value) ? .footnote.monospaced() : .subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func looksTechnical(_ value: String) -> Bool {
        value.hasPrefix("0x") || value.hasPrefix("m/") || value.range(of: "^[0-9a-fA-F]{16,}$", options: .regularExpression) != nil
            || value.contains("\n")
    }
}

// MARK: - Tasks

private struct TaskCard: View {
    let task: SigningTask
    let done: Bool
    /// Details usually list the requested signer and derivation path (EVM, Solana,
    /// TRON); the card repeats only what they lack, such as a Bitcoin PSBT's keys.
    let showsAddress: Bool
    let showsPath: Bool
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                WalletAvatar(identity: store.avatarIdentity(for: task.walletID), name: store.walletLabel(for: task.walletID), size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.walletLabel(for: task.walletID)).font(.headline)
                    Text("Fingerprint \(store.fingerprint(for: task.walletID))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if done {
                    StatusPill(text: "Signed", systemImage: "checkmark", color: Palette.success)
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("Awaiting password")
                }
            }
            if showsAddress {
                ForEach(task.displayAddresses, id: \.self) { address in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signing address").font(.caption).foregroundStyle(.secondary)
                        AddressText(address: address, font: .footnote)
                    }
                }
            }
            if showsPath {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.displayPaths.count > 1 ? "Derivation paths" : "Derivation path").font(.caption).foregroundStyle(.secondary)
                    Text(task.displayPaths.joined(separator: "\n")).font(.footnote.monospaced())
                }
            }
            if !task.inputs.isEmpty {
                DetailLine(label: "Inputs signed", value: task.inputs.map { "#\($0 + 1)" }.joined(separator: ", "), monospaced: false)
            }
            if let slot = task.signerSlot {
                DetailLine(label: "Signer position", value: "\(slot + 1)", monospaced: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

// MARK: - Authorization

struct AuthorizeSheet: View {
    let task: SigningTask
    let riskAcknowledged: Bool
    var onSigned: () -> Void = {}
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var operation = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            // Scrolls instead of compressing text at the medium detent on small
            // screens and with large Dynamic Type; Sign stays pinned at the bottom.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WalletIdentityHeader(walletID: task.walletID, size: 48)
                    PasswordField(.walletPassword, text: $password)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(sign)
                        .padding(14)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if let error {
                        Callout(verbatim: error, tone: .danger)
                    } else {
                        Text("The password decrypts this wallet for this signature only.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Metrics.pagePadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.background)
            .bottomActionBar {
                Button(action: sign) { ActionLabel("Sign", systemImage: "signature", busy: busy) }
                    .prominentAction()
                    .disabled(password.isEmpty || busy)
                    .accessibilityIdentifier("authorize.sign")
            }
            .navigationTitle("Authorize Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() }.disabled(busy) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
        .task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            focused = true
        }
        .onChange(of: store.securityEpoch) { _, _ in cancel() }
        .onDisappear { operation = UUID(); password = "" }
    }

    private func sign() {
        guard !password.isEmpty, !busy else { return }
        let entered = password, current = UUID(), epoch = store.securityEpoch
        password = ""; error = nil; busy = true; operation = current
        Task {
            do {
                try await store.sign(taskID: task.id, password: entered, riskAcknowledged: riskAcknowledged)
                guard operation == current else { return }
                busy = false
                onSigned()
                dismiss()
            } catch {
                guard operation == current else { return }
                busy = false
                if epoch == store.securityEpoch, !(error is CancellationError) {
                    self.error = error.localizedDescription
                    focused = true
                }
            }
        }
    }

    private func cancel() {
        operation = UUID(); password = ""; busy = false
        dismiss()
    }
}
