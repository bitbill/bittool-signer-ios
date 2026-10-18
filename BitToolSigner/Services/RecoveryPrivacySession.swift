import Combine
import UIKit

/// Display permission only: this object never owns a mnemonic or passphrase.
///
/// Tapping "Tap to Reveal" is the consent: the content shows at once, without
/// a second confirmation. It is concealed again on any screenshot, when the app
/// resigns active or enters the background, and while the screen is captured;
/// a screenshot also raises a warning that must be acknowledged before the
/// content can be shown again.
@MainActor
final class RecoveryPrivacySession: ObservableObject {
    enum Prompt: String, Identifiable {
        case screenshot
        var id: String { rawValue }
    }

    @Published private(set) var isRevealed = false
    @Published var prompt: Prompt?
    private let center: NotificationCenter
    private let canReveal: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var mounted = false

    init(center: NotificationCenter = .default,
         canReveal: @escaping @MainActor () -> Bool = {
             UIApplication.shared.applicationState == .active && !UIScreen.main.isCaptured
         }) {
        self.center = center
        self.canReveal = canReveal
    }

    func start() {
        stop()
        mounted = true
        observe(UIApplication.userDidTakeScreenshotNotification) { session in
            session.hide()
            session.prompt = .screenshot
        }
        observe(UIApplication.willResignActiveNotification) { $0.hide() }
        observe(UIApplication.didEnterBackgroundNotification) { $0.hide() }
        observe(UIScreen.capturedDidChangeNotification) { $0.hide() }
    }

    func stop() {
        mounted = false
        observers.forEach(center.removeObserver)
        observers.removeAll()
        hide()
        if prompt != nil { prompt = nil }
    }

    /// Shows the content if the screen is safe to show it on: the view is
    /// mounted, the app is active, the screen is not being captured, and no
    /// screenshot warning is waiting to be acknowledged.
    @discardableResult
    func reveal() -> Bool {
        guard mounted, canReveal(), prompt == nil else { return false }
        isRevealed = true
        return true
    }

    func hide() {
        if isRevealed { isRevealed = false }
    }

    /// The screenshot warning's OK button.
    func acknowledgeWarning() {
        hide()
        if prompt != nil { prompt = nil }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (RecoveryPrivacySession) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mounted else { return }
                action(self)
            }
        })
    }

    deinit { observers.forEach(center.removeObserver) }
}
