import Foundation
import JavaScriptCore

struct SigningEngineError: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// One JavaScriptCore VM with the bundled engine and native entropy installed.
/// Only the code-signed local bundle is evaluated; there is no web view,
/// network, file system or wallet storage interface in the context.
private final class EngineContext {
    private let context: JSContext
    private let dispatch: JSValue
    private var failed = false

    init(source: String, url: URL) throws {
        guard let machine = JSVirtualMachine(), let context = JSContext(virtualMachine: machine) else {
            throw SigningEngineError(code: "ENGINE_UNAVAILABLE", message: "The offline signing engine could not be started.")
        }
        self.context = context
        var evaluationFailed = false
        context.exceptionHandler = { _, _ in evaluationFailed = true }
        let entropy: @convention(block) (Int) -> [NSNumber]? = { count in
            guard let bytes = try? SecureRandom.bytes(count: count) else { return nil }
            return bytes.map { NSNumber(value: $0) }
        }
        context.setObject(entropy, forKeyedSubscript: "__bitSignerRandom" as NSString)
        // Capture and remove the native entry point before evaluating the bundle.
        // WebCrypto accepts only integer typed arrays and at most 65536 bytes.
        context.evaluateScript("""
        (function (random) {
            'use strict';
            delete globalThis.__bitSignerRandom;
            Object.defineProperty(globalThis, 'crypto', {value: Object.freeze({
                getRandomValues: function (array) {
                    var integer = array instanceof Int8Array || array instanceof Uint8Array ||
                        array instanceof Uint8ClampedArray || array instanceof Int16Array ||
                        array instanceof Uint16Array || array instanceof Int32Array ||
                        array instanceof Uint32Array ||
                        (typeof BigInt64Array !== 'undefined' && array instanceof BigInt64Array) ||
                        (typeof BigUint64Array !== 'undefined' && array instanceof BigUint64Array);
                    if (!integer || array.byteLength > 65536) throw new Error('Invalid entropy request');
                    if (array.byteLength === 0) return array;
                    var bytes = random(array.byteLength);
                    if (!bytes || bytes.length !== array.byteLength) throw new Error('Secure randomness unavailable');
                    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
                    return array;
                }
            }), writable: false, configurable: false});
            // Some bundled libraries use Math.random for internal identifiers
            // during module initialization. Back it with native entropy too.
            Object.defineProperty(Math, 'random', {value: function () {
                var bytes = new Uint32Array(2);
                crypto.getRandomValues(bytes);
                return ((bytes[0] >>> 5) * 67108864 + (bytes[1] >>> 6)) / 9007199254740992;
            }, writable: false, configurable: false});
        })(__bitSignerRandom);
        """)
        guard !evaluationFailed else {
            throw SigningEngineError(code: "ENTROPY_UNAVAILABLE", message: "The engine’s secure entropy source could not be installed.")
        }
        context.evaluateScript(source, withSourceURL: url)
        guard !evaluationFailed, let engine = context.objectForKeyedSubscript("BitToolSignerEngine"),
              !engine.isUndefined, let dispatch = engine.forProperty("dispatch"), !dispatch.isUndefined else {
            throw SigningEngineError(code: "ENGINE_INVALID", message: "The bundled signing engine could not be loaded.")
        }
        self.dispatch = dispatch
        context.exceptionHandler = { [weak self] _, _ in self?.failed = true }
    }

    /// JSON is passed as an argument; request text is never interpolated into script.
    func call(_ requestJSON: String) throws -> [String: Any] {
        failed = false
        defer { context.exception = nil }
        guard let response = dispatch.call(withArguments: [requestJSON]), !failed,
              let responseJSON = response.toString(), responseJSON.utf8.count <= 2_097_152,
              let responseData = responseJSON.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let ok = envelope["ok"] as? Bool else {
            throw SigningEngineError(code: "ENGINE_FAILURE", message: "The offline engine could not process this request.")
        }
        guard ok else {
            let error = envelope["error"] as? [String: Any]
            // Only engine-authored, bounded messages are presented by the UI.
            let code = String((error?["code"] as? String ?? "SIGNING_FAILED").prefix(80))
            let message = String((error?["message"] as? String ?? "This request could not be signed.").prefix(400))
            throw SigningEngineError(code: code, message: message)
        }
        if let result = envelope["result"] as? [String: Any] { return result }
        if let result = envelope["result"] { return ["value": result] }
        return [:]
    }
}

