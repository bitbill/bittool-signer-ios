import SwiftUI

/// First screen when no wallet exists. Create/Import intent is preserved through
/// the one-time introduction.
struct WelcomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("onboardingVersionCompleted") private var onboardingVersion = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var legal: LegalDocument?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    hero
                    Spacer(minLength: 28)
                    features
                    Spacer(minLength: 28)
                    networks
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 28)
                .frame(minHeight: proxy.size.height)
                .readableWidth(520)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(alignment: .top) {
            RadialGradient(colors: [Color.accentColor.opacity(0.16), .clear], center: .top, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .background(Palette.background.ignoresSafeArea())
        // The bar ends in the legal links, not a button, so they sit closer to
        // the edge than an action row would.
        .bottomActionBar(maxWidth: 520, bottomPadding: 0) {
            Button { start(.create) } label: { ActionLabel("Create New Wallet", systemImage: "plus") }
                .prominentAction()
                .accessibilityIdentifier("welcome.create")
            Button { start(.restore) } label: { ActionLabel("Import Existing Wallet", systemImage: "square.and.arrow.down", prominent: false) }
                .secondaryAction()
                .accessibilityIdentifier("welcome.import")
            HStack(spacing: 6) {
                Button("Terms of Use") { legal = .terms }.accessibilityIdentifier("welcome.terms")
                Text("·").foregroundStyle(.tertiary)
                Button("Privacy Policy") { legal = .privacy }.accessibilityIdentifier("welcome.privacy")
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            // On top of the bar's own 10pt row spacing: the legal links are a
            // separate thought from the two actions above them.
            .padding(.top, 12)
        }
        .sheet(item: $legal) { LegalDocumentSheet(document: $0) }
        .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.8)) { appeared = true } }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            BrandTile(size: 96)
                .scaleEffect(appeared ? 1 : 0.9)
                .opacity(appeared ? 1 : 0)
            Text("BitTool Signer")
                .font(.largeTitle.weight(.bold))
            Text("Air-gapped signing. For everyone.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 18) {
            feature("lock.iphone", "Keys stay on this device", "Built to work entirely offline. No accounts, no cloud.")
            feature("chevron.left.forwardslash.chevron.right", "Fully open source",
                    "Every line that touches your keys is published. Read it, or rebuild it and compare.")
            feature("checkmark.shield", "Know what you sign", "Scan a request, see it decoded and matched to your wallet, then sign it here.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var networks: some View {
        VStack(spacing: 10) {
            NetworkLogoStack(size: 28, ring: Palette.background)
            Text("Bitcoin, Ethereum, BNB Chain, Arbitrum, Base, TRON and Solana")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func start(_ intent: SetupIntent) {
        router.startSetup(intent, firstWallet: store.wallets.isEmpty, introductionCompleted: onboardingVersion >= 1)
    }
}

/// Three-page introduction shown before the first wallet is created or imported.
/// Safety guidance is a required step; there is intentionally no "Skip".
struct OnboardingView: View {
    var intent: SetupIntent? = nil
    var readOnly = false
    var onComplete: () -> Void = {}
    var onCancel: () -> Void = {}
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: LocalizedStringKey
        let body: LocalizedStringKey
        let points: [Point]
    }

    /// A key point on an introduction page. The SF Symbol is the identity, so
    /// the text can be translated without changing what `ForEach` tracks.
    private struct Point: Identifiable {
        let id: String
        let text: LocalizedStringKey
        init(_ symbol: String, _ text: LocalizedStringKey) { id = symbol; self.text = text }
    }

    private let pages: [Page] = [
        Page(symbol: "lock.iphone", title: "Offline by Design",
             body: "Your keys are created, encrypted and used only on this device. BitTool Signer works without a network connection.",
             points: [Point("key.fill", "Recovery phrases never leave the app"),
                      Point("wifi.slash", "No accounts, servers or cloud sync"),
                      Point("hand.raised.fill", "Every signature needs your wallet password")]),
        Page(symbol: "qrcode.viewfinder", title: "Built for Compatibility",
             body: "Pair BitTool Signer with a watch-only wallet on another device. It prepares transactions; BitTool Signer reviews and signs them.",
             points: [Point("arrow.left.arrow.right", "Open BC-UR and PSBT QR standards"),
                      Point("square.stack.3d.up.fill", "Bitcoin, EVM networks, TRON and Solana"),
                      Point("text.magnifyingglass", "Requests are decoded before you sign")]),
        Page(symbol: "airplane", title: "Prepare Your Device",
             body: "For the strongest isolation, use a dedicated iPhone and keep its connections off.",
             points: [Point("airplane", "Turn on Airplane Mode"),
                      Point("wifi.slash", "Confirm Wi‑Fi, cellular data and Bluetooth are off"),
                      Point("antenna.radiowaves.left.and.right.slash", "If iOS asks to allow wireless data, choose Don’t Allow: the app never connects"),
                      Point("eye.slash.fill", "Keep your recovery phrase private: anyone with it can take your funds")]),
    ]

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index]).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.smooth, value: page)
            .background(Palette.background.ignoresSafeArea())
            .bottomActionBar(maxWidth: 520) {
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Color.accentColor : Color(uiColor: .systemFill))
                            .frame(width: index == page ? 22 : 8, height: 8)
                    }
                }
                .animation(.snappy, value: page)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(page + 1) of \(pages.count)")
                .padding(.bottom, 6)
                Button {
                    if page < pages.count - 1 { page += 1 } else { onComplete() }
                } label: {
                    ActionLabel(page < pages.count - 1 ? "Continue" : (readOnly ? "Done" : "Get Started"))
                }
                .prominentAction()
                .accessibilityIdentifier("onboarding.next")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !readOnly {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                }
                if page > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Back") { page -= 1 }
                    }
                }
            }
        }
    }

    private func pageView(_ page: Page) -> some View {
        GeometryReader { proxy in
            // Short screens (iPhone SE, landscape) get a smaller hero so the
            // key points stay visible above the bottom bar without scrolling.
            let compact = proxy.size.height < 560
            ScrollView {
                pageContent(page, compact: compact)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func pageContent(_ page: Page, compact: Bool) -> some View {
        VStack(spacing: compact ? 16 : 24) {
            SymbolHero(systemImage: page.symbol, size: compact ? 36 : 56)
                .padding(.top, compact ? 4 : 16)
            VStack(spacing: 10) {
                Text(page.title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(page.points) { point in
                    Label {
                        Text(point.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: point.id).foregroundStyle(.tint).frame(width: 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .readableWidth(520)
    }
}
