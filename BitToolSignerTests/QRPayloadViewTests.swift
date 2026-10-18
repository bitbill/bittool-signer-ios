import Foundation
import Testing
@testable import BitToolSigner

/// Parsing of the engine's payload view (describeQR). Public example data only.
struct QRPayloadViewTests {
    @Test func jsonPayloadIsPrettySortedAndNamedAfterItsTransport() throws {
        let view = try #require(QRPayloadView(["type": "eth-signature", "frames": ["UR:ETH-SIGNATURE/X"], "payloadFormat": "json",
                                               "payload": ["signature": "ab", "request-id": ["uuid": "01"]], "payloadBytes": 89]))
        #expect(view.title == "Payload (JSON)")
        #expect(view.summary == "ur:eth-signature · CBOR · 89 bytes")
        #expect(view.text == "{\n  \"request-id\" : {\n    \"uuid\" : \"01\"\n  },\n  \"signature\" : \"ab\"\n}")
        #expect(!view.isPSBT)
    }

    @Test func plainTextAndPSBTTransportsAreLabelled() throws {
        let address = try #require(QRPayloadView(["type": "address", "frames": ["TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"],
                                                  "payloadFormat": "text", "payload": "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7", "payloadBytes": 34]))
        #expect(address.title == "Payload (Text)" && address.summary == "Plain text · 34 bytes")
        let bbqr = try #require(QRPayloadView(["type": "bbqr-psbt", "frames": ["B$HP0100abcd"], "payloadFormat": "json",
                                               "payload": ["psbt_base64": "cHNidP8="], "payloadBytes": 379]))
        #expect(bbqr.summary == "BBQr · PSBT (hex) · 379 bytes" && bbqr.isPSBT)
        let hex = try #require(QRPayloadView(["type": "bytes", "frames": ["UR:BYTES/X"], "payloadFormat": "hex", "payload": "0102", "payloadBytes": 3]))
        #expect(hex.title == "Payload (Hex)")
    }

    @Test func missingOrInvalidPayloadHidesTheDisclosure() {
        #expect(QRPayloadView(["frames": ["x"]]) == nil)
        #expect(QRPayloadView(["payloadFormat": "yaml", "payload": "x"]) == nil)
        #expect(QRPayloadView(["payloadFormat": "json", "payload": "not an object"]) == nil)
        #expect(QRPayloadView(["payloadFormat": "text", "payload": ""]) == nil)
    }
}
