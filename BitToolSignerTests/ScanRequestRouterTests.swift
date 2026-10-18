import Foundation
import Testing
@testable import BitToolSigner

/// The Wallets toolbar asks the Scan tab to open the camera. Exactly one open
/// per ask: the Scan tab's content view is destroyed when a request arrives and
/// built again when the signature is done, so the "already opened" mark cannot
/// live in its view state.
@MainActor
struct ScanRequestRouterTests {
    @Test func askingOpensTheCameraOnceAndOnlyOnce() {
        let router = AppRouter()
        #expect(router.consumeScanRequest() == false, "Nothing has been asked for yet.")

        router.startScanning()
        #expect(router.tab == .scan)
        #expect(router.consumeScanRequest() == true, "The camera opens.")
        #expect(router.consumeScanRequest() == false, "It does not open a second time.")
    }

    @Test func theCameraDoesNotReopenAfterASignatureIsFinished() {
        let router = AppRouter()
        router.startScanning()
        #expect(router.consumeScanRequest() == true)

        // Signing rebuilds the Scan tab's content view from scratch, so every
        // one of these is a fresh `onAppear` asking whether to open the camera.
        for step in ["request arrives", "review", "signature result", "Done"] {
            #expect(router.consumeScanRequest() == false, "Reopened the camera after: \(step)")
        }
    }

    @Test func askingAgainOpensTheCameraAgain() {
        let router = AppRouter()
        router.startScanning()
        #expect(router.consumeScanRequest() == true)
        #expect(router.consumeScanRequest() == false)

        router.startScanning()
        #expect(router.consumeScanRequest() == true, "A second tap on the toolbar opens it again.")
        #expect(router.consumeScanRequest() == false)
    }

    @Test func movingToTheScanTabByHandNeverOpensTheCamera() {
        let router = AppRouter()
        router.tab = .scan
        #expect(router.consumeScanRequest() == false, "Only the toolbar button opens the camera.")
    }
}