/// Engines that can assemble animated QR codes incrementally.
protocol IncrementalQREngine: Sendable {
    func beginScanSession() async throws
    func scan(frame: String) async throws -> [String: Any]
    func endScanSession() async
}

/// Operations involving secrets or untrusted input get a fresh VM each time, so
/// no state survives into another request. Public derivations over the device's
/// own validated public index reuse one warm VM that never receives secrets or
/// external data. A QR scan session has its own VM, discarded when it ends.
actor SigningEngine: IncrementalQREngine {
    private let bundle: Bundle
    #if DEBUG
    private let sourceURL: URL?
    #endif
    private let maximumRequestBytes = 1_048_576
    private var cachedSource: (String, URL)?
    private var publicContext: EngineContext?
    private var scanContext: EngineContext?

    private static let productionOperations: Set<String> = [
        "mnemonic", "capabilities",
        "derivePublicIndex", "derivePublicAddresses", "createPublicPairing", "createWalletPairing",
        "decodeQR", "decodePayload", "review", "resolveSigningPlan", "signPlanTask", "encodeResponse",
    ]
    /// Trusted local public inputs only.
    private static let warmOperations: Set<String> = ["derivePublicAddresses", "createPublicPairing", "createWalletPairing"]
    #if DEBUG
    /// Internal utilities used by tests; absent from Release builds.
    private static let testOperations: Set<String> = ["deriveAccounts", "deriveBitcoinCosigner", "encodeQR", "sign", "createPairing",
                                                     "validateMnemonic", "wordlist"]
    #endif

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        #if DEBUG
        self.sourceURL = nil
        #endif
    }

    #if DEBUG
    /// Test fixture injection is absent from production builds.
    init(bundle: Bundle = .main, sourceURL: URL) {
        self.bundle = bundle
        self.sourceURL = sourceURL
    }
    #endif

    func run(operation: String, parameters: [String: Any] = [:]) async throws -> [String: Any] {
        var allowed = Self.productionOperations.contains(operation)
        #if DEBUG
        allowed = allowed || Self.testOperations.contains(operation)
        #endif
        guard allowed else {
            throw SigningEngineError(code: "UNSUPPORTED_OPERATION", message: "This signing operation is not supported.")
        }
        let json = try requestJSON(operation, parameters)
        return try autoreleasepool {
            if Self.warmOperations.contains(operation) {
                let context = try publicContext ?? makeContext()
                publicContext = context
                return try context.call(json)
            }
            return try makeContext().call(json)
        }
    }

    func beginScanSession() async throws {
        scanContext = nil
        let context = try makeContext()
        _ = try context.call(requestJSON("scanBegin", [:]))
        scanContext = context
    }

    func scan(frame: String) async throws -> [String: Any] {
        guard let scanContext else { throw SigningEngineError(code: "SCAN", message: "The scan session ended. Scan again.") }
        let json = try requestJSON("scanAdd", ["frame": frame])
        return try autoreleasepool { try scanContext.call(json) }
    }

    func endScanSession() async { scanContext = nil }

    /// Drops the warm public context when the app is suspended (background, App
    /// Lock or screen capture); Connect's prefetch warms it again when allowed.
    func releaseWarmContext() { publicContext = nil }

    private func requestJSON(_ operation: String, _ parameters: [String: Any]) throws -> String {
        var request = parameters
        request["operation"] = operation
        guard JSONSerialization.isValidJSONObject(request) else {
            throw SigningEngineError(code: "INVALID_REQUEST", message: "The signing request has an invalid format.")
        }
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard data.count <= maximumRequestBytes, let json = String(data: data, encoding: .utf8) else {
            throw SigningEngineError(code: "REQUEST_TOO_LARGE", message: "This request exceeds the 1 MB offline signing limit.")
        }
        return json
    }

    private func makeContext() throws -> EngineContext {
        let (source, url) = try loadSource()
        return try EngineContext(source: source, url: url)
    }

    private func loadSource() throws -> (String, URL) {
        if let cachedSource { return cachedSource }
        var url = bundle.url(forResource: "signer", withExtension: "js")
            ?? bundle.url(forResource: "signer", withExtension: "js", subdirectory: "Resources")
        #if DEBUG
        url = sourceURL ?? url
        #endif
        guard let url, url.isFileURL, let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw SigningEngineError(code: "ENGINE_MISSING", message: "The bundled signing engine is unavailable. Reinstall BitTool Signer.")
        }
        cachedSource = (source, url)
        return (source, url)
    }
}
