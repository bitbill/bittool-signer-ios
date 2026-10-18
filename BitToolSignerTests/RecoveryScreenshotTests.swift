import Testing
import UIKit
@testable import BitToolSigner

/// Notification/lifecycle tests contain no phrase, image or screenshot data.
@MainActor
struct RecoveryScreenshotTests {
    @Test func repeatedScreenshotsInvokeCallbackAndRequireCurrentAcknowledgement() throws {
        let center = NotificationCenter()
        let environment = ScreenshotTestEnvironment()
        let session = RecoveryScreenshotSession(center: center, isApplicationActive: { environment.active })
        session.start { environment.callbacks += 1 }
        #expect(session.warning == nil)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        let first = try #require(session.warning)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        let second = try #require(session.warning)
        #expect(first.id != second.id)
        #expect(environment.callbacks == 2)
        session.acknowledge(first)
        #expect(session.warning == second)
        session.acknowledge(second)
        #expect(session.warning == nil)
        session.stop()
    }

    @Test(arguments: [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification])
    func lifecycleDismissesWarningAndDefersFurtherAlertsUntilActive(notification: Notification.Name) {
        let center = NotificationCenter()
        let environment = ScreenshotTestEnvironment()
        let session = RecoveryScreenshotSession(center: center, isApplicationActive: { environment.active })
        session.start { environment.callbacks += 1 }
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.warning != nil)
        center.post(name: notification, object: nil)
        #expect(session.warning == nil)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.warning == nil)
        #expect(environment.callbacks == 2)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.warning != nil)
        session.stop()
    }

    @Test func currentApplicationStateAlsoPreventsBackgroundPresentation() {
        let center = NotificationCenter()
        let environment = ScreenshotTestEnvironment()
        environment.active = false
        let session = RecoveryScreenshotSession(center: center, isApplicationActive: { environment.active })
        session.start { environment.callbacks += 1 }
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.warning == nil)
        environment.active = true
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        environment.active = false
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.warning == nil)
        #expect(environment.callbacks == 2)
        session.stop()
    }

    @Test func stoppingAndRemountingDoesNotRetainWarningsCallbacksOrObservers() {
        let center = NotificationCenter()
        let environment = ScreenshotTestEnvironment()
        let session = RecoveryScreenshotSession(center: center, isApplicationActive: { environment.active })
        session.start { environment.callbacks += 1 }
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(environment.callbacks == 1)
        session.stop()
        #expect(session.warning == nil)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(environment.callbacks == 1)
        #expect(session.warning == nil)
        session.start { environment.callbacks += 10 }
        session.start { environment.callbacks += 100 }
        #expect(session.warning == nil)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(environment.callbacks == 101)
        #expect(session.warning != nil)
        session.stop()
    }

    @Test func unmountingInsideScreenshotCallbackDoesNotPublishLateWarning() {
        let center = NotificationCenter()
        let session = RecoveryScreenshotSession(center: center, isApplicationActive: { true })
        session.start { [weak session] in session?.stop() }
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.warning == nil)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.warning == nil)
    }
}

@MainActor
private final class ScreenshotTestEnvironment {
    var active = true
    var callbacks = 0
}
