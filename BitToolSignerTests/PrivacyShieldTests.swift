import Foundation
import Testing
import UIKit
@testable import BitToolSigner

/// The privacy window is separate from the SwiftUI window, so it must take the
/// in-app appearance itself; otherwise the app-switcher card can show the other
/// appearance than the app.
@MainActor
struct PrivacyShieldTests {
    @Test func appearanceSettingMapsToAnInterfaceStyle() {
        #expect(UIUserInterfaceStyle(appearance: "light") == .light)
        #expect(UIUserInterfaceStyle(appearance: "dark") == .dark)
        #expect(UIUserInterfaceStyle(appearance: "system") == .unspecified)
        #expect(UIUserInterfaceStyle(appearance: nil) == .unspecified)
    }

    @Test func shieldWindowFollowsTheInAppAppearanceAndLeavesWhenActive() throws {
        try #require(!UIApplication.shared.connectedScenes.isEmpty, "The hosted test app has a window scene.")
        let center = NotificationCenter()
        let shield = PrivacyShield(center: center, isCaptured: { false })
        shield.style = .light
        shield.start()
        defer { shield.stop() }
        #expect(shield.windows.isEmpty)

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(!shield.windows.isEmpty)
        #expect(shield.windows.allSatisfy { !$0.isHidden && $0.windowLevel == .alert + 2 && $0.overrideUserInterfaceStyle == .light })

        // Changing Settings › Appearance while covered updates the visible cover.
        shield.style = .dark
        #expect(shield.windows.allSatisfy { $0.overrideUserInterfaceStyle == .dark })
        shield.style = .unspecified
        #expect(shield.windows.allSatisfy { $0.overrideUserInterfaceStyle == .unspecified })

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(shield.windows.isEmpty)
    }
}
