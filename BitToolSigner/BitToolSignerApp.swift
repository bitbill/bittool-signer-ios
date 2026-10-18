import SwiftUI

@main
struct BitToolSignerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore
    @StateObject private var access: AppAccessController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    private let defaults: UserDefaults

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if let test = SimulatorUITestContext.requested() {
            defaults = test.defaults
            _appearance = AppStorage(wrappedValue: "system", "appearance", store: test.defaults)
            _language = AppStorage(wrappedValue: AppLanguage.system.rawValue, "language", store: test.defaults)
            _store = StateObject(wrappedValue: test.store)
            _access = StateObject(wrappedValue: test.access)
            return
        }
        #endif
        defaults = .standard
        let vault = WalletVault()
        _store = StateObject(wrappedValue: AppStore(vault: vault))
        _access = StateObject(wrappedValue: AppAccessController(vault: vault))
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .defaultAppStorage(defaults)
                .appLanguage(AppLanguage.current(language))
                .environmentObject(store)
                .environmentObject(access)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onChange(of: appearance, initial: true) { _, value in
                    appDelegate.privacyShield.style = UIUserInterfaceStyle(appearance: value)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { store.suspend(); access.didEnterBackground() }
                    if phase == .active { access.willEnterForeground() }
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let privacyShield = PrivacyShield()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { privacyShield.start(); return true }
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool { extensionPointIdentifier != .keyboard }
}
