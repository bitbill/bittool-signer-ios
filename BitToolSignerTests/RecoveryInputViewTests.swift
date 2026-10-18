import SwiftUI
import UIKit
import XCTest
@testable import BitToolSigner

@MainActor
final class RecoveryInputViewTests: XCTestCase {
    /// Inspects actual UIKit input traits with a fixed non-sensitive label.
    /// Does not focus the keyboard, use recovery material, or take screenshots.
    func testRecoveryInputUsesPlainTextWithoutPasswordAutofillTraits() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else {
            throw XCTSkip("Input-trait inspection requires an app-hosted UIWindowScene.")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = InputTraitsHostingController(rootView: RecoveryPhraseInput(text: .constant("Input traits fixture")))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.view.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        let appeared = try await waitUntil {
            host.fullyAppeared && self.textView(in: host.view)?.text == "Input traits fixture"
        }
        XCTAssertTrue(appeared)
        let editor = try XCTUnwrap(textView(in: host.view))
        XCTAssertTrue(editor.isEditable)
        XCTAssertFalse(editor.isSecureTextEntry)
        XCTAssertNotEqual(editor.textContentType, UITextContentType.password)
        XCTAssertNotEqual(editor.textContentType, UITextContentType.newPassword)
        XCTAssertTrue(editor.textContentType?.rawValue.isEmpty ?? true)
        // The system keyboard stays selectable so CJK phrases can be typed with
        // Apple's input methods; third-party keyboards are refused app-wide.
        XCTAssertEqual(editor.keyboardType, .default)
        XCTAssertEqual(editor.autocapitalizationType, .none)
        XCTAssertEqual(editor.autocorrectionType, .no)
        if #available(iOS 18.0, *) {
            XCTAssertEqual(editor.writingToolsBehavior, .none)
        }
    }

    private func textView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        return condition()
    }
}

@MainActor
private final class InputTraitsHostingController<Content: View>: UIHostingController<Content> {
    private(set) var fullyAppeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fullyAppeared = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        fullyAppeared = false
    }
}
