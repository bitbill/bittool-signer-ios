import XCTest
final class BitToolSignerUITestsLaunchTests: XCTestCase {
    @MainActor
    func testLaunchScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["--bittool-signer-ui-tests", "--reset-ui-fixtures"]
        app.launchEnvironment["BITTOOL_SIGNER_UI_TEST_RUN"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.staticTexts["BitTool Signer"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "BitTool Signer launch"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
