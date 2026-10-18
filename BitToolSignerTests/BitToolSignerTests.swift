import Foundation
import Testing
@testable import BitToolSigner

struct EngineIntegrationTests {
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let signer = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"

    @Test func bundledEngineDerivesKnownFourChainAccountsAndPublicPairing() async throws {
        let engine = SigningEngine()
        let generated = try await engine.run(operation: "mnemonic", parameters: ["entropy": String(repeating: "00", count: 16)])
        #expect(generated["mnemonic"] as? String == phrase)
        let derived = try await engine.run(operation: "deriveAccounts", parameters: ["mnemonic": phrase])
        let accounts = try #require(derived["accounts"] as? [[String: Any]])
        #expect(accounts.count == 4)
        #expect(accounts.first { $0["chain"] as? String == "bitcoin" }?["address"] as? String == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        #expect(accounts.first { $0["chain"] as? String == "evm" }?["address"] as? String == signer)
        #expect(accounts.first { $0["chain"] as? String == "tron" }?["address"] as? String == "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH")
        #expect(accounts.first { $0["chain"] as? String == "solana" }?["address"] as? String == "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        let index = try await engine.run(operation: "derivePublicIndex", parameters: ["mnemonic": phrase])
        _ = try WalletPublicMetadata(index)
        let pairing = try await engine.run(operation: "createPublicPairing", parameters: ["publicIndex": index, "chain": "evm", "profile": "standard", "outputMode": "wallet"])
        #expect((pairing["frames"] as? [String])?.first?.lowercased().hasPrefix("ur:crypto-hdkey/") == true)
    }

