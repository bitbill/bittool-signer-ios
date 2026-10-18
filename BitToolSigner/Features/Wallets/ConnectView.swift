import SwiftUI

struct AccountProfile: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    static let bitcoinSingle = [
        Self(id: "native", title: "Native SegWit", detail: "BIP84 · bc1q…"),
        Self(id: "taproot", title: "Taproot", detail: "BIP86 · bc1p…"),
        Self(id: "nested", title: "Nested SegWit", detail: "BIP49 · 3…"),
        Self(id: "legacy", title: "Legacy", detail: "BIP44 · 1…"),
    ]
    static let bitcoinMulti = [
        Self(id: "multisig-native", title: "Native SegWit", detail: "BIP48 · P2WSH"),
        Self(id: "multisig-nested", title: "Nested SegWit", detail: "BIP48 · P2SH-P2WSH"),
    ]
    static let solana = [
        Self(id: "standard", title: "Standard", detail: "m/44'/501'/0'/0'"),
        Self(id: "trust", title: "Trust", detail: "m/44'/501'/0'"),
        Self(id: "legacy", title: "Legacy", detail: "m/44'/501'"),
    ]
}

/// Segmented chain switcher with each network's own logo. The selected chain
/// gets an accent-tinted, outlined tile and full-colour logo; the others are
/// muted, so the selection is obvious in light and dark mode alike.
struct ChainPicker: View {
    @Binding var selection: Chain
    @Namespace private var namespace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Chain.allCases) { chain in
                let selected = selection == chain
                Button {
                    withAnimation(.snappy(duration: 0.28)) { selection = chain }
                } label: {
                    VStack(spacing: 5) {
                        ChainLogo(chain: chain, size: 26)
                            .saturation(selected ? 1 : 0.35)
                            .opacity(selected ? 1 : 0.6)
                            .scaleEffect(selected ? 1.06 : 1)
                        // Four names do not fit at accessibility sizes; the logo and
                        // the selected tile carry the choice, VoiceOver reads the name.
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(chain.name)
                                .font(.caption.weight(selected ? .bold : .medium))
                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                                }
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chain.longName)
                .accessibilityAddTraits(selection == chain ? .isSelected : [])
                .accessibilityIdentifier("chain." + chain.rawValue)
            }
        }
        .padding(4)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

struct ConnectView: View {
    let walletID: UUID
    @EnvironmentObject private var store: AppStore
    @State private var chain: Chain
    @State private var multisig = false
    @State private var btcSingle = AppStore.defaultConnectProfile
    @State private var btcMulti = "multisig-native"
    @State private var btcMode = AppStore.defaultConnectMode
    @State private var evmMode = "wallet"
    @State private var solanaProfile = "standard"
    @State private var solanaMode = "wallet"
    @State private var tronIndex = 0
    @State private var level: PairingLevel = .wallet
    @State private var walletPayload: WalletPairingPayload?
    @State private var walletLoadedKey: String?
    @State private var payload: PairingPayload?
    @State private var loadedKey: String?
    @State private var error: String?
    @State private var copied = false
    /// Images of the prefetched opening QR, used only while its frames are shown.
    @State private var preparedImages: [UIImage]?

    /// `prefetched` is the wallet's prepared wallet-level QR, the one this page
    /// opens on, so it is complete on its first frame and nothing changes during
    /// the push. Coin Level loads when it is chosen.
    init(walletID: UUID, initialChain: Chain = .bitcoin, initialLevel: PairingLevel = .wallet, prefetched: AppStore.PreparedConnect? = nil) {
        self.walletID = walletID
        _chain = State(initialValue: initialChain)
        _level = State(initialValue: initialLevel)
        if let prefetched {
            _walletPayload = State(initialValue: prefetched.payload)
            _preparedImages = State(initialValue: prefetched.images)
            _walletLoadedKey = State(initialValue: Self.walletKeyValue)
        }
    }

