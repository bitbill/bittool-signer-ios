import SwiftUI

/// The interface language, chosen in Settings and applied without restarting.
/// `system` follows the device. Every other case names a localisation bundled
/// with the app, so switching is a change of environment, not of process.
///
/// The names are endonyms: a list of languages is read by people who do not yet
/// read the current one.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"
    case ukrainian = "uk"
    case spanish = "es"
    case latinAmericanSpanish = "es-419"
    case german = "de"
    case french = "fr"
    case italian = "it"
    case brazilianPortuguese = "pt-BR"
    case europeanPortuguese = "pt-PT"
    case polish = "pl"
    case indonesian = "id"
    case turkish = "tr"
    case thai = "th"
    case vietnamese = "vi"
    case filipino = "fil"
    case arabic = "ar"

    var id: String { rawValue }

    var endonym: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .russian: "Русский"
        case .ukrainian: "Українська"
        case .spanish: "Español (España)"
        case .latinAmericanSpanish: "Español (Latinoamérica)"
        case .german: "Deutsch"
        case .french: "Français"
        case .italian: "Italiano"
        case .brazilianPortuguese: "Português (Brasil)"
        case .europeanPortuguese: "Português (Portugal)"
        case .polish: "Polski"
        case .indonesian: "Bahasa Indonesia"
        case .turkish: "Türkçe"
        case .thai: "ภาษาไทย"
        case .vietnamese: "Tiếng Việt"
        case .filipino: "Filipino"
        case .arabic: "العربية"
        }
    }

    /// Languages the app is actually translated into, in the order shown. A
    /// language appears here only once its strings are bundled, so the picker
    /// never offers one that would leave the interface in English.
    static var selectable: [AppLanguage] {
        allCases.filter { $0 == .system || Bundle.main.localizations.contains($0.rawValue) }
    }

    var locale: Locale? { self == .system ? nil : Locale(identifier: rawValue) }

    /// Arabic lays out right to left; everything mirrors, including back buttons
    /// and the leading edge of every row.
    var layoutDirection: LayoutDirection? {
        switch self {
        case .system: nil
        case .arabic: .rightToLeft
        default: .leftToRight
        }
    }

    /// The bundle to read strings from. Picking a language means reading that
    /// language's bundle even when the device is set to another one.
    var bundle: Bundle? {
        guard self != .system,
              let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle
    }

    static func current(_ stored: String) -> AppLanguage { AppLanguage(rawValue: stored) ?? .system }
}

/// Applies the chosen language to a view tree: the locale decides which strings
/// SwiftUI looks up, the layout direction decides which way the interface runs.
struct LanguageEnvironment: ViewModifier {
    let language: AppLanguage

    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.locale ?? Locale.autoupdatingCurrent)
            .environment(\.layoutDirection, language.layoutDirection ?? systemDirection)
            // Navigation titles and toolbar text are resolved once and cached, so
            // a change of language rebuilds the tree. It returns to the first tab,
            // which is the usual behaviour for switching language.
            .id(language.rawValue)
    }

    private var systemDirection: LayoutDirection {
        Locale.Language(identifier: Locale.autoupdatingCurrent.identifier).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

extension View {
    func appLanguage(_ language: AppLanguage) -> some View { modifier(LanguageEnvironment(language: language)) }
}

/// Interface text built outside a SwiftUI view — error messages, mostly.
/// A view resolves `LocalizedStringKey` against the environment locale, which
/// the language picker sets; a string built in the model layer has no
/// environment, so it reads the chosen language's bundle itself.
enum AppText {
    /// The bundle for the language chosen in Settings, or the main bundle when
    /// the app follows the system.
    static var bundle: Bundle {
        AppLanguage.current(UserDefaults.standard.string(forKey: "language") ?? "").bundle ?? .main
    }
}
