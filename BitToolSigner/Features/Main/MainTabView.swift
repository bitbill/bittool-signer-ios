import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView(selection: $router.tab) {
            WalletsTab()
                .tabItem { Label("Wallets", systemImage: Self.walletsSymbol) }
                .tag(AppRouter.Tab.wallets)
            ScanTab()
                .tabItem { Label("Scan", systemImage: "qrcode.viewfinder") }
                .tag(AppRouter.Tab.scan)
                .badge(store.review != nil && !store.hasSignedResponse ? 1 : 0)
            ActivityTab()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(AppRouter.Tab.activity)
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppRouter.Tab.settings)
        }
        // The tab bar stays expanded: a signing app should keep Activity and
        // Settings one tap away after scrolling a long review.
    }

    /// `wallet.bifold` is new in iOS 18.
    private static var walletsSymbol: String {
        if #available(iOS 18.0, *) { "wallet.bifold" } else { "wallet.pass" }
    }
}
