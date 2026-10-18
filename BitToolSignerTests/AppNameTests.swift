import Foundation
import SwiftUI
import Testing
@testable import BitToolSigner

/// The app is called BitTool Signer in every language; only the interface is
/// translated. Each bundled localisation must actually carry strings, so the
/// picker never offers a language that would leave the interface in English.
struct AppNameTests {
    @Test func theAppIsNamedBitToolSignerEverywhere() throws {
        #expect(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String == "BitTool Signer")
        for code in Bundle.main.localizations where code != "Base" {
            // A localisation may translate the system prompts (camera, Face ID),
            // but never the app's own name.
            guard let url = Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: code) else { continue }
            let strings = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(code)")
            #expect(strings["CFBundleDisplayName"] == nil && strings["CFBundleName"] == nil, "\(code) must not rename the app")
            #expect(strings.values.allSatisfy { !$0.isEmpty }, "\(code)")
            #expect(!strings.isEmpty, "\(code) ships an empty InfoPlist.strings")
        }
    }

    /// Every language that translates the interface also translates the system
    /// prompts, so iOS never asks for the camera in English inside a
    /// translated app.
    @Test func everyTranslatedLanguageTranslatesTheSystemPrompts() throws {
        for language in AppLanguage.selectable where ![.system, .english].contains(language) {
            let url = try #require(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: language.rawValue),
                                   "\(language.rawValue) has no InfoPlist.strings")
            let strings = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for key in ["NSCameraUsageDescription", "NSFaceIDUsageDescription"] {
                let value = try #require(strings[key], "\(language.rawValue) is missing \(key)")
                #expect(value != Bundle.main.infoDictionary?[key] as? String, "\(language.rawValue) \(key) is still English")
            }
        }
    }

    @Test func everyOfferedLanguageIsTranslated() throws {
        let offered = AppLanguage.selectable.filter { $0 != .system }
        #expect(offered.contains(.english) && offered.count > 1, "Offered: \(offered.map(\.rawValue))")
        for language in offered where language != .english {
            let url = try #require(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.rawValue),
                                   "\(language.rawValue) has no strings file")
            let strings = try #require(NSDictionary(contentsOf: url) as? [String: String])
            #expect(strings.count > 200, "\(language.rawValue) has only \(strings.count) strings")
            #expect(strings["Settings"] != nil && strings["Settings"] != "Settings", "\(language.rawValue) must translate Settings")
            #expect(strings.values.allSatisfy { !$0.isEmpty })
        }
        #expect(AppLanguage.arabic.layoutDirection == .rightToLeft)
        #expect(AppLanguage.english.layoutDirection == .leftToRight)
    }
}