    @Test func fixedEVMPlanSignsAndExportsWithoutNetwork() async throws {
        let engine = SigningEngine()
        let request = transactionRequest()
        let review = try await engine.run(operation: "review", parameters: ["request": request])
        #expect(review["canSign"] as? Bool == true)
        let hash = try #require(review["requestHash"] as? String)
        let (plan, taskID) = try await resolve(request, engine: engine)
        let signed = try await engine.run(operation: "signPlanTask", parameters: ["request": request, "plan": plan, "taskId": taskID, "mnemonic": phrase])
        #expect(signed["requestHash"] as? String == hash)
        #expect(signed["address"] as? String == signer)
        #expect((signed["serializedTransaction"] as? String)?.hasPrefix("0x02") == true)
        #expect((signed["signature"] as? String)?.count == 130)
        // This fixture is an internal request with no scanned public transport.
        // It must not regain the removed private-JSON response fallback.
        await #expect(throws: SigningEngineError.self) {
            try await engine.run(operation: "encodeResponse", parameters: ["request": request, "result": signed])
        }
        try await checkPublicFixtureExport(chain: "evm", result: signed, engine: engine)
        let altered = transactionRequest(nonce: 1)
        await #expect(throws: SigningEngineError.self) {
            try await engine.run(operation: "signPlanTask", parameters: ["request": altered, "plan": plan, "taskId": taskID, "mnemonic": phrase])
        }
    }

    @Test func malformedQRIsRejectedAndOpaqueContractRequiresPerRequestRiskConsent() async throws {
        let engine = SigningEngine()
        await #expect(throws: SigningEngineError.self) { try await engine.run(operation: "decodeQR", parameters: ["frames": ["ur:eth-sign-request/invalid"]]) }
        let request = transactionRequest(data: "0xdeadbeef")
        let review = try await engine.run(operation: "review", parameters: ["request": request])
        #expect(review["canSign"] as? Bool == true)
        #expect(["partiallyDecoded", "opaque"].contains(review["decodeStatus"] as? String ?? ""))
        #expect(!(review["warnings"] as? [String] ?? []).isEmpty)
        let (plan, taskID) = try await resolve(request, engine: engine)
        await #expect(throws: SigningEngineError.self) {
            try await engine.run(operation: "signPlanTask", parameters: ["request": request, "plan": plan, "taskId": taskID, "mnemonic": phrase])
        }
        let accepted = try await engine.run(operation: "signPlanTask", parameters: ["request": request, "plan": plan, "taskId": taskID, "mnemonic": phrase, "riskAcknowledged": true])
        #expect(accepted["requestHash"] as? String == review["requestHash"] as? String)
        #expect((accepted["signature"] as? String)?.count == 130)
    }

    @Test func nativeRuntimeResolvesSolanaTronAndTwoWalletBitcoinPlans() async throws {
        // This resource is copied from engine/test/fixtures/public-plan-vectors.json.
        // Both recovery phrases are published BIP39 fixtures, never user wallets.
        let fixtureURL = try #require(Bundle(for: PublicPlanFixtureBundle.self).url(forResource: "PublicPlanVectors", withExtension: "json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        #expect(fixture["publicFixture"] as? Bool == true)
        let wallets = try #require(fixture["mnemonics"] as? [[String: String]])
        let engine = SigningEngine()
        var publicWallets: [[String: Any]] = []
        for wallet in wallets {
            let id = try #require(wallet["localWalletId"])
            let mnemonic = try #require(wallet["mnemonic"])
            let index = try await engine.run(operation: "derivePublicIndex", parameters: ["mnemonic": mnemonic])
            _ = try WalletPublicMetadata(index)
            publicWallets.append(["localWalletId": id, "publicIndex": index])
        }
        let vectors = try #require(fixture["vectors"] as? [[String: Any]])
        let names: Set<String> = ["SOL legacy", "TRON index 99 without path", "BTC two local BIP48 cosigners without derivations"]
        let selected = vectors.filter { names.contains($0["name"] as? String ?? "") }
        #expect(selected.count == 3)
        for vector in selected {
            let request = try #require(vector["request"] as? [String: Any])
            let expected = try #require(vector["expected"] as? [String: Any])
            let review = try await engine.run(operation: "review", parameters: ["request": request])
            let requestHash = try #require(review["requestHash"] as? String)
            let plan = try await engine.run(operation: "resolveSigningPlan", parameters: ["request": request, "wallets": publicWallets])
            let decodedPlan = try SigningPlan(plan, expectedRequestHash: requestHash)
            #expect(decodedPlan.tasks.map { $0.walletID.uuidString.lowercased() } == expected["taskWalletIds"] as? [String])
            #expect(decodedPlan.tasks.map(\.paths) == expected["taskPaths"] as? [[String]])
            var previous: [String: Any]?
            var completed: [String] = []
            for task in decodedPlan.tasks {
                let mnemonic = try #require(wallets.first { $0["localWalletId"] == task.walletID.uuidString.lowercased() }?["mnemonic"])
                var parameters: [String: Any] = ["request": request, "plan": plan, "taskId": task.id, "mnemonic": mnemonic]
                if let previous { parameters["previousResult"] = previous }
                let result = try await engine.run(operation: "signPlanTask", parameters: parameters)
                completed.append(task.id)
                #expect(result["requestHash"] as? String == decodedPlan.requestHash)
                #expect(result["planHash"] as? String == decodedPlan.planHash)
                #expect(result["completedTaskIds"] as? [String] == completed)
                if task.chain == .bitcoin {
                    #expect(result["signedInputs"] as? Int == 1)
                    #expect(result["psbt"] as? String != (previous?["psbt"] as? String ?? request["psbt"] as? String))
                } else {
                    #expect((result["signature"] as? String)?.count == (task.chain == .solana ? 128 : 130))
                    #expect(task.addresses.contains(result["address"] as? String ?? ""))
                    if task.chain == .solana { #expect(task.signerSlot == result["signerIndex"] as? Int) }
                }
                previous = result
            }
            let result = try #require(previous)
            // These resolver vectors deliberately omit transport (including the
            // no-path fallback case). Test the explicit public output encoder;
            // a scanned request's encodeResponse route is covered by UI/UR tests.
            try await checkPublicFixtureExport(chain: try #require(request["chain"] as? String), result: result, engine: engine)
        }
    }

    private func checkPublicFixtureExport(chain: String, result: [String: Any], engine: SigningEngine) async throws {
        let type = try #require(["bitcoin": "crypto-psbt", "evm": "eth-signature", "solana": "sol-signature", "tron": "tron-signature"][chain])
        let payload = try #require((chain == "bitcoin" ? result["psbt"] : result["qrSignature"] ?? result["signature"]) as? String)
        let encoded = try await engine.run(operation: "encodeQR", parameters: [
            "type": type, "payload": payload, "encoding": chain == "bitcoin" ? "base64" : "hex",
            "requestId": "8f235e99-e6e8-4044-a51d-51ec3ec942b0"
        ])
        let frames = try #require(encoded["frames"] as? [String])
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.lowercased().hasPrefix("ur:\(type)/") })
    }

    private func transactionRequest(nonce: Int = 0, data: String = "0x") -> [String: Any] {
        ["chain": "evm", "kind": "transaction", "path": "m/44'/60'/0'/0/0", "address": signer, "masterFingerprint": "73c5da0a",
         "transaction": ["type": 2, "chainId": "1", "nonce": nonce, "gasLimit": "21000", "maxFeePerGas": "2000000000",
                         "maxPriorityFeePerGas": "1000000000", "to": "0x1111111111111111111111111111111111111111", "value": "1", "data": data]]
    }
    private func resolve(_ request: [String: Any], engine: SigningEngine) async throws -> ([String: Any], String) {
        let index = try await engine.run(operation: "derivePublicIndex", parameters: ["mnemonic": phrase])
        let plan = try await engine.run(operation: "resolveSigningPlan", parameters: ["request": request, "wallets": [["localWalletId": "00112233-4455-6677-8899-aabbccddeeff", "publicIndex": index]]])
        #expect(plan["status"] as? String == "ready")
        let taskID = try #require((plan["tasks"] as? [[String: Any]])?.first?["id"] as? String)
        return (plan, taskID)
    }
}

private final class PublicPlanFixtureBundle: NSObject {}
