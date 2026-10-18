import Combine
import Foundation
import Testing
import UIKit
@testable import BitToolSigner

/// These tests exercise display permission only. No mnemonic, passphrase, image,
/// wallet file, or real screenshot is created or recorded by this suite.
@MainActor
struct RecoveryPrivacyTests {
    @Test func startsHiddenAndATapRevealsWithoutConfirmation() {
        let session = RecoveryPrivacySession(center: NotificationCenter(), canReveal: { true })
        #expect(!session.isRevealed)
        #expect(session.prompt == nil)
        session.start()
        defer { session.stop() }
        #expect(session.reveal())
        #expect(session.isRevealed)
        #expect(session.prompt == nil, "Revealing never raises a confirmation prompt.")
        session.hide()
        #expect(!session.isRevealed)
        #expect(session.reveal())
    }

    @Test func screenshotImmediatelyConcealsAndRequiresWarningAcknowledgement() {
        let center = NotificationCenter()
        let session = RecoveryPrivacySession(center: center, canReveal: { true })
        session.start()
        defer { session.stop() }
        #expect(session.reveal())
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(!session.isRevealed)
        #expect(session.prompt == .screenshot)

        #expect(!session.reveal())
        #expect(!session.isRevealed)
        session.hide() // Hiding alone does not acknowledge the warning.
        #expect(!session.reveal())
        session.acknowledgeWarning()
        #expect(session.prompt == nil)
        #expect(!session.isRevealed, "Acknowledging never reveals by itself.")
        #expect(session.reveal())
    }

    @Test func screenshotWhileHiddenStillWarnsWithoutExposingContent() {
        let center = NotificationCenter()
        let session = RecoveryPrivacySession(center: center, canReveal: { true })
        session.start()
        defer { session.stop() }
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(!session.isRevealed)
        #expect(session.prompt == .screenshot)
        #expect(!session.reveal())
    }

    @Test(arguments: [
        UIApplication.willResignActiveNotification,
        UIApplication.didEnterBackgroundNotification,
        UIScreen.capturedDidChangeNotification
    ])
    func lifecycleAndCaptureEventsConceal(_ notification: Notification.Name) {
        let center = NotificationCenter()
        let session = RecoveryPrivacySession(center: center, canReveal: { true })
        session.start()
        defer { session.stop() }
        #expect(session.reveal())
        center.post(name: notification, object: nil)
        #expect(!session.isRevealed)
        #expect(session.prompt == nil)
        #expect(session.reveal(), "Returning to a safe screen needs only a new tap.")
    }

    @Test func unsafeEnvironmentRefusesToReveal() {
        let environment = RecoveryTestEnvironment()
        let session = RecoveryPrivacySession(center: NotificationCenter(), canReveal: { environment.allowsReveal })
        session.start()
        defer { session.stop() }
        #expect(!session.reveal()) // Inactive app or a captured (recorded/mirrored) screen.
        #expect(!session.isRevealed)
        environment.allowsReveal = true
        #expect(session.reveal())
    }

    @Test func aSessionPausedUnderASheetLeavesTheScreenshotWarningToTheSheet() {
        let center = NotificationCenter()
        let covered = RecoveryPrivacySession(center: center, canReveal: { true })
        let sheet = RecoveryPrivacySession(center: center, canReveal: { true })
        covered.start()
        #expect(covered.reveal())
        covered.stop() // A sheet covers the panel.
        #expect(!covered.isRevealed, "Pausing conceals the covered content.")
        sheet.start()
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(sheet.prompt == .screenshot)
        #expect(covered.prompt == nil, "Only the visible sheet raises the warning.")
        sheet.acknowledgeWarning(); sheet.stop()
        covered.start() // The sheet closed.
        #expect(covered.reveal(), "One acknowledgement is enough to reveal again.")
        covered.stop()
    }

    @Test func unmountedSessionsCannotReveal() {
        let center = NotificationCenter()
        let session = RecoveryPrivacySession(center: center, canReveal: { true })
        #expect(!session.reveal())
        #expect(!session.isRevealed)
        session.start()
        #expect(session.reveal())
        session.stop()
        #expect(!session.isRevealed)
        #expect(!session.reveal())
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(session.prompt == nil)
    }

    @Test func remountResetsVisibilityAndDoesNotAccumulateObservers() {
        let center = NotificationCenter()
        let session = RecoveryPrivacySession(center: center, canReveal: { true })
        var screenshotPrompts = 0
        let observation = session.$prompt.sink { prompt in
            if prompt == .screenshot { screenshotPrompts += 1 }
        }
        defer { observation.cancel(); session.stop() }

        session.start()
        #expect(session.reveal())
        session.start() // Reappearance must reset a previous reveal.
        #expect(!session.isRevealed)
        #expect(session.prompt == nil)
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(screenshotPrompts == 1)

        session.stop()
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        #expect(screenshotPrompts == 1)
        session.start()
        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        // Old observers would also fire after remount if stop merely set a flag.
        #expect(screenshotPrompts == 2)
    }
}

@MainActor
private final class RecoveryTestEnvironment {
    var allowsReveal = false
}
