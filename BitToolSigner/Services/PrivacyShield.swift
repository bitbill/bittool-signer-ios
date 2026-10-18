import SwiftUI
import UIKit

extension UIUserInterfaceStyle {
    /// The Settings › Appearance value ("system", "light" or "dark").
    init(appearance: String?) {
        switch appearance {
        case "light": self = .light
        case "dark": self = .dark
        default: self = .unspecified
        }
    }
}

/// A separate native window covers presented sheets as well as the root view.
/// This protects app-switcher snapshots/recording, not an already-taken screenshot.
@MainActor
final class PrivacyShield {
    private(set) var windows: [UIWindow] = []
    private let center: NotificationCenter
    private let isCaptured: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var inactive = false
    /// The main window gets the in-app appearance from preferredColorScheme; this
    /// window does not, so it is set here (BitToolSignerApp keeps it current).
    var style = UIUserInterfaceStyle(appearance: UserDefaults.standard.string(forKey: "appearance")) {
        didSet { windows.forEach { $0.overrideUserInterfaceStyle = style } }
    }
    init(center: NotificationCenter = .default, isCaptured: @escaping @MainActor () -> Bool = { UIScreen.main.isCaptured }) {
        self.center = center
        self.isCaptured = isCaptured
    }
    func start() {
        stop()
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.inactive = true; self?.update() } })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.inactive = false; self?.update() } })
        observers.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } })
    }
    func stop() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
        inactive = false
        windows.forEach { $0.isHidden = true }
        windows = []
    }
    private func update() {
        let captured = isCaptured()
        guard inactive || captured else { windows.forEach { $0.isHidden = true }; windows = []; return }
        if windows.isEmpty {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 2
                window.overrideUserInterfaceStyle = style
                window.rootViewController = UIHostingController(rootView: PrivacyShieldView(captured: captured))
                window.isHidden = false
                windows.append(window)
            }
        } else {
            for window in windows { (window.rootViewController as? UIHostingController<PrivacyShieldView>)?.rootView = PrivacyShieldView(captured: captured) }
        }
    }
}

/// Shared by the native privacy window and SwiftUI's scene cover. Identical to
/// the launch screen so app-switcher snapshots never show wallet content. While
/// the screen is recorded or mirrored it says why, so it is not taken for a
/// launch that never finished.
struct PrivacyShieldView: View {
    var captured = false

    var body: some View {
        LaunchView()
            .overlay(alignment: .bottom) {
                if captured {
                    Label("Hidden while your screen is recorded or mirrored", systemImage: "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.bottom, 24)
                }
            }
    }
}
