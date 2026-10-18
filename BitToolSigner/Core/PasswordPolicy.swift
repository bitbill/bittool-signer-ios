import Foundation

/// Passwords are used exactly as entered, without trimming or normalization.
/// A larger limit permits strong passphrases while the required character mix is retained.
enum PasswordPolicy {
    static let minimumLength = 8
    static let maximumLength = 64

    struct Evaluation: Sendable {
        let isValid: Bool
        let categories: Int
        let hasUppercase: Bool
        let hasLowercase: Bool
        let hasNumber: Bool
        let hasSymbol: Bool
        let hasValidLength: Bool
        let message: String
    }

    static func evaluate(_ password: String) -> Evaluation {
        let scalars = password.unicodeScalars
        let uppercase = scalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let lowercase = scalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let number = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let symbol = scalars.contains {
            CharacterSet.symbols.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }
        let categories = [uppercase, lowercase, number, symbol].filter { $0 }.count
        let length = (minimumLength...maximumLength).contains(password.count) && password.utf8.count <= 1024
        let containsControl = scalars.contains { CharacterSet.controlCharacters.contains($0) }
        let valid = length && categories >= 3 && !containsControl
        let message: String
        if !length {
            message = String(localized: "Use 8–64 characters.", bundle: AppText.bundle)
        } else if containsControl {
            message = String(localized: "Control characters are not allowed.", bundle: AppText.bundle)
        } else if categories < 3 {
            message = String(localized: "Include at least 3 of: uppercase, lowercase, numbers and symbols.", bundle: AppText.bundle)
        } else {
            message = String(localized: "Password meets the requirements.", bundle: AppText.bundle)
        }
        return Evaluation(isValid: valid, categories: categories, hasUppercase: uppercase,
                          hasLowercase: lowercase, hasNumber: number, hasSymbol: symbol,
                          hasValidLength: length, message: message)
    }
}
