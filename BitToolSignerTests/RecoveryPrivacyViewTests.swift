import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import BitToolSigner

/// App-hosted presentation checks. Content is a fixed, non-sensitive label;
/// screenshot notifications use an isolated center and never capture an image.
@MainActor
final class RecoveryPrivacyViewTests: XCTestCase {
    func testScreenshotNotificationPresentsWarningThroughSwiftUI() async throws {
        let center = NotificationCenter()
        let session = RecoveryPrivacySession(center: center, canReveal: { true })
        let fixture = try makeFixture(session: session)
        addTeardownBlock { await fixture.close() }
        let fixtureAppeared = try await waitUntil { fixture.appeared }
        XCTAssertTrue(fixtureAppeared)

        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        let warningTitle = RecoveryCopy.screenshotTitle
        let warningAppeared = try await waitUntil {
            self.presentedAlert(from: fixture.host)?.title == warningTitle
        }
        XCTAssertTrue(warningAppeared, "Screenshot notification must present the user-facing warning, not just change internal state.")
        let alert = try XCTUnwrap(presentedAlert(from: fixture.host))
        XCTAssertEqual(alert.title, warningTitle)
        XCTAssertFalse(session.isRevealed)
        XCTAssertEqual(session.prompt, .screenshot)
    }

    func testTapRevealsWithoutAConfirmationAndAScreenshotConcealsBehindTheWarning() async throws {
        let center = NotificationCenter()
        let session = RecoveryPrivacySession(center: center, canReveal: { true })
        let fixture = try makeFixture(session: session)
        addTeardownBlock { await fixture.close() }
        let fixtureAppeared = try await waitUntil { fixture.appeared }
        XCTAssertTrue(fixtureAppeared)

        XCTAssertTrue(session.reveal(), "Tapping the concealed content shows it directly.")
        XCTAssertTrue(session.isRevealed)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(presentedAlert(from: fixture.host), "No confirmation alert is shown before revealing.")

        center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        let warningTitle = RecoveryCopy.screenshotTitle
        let warningAppeared = try await waitUntil {
            self.presentedAlert(from: fixture.host)?.title == warningTitle
        }
        XCTAssertTrue(warningAppeared, "A screenshot conceals the content and presents the warning.")
        XCTAssertFalse(session.isRevealed)
        XCTAssertEqual(session.prompt, .screenshot, "Presentation callbacks must not clear the screenshot warning gate.")
        XCTAssertFalse(session.reveal(), "Nothing can be shown again until the warning is acknowledged.")
        XCTAssertFalse(session.isRevealed)
    }

    private func makeFixture(session: RecoveryPrivacySession) throws -> HostedFixture {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else {
            throw XCTSkip("SwiftUI alert presentation requires an app-hosted foreground UIWindowScene.")
        }
        return HostedFixture(scene: scene, session: session)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        return condition()
    }

    private func presentedAlert(from controller: UIViewController) -> UIAlertController? {
        if let presented = controller.presentedViewController,
           let alert = presentedAlert(from: presented) { return alert }
        for child in controller.children {
            if let alert = presentedAlert(from: child) { return alert }
        }
        guard let alert = controller as? UIAlertController,
              !alert.isBeingPresented, !alert.isBeingDismissed,
              alert.transitionCoordinator == nil,
              alert.viewIfLoaded?.window != nil else { return nil }
        return alert
    }
}

@MainActor
private final class HostedFixture {
    let window: UIWindow
    let host: UIViewController
    private let previousKeyWindow: UIWindow?
    private let session: RecoveryPrivacySession
    private let probe: MountProbe
    var appeared: Bool { probe.contentMounted && probe.fullyAppeared }

    init(scene: UIWindowScene, session: RecoveryPrivacySession) {
        self.session = session
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let probe = MountProbe()
        self.probe = probe
        let content = Text("Recovery privacy presentation fixture")
            .recoveryPrivacy(session)
            .onAppear { probe.contentMounted = true }
        host = AppearanceTrackingHost(rootView: content, probe: probe)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func close() async {
        // Removing a hosting window mid-alert animation corrupts UIKit's appearance
        // lifecycle. Await actual transitions, clear the presentation binding,
        // and wait for UIKit's dismissal completion before detaching the host.
        let settled = await waitForTransition {
            self.host.transitionCoordinator == nil &&
                self.host.presentedViewController?.transitionCoordinator == nil &&
                self.host.presentedViewController?.isBeingPresented != true &&
                self.host.presentedViewController?.isBeingDismissed != true
        }
        XCTAssertTrue(settled, "The fixture must finish presenting before teardown.")
        session.hide()
        let presentation = host.presentedViewController
        let dismissal = DismissalProbe(completed: presentation == nil)
        if presentation != nil {
            // A legacy SwiftUI Alert can keep its presentation controller after
            // an external item-binding reset. Explicit dismissal is fixture
            // cleanup only; both tests already checked the real visible alert.
            host.dismiss(animated: false) { dismissal.completed = true }
        }
        let dismissed = await waitForTransition {
            dismissal.completed &&
                presentation?.viewIfLoaded?.window == nil &&
                self.host.transitionCoordinator == nil
        }
        XCTAssertTrue(dismissed, "UIKit must finish dismissing the visible alert before the fixture window is removed.")
        session.stop()
        // Continue outside the binding update's current UIKit/SwiftUI transaction.
        await Task.yield()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }

    private func waitForTransition(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if condition() { return true }
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { return condition() }
        } while Date() < deadline
        return condition()
    }
}

@MainActor
private final class MountProbe {
    var contentMounted = false
    var fullyAppeared = false
}

@MainActor
private final class DismissalProbe {
    var completed: Bool
    init(completed: Bool) { self.completed = completed }
}

@MainActor
private final class AppearanceTrackingHost<Content: View>: UIHostingController<Content> {
    private let probe: MountProbe

    init(rootView: Content, probe: MountProbe) {
        self.probe = probe
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewWillAppear(_ animated: Bool) {
        probe.fullyAppeared = false
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        probe.fullyAppeared = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        probe.fullyAppeared = false
    }
}
