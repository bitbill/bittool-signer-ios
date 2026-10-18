import Combine
import UIKit

/// Screenshot notification and warning state only. This component does not own
/// recovery material or control whether the underlying content is visible.
@MainActor
final class RecoveryScreenshotSession: ObservableObject {
    struct Warning: Identifiable, Equatable {
        let id = UUID()
    }

    @Published private(set) var warning: Warning?
    private let center: NotificationCenter
    private let isApplicationActive: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var mounted = false
    private var active = false
    private var onScreenshot: (@MainActor () -> Void)?

    init(center: NotificationCenter = .default,
         isApplicationActive: @escaping @MainActor () -> Bool = {
             UIApplication.shared.applicationState == .active
         }) {
        self.center = center
        self.isApplicationActive = isApplicationActive
    }

    func start(onScreenshot: @escaping @MainActor () -> Void = {}) {
        stop()
        mounted = true
        active = isApplicationActive()
        self.onScreenshot = onScreenshot
        observe(UIApplication.userDidTakeScreenshotNotification) { $0.receiveScreenshot() }
        observe(UIApplication.willResignActiveNotification) { $0.deactivate() }
        observe(UIApplication.didEnterBackgroundNotification) { $0.deactivate() }
        observe(UIApplication.didBecomeActiveNotification) { session in
            session.active = session.isApplicationActive()
        }
    }

    func stop() {
        mounted = false
        active = false
        observers.forEach(center.removeObserver)
        observers.removeAll()
        onScreenshot = nil
        dismissWarning()
    }

    func acknowledge(_ presented: Warning) {
        // A button from a replaced alert must not acknowledge a later screenshot.
        guard warning?.id == presented.id else { return }
        dismissWarning()
    }

    private func receiveScreenshot() {
        onScreenshot?()
        // The callback may itself unmount the view. Never show a late warning
        // after that, or re-present one while the app is inactive/backgrounded.
        guard mounted, active, isApplicationActive() else { return }
        warning = Warning()
    }

    private func deactivate() {
        active = false
        dismissWarning()
    }

    private func dismissWarning() {
        if warning != nil { warning = nil }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (RecoveryScreenshotSession) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mounted else { return }
                action(self)
            }
        })
    }

    deinit { observers.forEach(center.removeObserver) }
}
