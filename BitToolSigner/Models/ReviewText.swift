import Foundation

/// Translates the review text the offline engine produces.
///
/// The engine writes its field labels, action names and headlines in English
/// and nothing translates them there: that text is what the request fingerprint
/// covers and what a rebuilt engine has to reproduce byte for byte, so a
/// language setting must not change it. The interface translates at the last
/// moment instead, when the words are drawn, and falls back to the engine's own
/// English whenever a phrase has no translation — a new label added to the
/// engine shows up in English rather than disappearing.
enum ReviewText {
    /// A whole phrase the engine emits unchanged: a Details label, a display
    /// action, a counterparty label.
    static func phrase(_ english: String) -> String {
        guard !english.isEmpty else { return english }
        return NSLocalizedString(english, bundle: AppText.bundle, value: english, comment: "")
    }

    /// Engine headlines that are a fixed phrase followed by a value it fills in.
    /// Only the phrase is translated; the value is reproduced exactly.
    private static let prefixes = ["Method ", "Safe: ", "Batch: ", "New "]

    /// A phrase that may end in an engine-supplied value, such as
    /// "Method 0x3593564c". Left alone when it matches no known shape.
    static func headline(_ english: String) -> String {
        if let translated = translation(of: english) { return translated }
        for prefix in prefixes where english.hasPrefix(prefix) {
            let value = String(english.dropFirst(prefix.count))
            guard !value.isEmpty else { break }
            return phrase(String(prefix.dropLast())) + " " + value
        }
        return english
    }

    /// Labels the engine builds by appending a unit or symbol it decided at
    /// decode time — "Amount (USDC)", "Native amount (wei)". The bracketed part
    /// is a token symbol or a chain unit and stays as it is.
    static func label(_ english: String) -> String {
        if let translated = translation(of: english) { return translated }
        guard english.hasSuffix(")"), let open = english.lastIndex(of: "(") else { return english }
        let stem = String(english[english.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let unit = String(english[open...])
        guard let translated = translation(of: stem) else { return english }
        return translated + " " + unit
    }

    /// The translation of `english`, or nil when the table has no entry for it.
    private static func translation(of english: String) -> String? {
        guard !english.isEmpty else { return nil }
        let marker = "\u{0}none\u{0}"
        let value = NSLocalizedString(english, bundle: AppText.bundle, value: marker, comment: "")
        return value == marker ? nil : value
    }

    /// Shortens a decimal amount for display, keeping at most `places` digits
    /// after the point. Fee ceilings round away from zero so the figure shown
    /// is never below the one the request actually allows; the exact value
    /// stays in Details.
    static func shortDecimal(_ text: String, places: Int = 8) -> String {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let number = parts.first else { return text }
        let unit = parts.count > 1 ? " " + parts[1] : ""
        guard let dot = number.firstIndex(of: "."), number.dropFirst().allSatisfy({ $0.isNumber || $0 == "." })
        else { return text }
        let whole = String(number[number.startIndex..<dot])
        let fraction = String(number[number.index(after: dot)...])
        guard fraction.count > places, fraction.allSatisfy(\.isNumber) else { return text }
        let kept = String(fraction.prefix(places))
        // Everything dropped was non-zero only if some digit beyond the cut is,
        // in which case the kept digits are stepped up by one to stay an upper
        // bound. "0.999…" carries into the whole part.
        let dropped = fraction.dropFirst(places)
        guard dropped.contains(where: { $0 != "0" }) else {
            return whole + "." + kept + unit
        }
        guard let rounded = increment(whole: whole, fraction: kept) else { return text }
        return rounded + unit
    }

    /// Adds one unit in the last place of `fraction`, carrying into `whole`.
    private static func increment(whole: String, fraction: String) -> String? {
        var digits = Array(fraction), carry = true
        var index = digits.count - 1
        while carry && index >= 0 {
            guard let value = digits[index].wholeNumberValue else { return nil }
            if value == 9 { digits[index] = "0" } else { digits[index] = Character(String(value + 1)); carry = false }
            index -= 1
        }
        guard carry else { return whole + "." + String(digits) }
        guard let number = Int(whole) else { return nil }
        return String(number + 1) + "." + String(digits)
    }
}
