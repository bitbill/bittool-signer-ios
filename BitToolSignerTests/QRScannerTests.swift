import Foundation
import Testing
@testable import BitToolSigner

struct QRScannerTests {
    @Test func recognizedButUnreadableAndEmptyCodesHaveExplicitFailures() {
        var gate = QRScanFrameGate()
        let binary = gate.receive(nil, at: 0)
        let empty = gate.receive("", at: 0.1)
        let whitespace = gate.receive(" \n\t", at: 2)
        #expect(binary == .rejected(.nonText))
        #expect(empty == .rejected(.empty))
        #expect(whitespace == .rejected(.empty))
        #expect(!QRScanFrameGate.Issue.nonText.message.isEmpty)
        #expect(!QRScanFrameGate.Issue.empty.message.isEmpty)
        // Recovery-phrase scanning never talks about signing requests or request files.
        for issue in [QRScanFrameGate.Issue.nonText, .empty, .tooLarge] {
            let text = issue.message(for: .recoveryPhrase)
            #expect(!text.isEmpty && !text.contains("request"))
        }
    }

    @Test func sizeLimitCountsUTF8BytesAndAcceptsTheExactBoundary() {
        var gate = QRScanFrameGate()
        let limit = QRScanFrameGate.maximumBytes
        let ascii = String(repeating: "a", count: limit)
        let unicode = String(repeating: "é", count: limit / 2)
        let acceptedASCII = gate.receive(ascii, at: 0)
        let acceptedUnicode = gate.receive(unicode, at: 0.1)
        let tooLarge = gate.receive(unicode + "a", at: 0.2)
        #expect(acceptedASCII == .accepted(ascii))
        #expect(acceptedUnicode == .accepted(unicode))
        #expect(tooLarge == .rejected(.tooLarge))
        #expect(!QRScanFrameGate.Issue.tooLarge.message.isEmpty)
    }

    @Test func repeatedFramesThrottleWithoutExtendingTheRetryWindow() {
        var gate = QRScanFrameGate()
        // Synthetic transport text only; no real wallet requests are fixtures.
        let value = "UR:BYTES/1-2/TESTFRAME"
        let first = gate.receive(value, at: 10)
        let repeated = gate.receive(value, at: 10.4)
        let repeatedAgain = gate.receive(value, at: 10.9)
        let retry = gate.receive(value, at: 11)
        #expect(first == .accepted(value))
        #expect(repeated == .throttled)
        #expect(repeatedAgain == .throttled)
        #expect(retry == .accepted(value), "A QR held in place must be offered again after the throttle interval.")
    }

    @Test func distinctAnimatedFramesAreDeliveredImmediatelyAndUnchanged() {
        var gate = QRScanFrameGate()
        let first = "UR:BYTES/1-2/TESTFRAMEONE"
        let next = "UR:BYTES/2-2/TESTFRAMETWO"
        let firstResult = gate.receive(first, at: 10)
        let nextResult = gate.receive(next, at: 10.01)
        let wrapped = " \nUR:BYTES/TESTFRAME\n"
        let unchanged = gate.receive(wrapped, at: 10.02)
        #expect(firstResult == .accepted(first))
        #expect(nextResult == .accepted(next))
        #expect(unchanged == .accepted(wrapped), "The camera must not rewrite bytes before protocol validation.")
    }

    @Test func repeatedFailuresDoNotBlockAReadableFrame() {
        var gate = QRScanFrameGate()
        let failure = gate.receive(nil, at: 0)
        let duplicateFailure = gate.receive(nil, at: 0.1)
        let recovered = gate.receive("readable-request", at: 0.2)
        #expect(failure == .rejected(.nonText))
        #expect(duplicateFailure == .throttled)
        #expect(recovered == .accepted("readable-request"))
    }

    @Test func earlierClockValueCannotPermanentlySuppressAFrame() {
        var gate = QRScanFrameGate()
        let first = gate.receive("request", at: 50)
        let earlier = gate.receive("request", at: 1)
        #expect(first == .accepted("request"))
        #expect(earlier == .accepted("request"))
    }
}