    private var profile: String {
        switch chain {
        case .bitcoin: multisig ? btcMulti : btcSingle
        case .solana: solanaProfile
        default: "standard"
        }
    }
    private var outputMode: String {
        switch chain {
        case .bitcoin: multisig ? "accountXpub" : btcMode
        case .evm: evmMode
        case .solana: solanaMode
        case .tron: "address"
        }
    }
    /// Only TRON exports a chosen address index; every other chain exports index 0.
    private var addressIndex: Int { chain == .tron ? tronIndex : 0 }
    private var requestKey: String { Self.key(chain: chain, profile: profile, outputMode: outputMode, index: addressIndex) }
    private static func key(chain: Chain, profile: String, outputMode: String, index: Int) -> String {
        [chain.rawValue, profile, outputMode, String(index)].joined(separator: "|")
    }
    private var current: PairingPayload? { loadedKey == requestKey ? payload : nil }
    private static let walletKeyValue = "wallet"
    private var walletKey: String { Self.walletKeyValue }
    private var currentWallet: WalletPairingPayload? { walletLoadedKey == walletKey ? walletPayload : nil }
    /// What the toolbar copies: exactly the text of the QR on screen.
    private var copyText: String? { level == .coin ? current?.text : currentWallet?.text }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("Pairing level", selection: $level.animation(.snappy(duration: 0.25))) {
                    Text("Wallet Level").tag(PairingLevel.wallet)
                    Text("Coin Level").tag(PairingLevel.coin)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("connect.level")
                switch level {
                case .coin:
                    ChainPicker(selection: $chain)
                    options
                    qrSection
                    if let current { verification(current) }
                    notes
                    IntendedWalletsView(chain: chain, profile: profile, mode: outputMode)
                case .wallet:
                    WalletLevelPairingView(payload: currentWallet, error: error,
                                           masterFingerprint: store.publicMetadata(for: walletID)?.masterFingerprint,
                                           initialImages: preparedImages)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .background(Palette.background)
        .navigationTitle(level == .coin ? "Pair \(chain.name)" : "Pair Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let copyText { Clipboard.copy(copyText); copied = true }
                } label: {
                    Label("Copy QR Data", systemImage: "doc.on.doc")
                }
                .disabled(copyText == nil)
                .accessibilityIdentifier("connect.copy")
            }
        }
        .task(id: level == .coin ? requestKey : walletKey) { await load() }
        .copiedToast($copied)
    }

    @ViewBuilder private var options: some View {
        switch chain {
        case .bitcoin:
            VStack(spacing: 12) {
                Picker("Account type", selection: $multisig.animation(.snappy)) {
                    Text("Single-sig").tag(false)
                    Text("Multisig").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("connect.btcKind")
                ProfileMenu(title: "Address type",
                            profiles: multisig ? AccountProfile.bitcoinMulti : AccountProfile.bitcoinSingle,
                            selection: multisig ? $btcMulti : $btcSingle)
            }
        case .solana:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Derivation path", selection: $solanaProfile) {
                    ForEach(AccountProfile.solana) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("connect.solanaProfile")
                Text(AccountProfile.solana.first { $0.id == solanaProfile }?.detail ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        case .tron:
            AddressIndexControl(index: $tronIndex, pathPrefix: "m/44'/195'/0'/0/")
        case .evm:
            EmptyView()
        }
    }

    private var qrSection: some View {
        VStack(spacing: 12) {
            if let current {
                QRCodeView(frames: current.frames, maxSide: 300)
                    .transition(.opacity)
                Text(chain == .bitcoin && multisig ? "Scan with your multisig coordinator" : "Scan with your watch-only wallet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let error {
                Callout(verbatim: error, tone: .danger)
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Palette.card)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 300)
                    .overlay(ProgressView())
            }
            if let modes = exportModes {
                Picker("Export as", selection: modeBinding) {
                    ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pairing.outputMode")
                .padding(.top, 4)
            }
        }
        .animation(.smooth(duration: 0.2), value: current)
    }

    private var exportModes: [(String, String)]? {
        switch chain {
        case .bitcoin: multisig ? nil : [("accountXpub", "Account XPUB"), ("address", "Address")]
        case .evm, .solana: [("wallet", "Wallet"), ("address", "Address")]
        case .tron: nil
        }
    }

    private var modeBinding: Binding<String> {
        switch chain {
        case .bitcoin: $btcMode
        case .evm: $evmMode
        case .solana: $solanaMode
        case .tron: .constant("address")
        }
    }

    private func verification(_ payload: PairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !payload.address.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chain == .bitcoin ? "Verify the first receive address" : "Verify the address")
                        .font(.subheadline.weight(.semibold))
                    CopyableAddress(address: payload.address, font: .callout)
                }
                Divider()
            }
            if outputMode == "accountXpub" || (chain == .evm && outputMode == "wallet") {
                DetailLine(label: chain == .bitcoin && multisig ? "Cosigner account path" : "Account path", value: payload.path)
                if !payload.address.isEmpty {
                    DetailLine(label: "First address path", value: payload.path + "/0/0")
                }
            } else {
                DetailLine(label: "Derivation path", value: payload.path)
            }
            // Format, then fingerprint, then payload — the same order as wallet level.
            if let view = payload.payloadView {
                DetailLine(label: "Format", value: view.summary, monospaced: false)
            }
            if let fingerprint = store.publicMetadata(for: walletID)?.masterFingerprint {
                DetailLine(label: "Master fingerprint", value: fingerprint.uppercased())
            }
            if let view = payload.payloadView {
                PayloadDisclosure(verbatim: view.title, text: view.text, notes: payloadNotes(view), identifier: "connect.payload")
            }
        }
        .cardBackground()
    }

    /// UR payloads store fingerprints as 32-bit numbers; relate them to the hex
    /// fingerprint shown everywhere else.
    private func payloadNotes(_ view: QRPayloadView) -> [String] {
        guard view.format == .json, let hex = store.publicMetadata(for: walletID)?.masterFingerprint,
              let value = UInt32(hex, radix: 16), view.text.contains(String(value)) else { return [] }
        return ["Fingerprints are stored as 32-bit numbers: \(value) is fingerprint \(hex.uppercased())."]
    }

    @ViewBuilder private var notes: some View {
        if outputMode == "address" {
            Callout("Address only. No public key or derivation path is included.")
        } else if chain == .bitcoin && multisig {
            Callout("This exports one cosigner key. Your multisig coordinator combines all cosigner keys and the threshold to create the wallet and its addresses.")
        }
    }

    private func load() async {
        if level == .wallet { await loadWallet(); return }
        let key = requestKey
        if loadedKey == key, payload != nil { return } // Opened with the prefetched QR.
        let first = loadedKey == nil
        error = nil
        do {
            let value = try await store.pairing(walletID: walletID, chain: chain, profile: profile, outputMode: outputMode, index: addressIndex)
            try Task.checkCancellation()
            guard key == requestKey else { return }
            // The first result may land while the page is still sliding in: apply it
            // without the fade so SwiftUI does not animate during the push.
            var transaction = Transaction()
            transaction.disablesAnimations = first
            withTransaction(transaction) { payload = value; loadedKey = key }
        } catch {
            if !Task.isCancelled, key == requestKey, !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func loadWallet() async {
        let key = walletKey
        error = nil
        do {
            let value = try await store.walletPairing(walletID: walletID)
            try Task.checkCancellation()
            guard key == walletKey else { return }
            walletPayload = value; walletLoadedKey = key
        } catch {
            if !Task.isCancelled, key == walletKey, !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}

enum PairingLevel: Hashable { case coin, wallet }

/// BitTool Signer wallet-level pairing (`bittool-signer-wallet` v1): one QR carrying the
/// watch information for Bitcoin, EVM, TRON and Solana at once, for multi-chain
/// wallets that implement it: the account xpubs for Bitcoin, EVM and TRON (so the
/// wallet derives every address without scanning again) and one Solana address,
/// since hardened Ed25519 derivation has no xpub.
/// Coin level stays the choice for Sparrow, MetaMask and other wallets that read
/// each chain's standard format.
struct WalletLevelPairingView: View {
    let payload: WalletPairingPayload?
    let error: String?
    let masterFingerprint: String?
    /// Images of the prefetched QR, so the page is complete on its first frame.
    var initialImages: [UIImage]?

    private static let chains: [(code: String, chain: Chain)] = [("btc", .bitcoin), ("evm", .evm), ("tron", .tron), ("sol", .solana)]

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("One animated QR code for all four chains")
                    .font(.headline)
                Text("Includes an account xpub for each Bitcoin address type (bc1q, bc1p, 3, 1), for EVM and for TRON, plus all three Solana addresses. Your wallet can then use every Bitcoin, EVM and TRON address without scanning again. Hold the camera steady until every frame is read.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(Self.chains, id: \.code) { item in
                            ChainLogo(chain: item.chain, size: 18)
                                .accessibilityLabel(item.chain.longName)
                        }
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text("BTC · EVM · TRON · SOL").font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let payload {
                // An animated multi-part QR, drawn as large as the screen allows.
                QRCodeView(frames: payload.frames, maxSide: 360, initialImages: initialImages)
                    .accessibilityIdentifier("connect.walletQR")
                    .transition(.opacity)
                Text("Scan with BitTool Wallet or another wallet that supports BitTool Signer wallet pairing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                verification(payload)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Works with").font(.headline)
                    WalletGroup(title: "One QR for every chain", systemImage: "qrcode.viewfinder", wallets: CompatibleWallets.walletLevel)
                    Text("Always compare the first addresses in both apps before receiving funds.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SubmitWalletLink()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
                .accessibilityIdentifier("connect.walletLevelWallets")
            } else if let error {
                Callout(verbatim: error, tone: .danger)
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Palette.card)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 300)
                    .overlay(ProgressView())
            }
            Callout("Chain-specific QR codes (Coin Level) remain the choice for Sparrow, MetaMask, Solflare and the other wallets listed there.")
        }
        .animation(.smooth(duration: 0.2), value: payload)
    }

    /// "Bitcoin · Taproot", "Solana · Trust" and so on, reusing the same preset
    /// names the Coin Level pickers show. Nil where the chain has one account.
    private static func accountName(chain code: String, profile: String) -> String? {
        guard let chain = chains.first(where: { $0.code == code })?.chain else { return nil }
        let presets: [AccountProfile]
        switch code {
        case "btc": presets = AccountProfile.bitcoinSingle
        case "sol": presets = AccountProfile.solana
        default: return nil
        }
        guard let title = presets.first(where: { $0.id == profile })?.title else { return nil }
        return chain.longName + " · " + title
    }

    private func verification(_ payload: WalletPairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify the first address of each account")
                .font(.subheadline.weight(.semibold))
            ForEach(payload.firstAddresses) { line in
                if let chain = Self.chains.first(where: { $0.code == line.chain })?.chain {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ChainLogo(chain: chain, size: 20)
                            // Bitcoin and Solana contribute several accounts, so
                            // the row names which one it is.
                            Text(verbatim: Self.accountName(chain: line.chain, profile: line.profile) ?? chain.longName)
                                .font(.footnote.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(line.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        CopyableAddress(address: line.address, font: .callout)
                    }
                    .accessibilityElement(children: .contain)
                    Divider()
                }
            }
            DetailLine(label: "Format", value: "bittool-signer-wallet v1 · ur:bytes (canonical CBOR) · \(payload.payloadBytes) bytes", monospaced: false)
            if let masterFingerprint { DetailLine(label: "Master fingerprint", value: masterFingerprint.uppercased()) }
            PayloadDisclosure(title: "Payload (JSON)", text: payload.json, identifier: "connect.walletJSON")
            Text("Public addresses and public keys only. No private key, recovery phrase or passphrase is included.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardBackground()
    }
}

/// A receive index: the stepper covers nearby indexes and the number field
/// accepts any non-hardened BIP32 index, 0 through 2,147,483,647.
struct AddressIndexControl: View {
    @Binding var index: Int
    let pathPrefix: String
    @FocusState private var editing: Bool
    @State private var text = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var narrowField: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var wideField: CGFloat = 116

    static let maximum = 2_147_483_647

    var body: some View {
        // Side by side normally; at accessibility sizes the label sits above the controls.
        let row = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        VStack(alignment: .leading, spacing: 6) {
            row {
                Text("Address index")
                    .font(.subheadline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .layoutPriority(1)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                TextField("0", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .focused($editing)
                    .frame(width: fieldWidth)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    .accessibilityLabel("Address index")
                    .accessibilityIdentifier("connect.tronIndex.field")
                Stepper("Address index", value: $index, in: 0...Self.maximum)
                    .labelsHidden()
                    .accessibilityIdentifier("connect.tronIndex")
            }
            Text(pathPrefix + String(index))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Derivation path \(pathPrefix + String(index))")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { text = String(index) }
        // The field always shows the exported index: the stepper updates it while
        // editing too, non-digits are dropped and larger values clamp to the maximum.
        .onChange(of: index) { _, value in if text != String(value) { text = String(value) } }
        .onChange(of: text) { _, value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(10))
            if digits != value { text = digits; return }
            guard let number = Int(digits) else { return }
            let clamped = min(number, Self.maximum)
            if clamped != number { text = String(clamped); return }
            if clamped != index { index = clamped }
        }
        .onChange(of: editing) { _, focused in if !focused { text = String(index) } }
        .toolbar {
            if editing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }

    /// Wide enough for the typed digits, without jumping on every keystroke.
    private var fieldWidth: CGFloat { text.count > 5 ? wideField : narrowField }
}

/// Menu picker presented as a full-width row, used for option lists that do
/// not fit a segmented control on narrow phones.
struct ProfileMenu: View {
    let title: LocalizedStringKey
    let profiles: [AccountProfile]
    @Binding var selection: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var current: AccountProfile? { profiles.first { $0.id == selection } }
    /// Side by side normally; stacked at accessibility sizes so no word breaks.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        // A Menu with its own label: a menu-style Picker adds system insets that
        // differ between iOS versions, which left the value almost touching the
        // card edge. The whole row opens the menu.
        Menu {
            Picker(title, selection: $selection) {
                ForEach(profiles) { Text($0.title).tag($0.id) }
            }
        } label: {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).foregroundStyle(.primary)
                    Text(current?.detail ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                HStack(spacing: 5) {
                    Text(current?.title ?? "")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .imageScale(.small)
                }
                .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue([current?.title, current?.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("profile.menu")
    }
}

/// Wallets documented to work with this export, grouped by what they can do.
/// Listing a wallet is not a compatibility certification; people should
/// always compare the first address in both apps.
struct IntendedWalletsView: View {
    let chain: Chain
    let profile: String
    let mode: String

    private var wallets: [CompatibleWallet] { CompatibleWallets.wallets(chain: chain, profile: profile, mode: mode) }

    var body: some View {
        let signing = wallets.filter { $0.support == .signing }, watching = wallets.filter { $0.support == .watchOnly }
        if !wallets.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Works with").font(.headline)
                if !signing.isEmpty {
                    WalletGroup(title: profile.hasPrefix("multisig-") ? "Multisig coordinators · sign by QR" : "Watch and sign by QR",
                                systemImage: "qrcode.viewfinder", wallets: signing)
                }
                if !watching.isEmpty {
                    WalletGroup(title: "Watch only", systemImage: "eye", wallets: watching)
                    Text(chain == .tron
                         ? "These wallets can show this address’s balance. No mainstream wallet currently sends TRON transactions to a QR signer in BitTool Signer’s format."
                         : "These wallets can show this address’s balance but cannot send its transactions to BitTool Signer for signing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Based on each wallet’s documentation or source code, or its official QR hardware-wallet guide (September 2026). Versions change: always compare the first address in both apps before receiving funds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SubmitWalletLink()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .accessibilityIdentifier("connect.wallets")
        }
    }
}

/// The last line of a "Works with" block: how to get another wallet listed.
struct SubmitWalletLink: View {
    var body: some View {
        NavigationLink { SubmitWalletView() } label: {
            Label("Submit a Wallet", systemImage: "envelope")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("connect.submitWallet")
    }
}

/// A titled grid of wallet icons, names and platforms.
struct WalletGroup: View {
    let title: LocalizedStringKey
    let systemImage: String
    let wallets: [CompatibleWallet]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize >= .xxLarge ? 260 : 140), spacing: 10, alignment: .leading)],
                      alignment: .leading, spacing: 12) {
                ForEach(wallets) { wallet in
                    HStack(spacing: 9) {
                        WalletAppIcon(asset: wallet.asset, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wallet.name).font(.subheadline).lineLimit(2).minimumScaleFactor(0.85)
                            Text(wallet.platforms).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct WalletAppIcon: View {
    let asset: String
    var size: CGFloat = 26
    var body: some View {
        Group {
            if UIImage(named: asset) != nil {
                Image(asset).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
