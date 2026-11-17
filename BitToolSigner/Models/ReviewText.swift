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
    /// Looks a key up in one language's table; nil when the table has no entry.
    typealias Lookup = (String) -> String?

    /// What a piece of engine text looks like once drawn. `complete` is false
    /// when any part of it fell back to the engine's English; the coverage test
    /// reads it, the interface only draws `text`.
    struct Rendered: Equatable {
        let text: String
        let complete: Bool
        static func english(_ text: String) -> Rendered { Rendered(text: text, complete: false) }
    }

    /// The four shapes engine text comes in, each with its own way of being split
    /// into parts that the catalogue can translate.
    enum Kind: CaseIterable {
        /// A whole name: a display action, a review title, a counterparty label.
        case phrase
        /// The line under the action, which may carry a value the engine filled in.
        case headline
        /// A Details label, possibly numbered ("Instruction 2 · Amount (SOL)").
        case label
        /// A warning or a refusal: a sentence, possibly numbered ("HIGH RISK: Order 2: …").
        case sentence
    }

    /// A whole phrase the engine emits unchanged: a Details label, a display
    /// action, a counterparty label.
    static func phrase(_ english: String) -> String { render(english, as: .phrase).text }

    /// Engine headlines that are a fixed phrase followed by a value it fills in.
    /// Only the phrase is translated; the value is reproduced exactly.
    private static let prefixes = ["Method ", "Safe: ", "Batch: ", "New "]

    /// A phrase that may end in an engine-supplied value, such as
    /// "Method 0x3593564c". Left alone when it matches no known shape.
    static func headline(_ english: String) -> String { render(english, as: .headline).text }

    /// Labels the engine builds by appending a unit or symbol it decided at
    /// decode time — "Amount (USDC)", "Native amount (wei)" — or by numbering the
    /// part of the request they belong to — "Instruction 2 · Amount (SOL)",
    /// "Call 3: Recipient". The bracketed unit and the number stay as they are.
    static func label(_ english: String) -> String { render(english, as: .label).text }

    /// A word drawn beside an amount: "Unlimited", or a unit such as "raw units"
    /// or "native coin". Token symbols are names and are never looked up: only a
    /// word written all in lower case, which no symbol in the registry is, or an
    /// amount that is not a number at all.
    static func unit(_ english: String) -> String {
        let lowercaseWords = english.range(of: "^[a-z][a-z ]*$", options: .regularExpression) != nil
        let notANumber = english.range(of: "^[0-9.,\\s]+$", options: .regularExpression) == nil
        return lowercaseWords || notANumber ? phrase(english) : english
    }

    /// An amount as the card draws it: the number as the engine wrote it, and the
    /// word beside it — "Unlimited", "raw units", a token symbol — through `unit`.
    static func amountLine(_ amount: String, _ symbol: String?) -> String {
        [unit(amount), symbol.map(unit)].compactMap { $0 }.joined(separator: " ")
    }

    /// Whether a headline is the requester's own text rather than the engine's: the
    /// words of a message, or the type name of typed data the engine does not
    /// recognise. Those are drawn exactly as they arrive — a message that happens
    /// to equal a catalogue entry must not be shown translated, because the text on
    /// screen would then differ from the text being signed.
    static func headlineIsTheirs(action: String?) -> Bool {
        action == "Sign Message" || action == "Sign Typed Data"
    }

    /// The engine warnings that carry a value. Order matters only in that a
    /// more specific template must come before one that could also match it.
    private static let templates: [Template] = TemplateTable.all.map(Template.init)

    /// The template table, for tests that check it is well formed.
    static var registeredTemplates: [Template] { templates }

    /// A warning the engine wrote. Most are whole sentences and translate by
    /// lookup; the rest are a fixed sentence with values the engine filled in at
    /// decode time — an amount, a chain ID, an address — and those are matched
    /// against the English templates, with the values reproduced exactly.
    ///
    /// An untranslated warning stays in the engine's English rather than
    /// disappearing, so a new warning is readable the day it is added.
    ///
    /// Callers must decide severity from the **engine's** English, never from the
    /// result: "HIGH RISK" is a marker in the source text, not in the translation.
    static func sentence(_ english: String) -> String { render(english, as: .sentence).text }

    /// `sentence` with the catalogue lookup supplied, so a test can hand it a
    /// translation that does not fit and see the English come back.
    static func sentence(_ english: String, translate: Lookup) -> String {
        render(english, as: .sentence, translate: translate).text
    }

    /// Draws engine text of one kind through one language's table.
    static func render(_ english: String, as kind: Kind, translate: Lookup = translation(of:)) -> Rendered {
        guard !english.isEmpty else { return Rendered(text: english, complete: true) }
        if let direct = direct(english, translate) { return Rendered(text: direct, complete: true) }
        switch kind {
        case .phrase: return phraseParts(english, translate)
        case .headline: return headlineParts(english, translate)
        case .label: return labelParts(english, translate)
        case .sentence: return sentenceParts(english, translate)
        }
    }

    /// An exact catalogue entry, or a registered template with its values put back.
    private static func direct(_ english: String, _ translate: Lookup) -> String? {
        if let translated = translate(english) { return translated }
        for template in templates {
            guard var values = template.match(english) else { continue }
            guard let localized = translate(template.english) else { return nil }
            // A value that is engine text itself is translated in turn; data, or
            // text the catalogue lacks, is drawn exactly as the engine wrote it.
            for (index, kind) in TemplateTable.slots[template.english] ?? [:] where values.indices.contains(index) {
                let inner = render(values[index], as: kind, translate: translate)
                if inner.complete { values[index] = inner.text }
            }
            return substitute(localized, values)
        }
        return nil
    }

    /// One numbered key — "Call %@", "Orders %@ (+%@ more)" — filled with its
    /// numbers, which are drawn as the engine wrote them.
    private static func numbered(_ key: String, _ values: [String], _ translate: Lookup) -> Rendered? {
        guard let localized = translate(key), let text = substitute(localized, values) else { return nil }
        return Rendered(text: text, complete: true)
    }

    private static func join(_ parts: Rendered..., separator: String = "") -> Rendered {
        Rendered(text: parts.map(\.text).joined(separator: separator), complete: parts.allSatisfy(\.complete))
    }

    /// The groups a regular expression captured, or nil when it does not match the whole text.
    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators]),
              let m = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { index in
            Range(m.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// The parts of a request the engine numbers, as they prefix labels and warnings.
    private static let numberedParts = "Call|Order|Instruction|Input|Output|Authorization|Item|Token"

    // "Safe: Send", "TRON Transfer tokens": a fixed prefix on a phrase that translates on its own.
    private static func phraseParts(_ english: String, _ translate: Lookup) -> Rendered {
        if let g = groups("Safe: (.+)", english), let safe = translate("Safe:") {
            return join(Rendered(text: safe, complete: true), render(g[0], as: .phrase, translate: translate), separator: " ")
        }
        if let g = groups("TRON (.+)", english) {
            return join(Rendered(text: "TRON", complete: true), render(g[0], as: .phrase, translate: translate), separator: " ")
        }
        return .english(english)
    }

    private static func headlineParts(_ english: String, _ translate: Lookup) -> Rendered {
        for prefix in prefixes where english.hasPrefix(prefix) {
            let value = String(english.dropFirst(prefix.count))
            guard !value.isEmpty else { break }
            let head = Rendered(text: phrase(String(prefix.dropLast()), translate), complete: translate(String(prefix.dropLast())) != nil)
            // "Safe: …" and "Batch: …" wrap another headline; "Method 0x…" and "New …" wrap a value.
            let rest = ["Safe: ", "Batch: "].contains(prefix) ? render(value, as: .headline, translate: translate) : Rendered(text: value, complete: true)
            return join(head, rest, separator: " ")
        }
        return .english(english)
    }

    private static func phrase(_ english: String, _ translate: Lookup) -> String { translate(english) ?? english }

    private static func labelParts(_ english: String, _ translate: Lookup) -> Rendered {
        // "Order 3 · Also paid · Item 2": each part on its own.
        if let dot = english.range(of: " · ") {
            return join(render(String(english[..<dot.lowerBound]), as: .label, translate: translate),
                        render(String(english[dot.upperBound...]), as: .label, translate: translate), separator: " · ")
        }
        // "Call 3: Recipient", "Call 2: Call 1: Method"
        if let g = groups("(\(numberedParts)) ([0-9]+): (.+)", english), let head = numbered("\(g[0]) %@", [g[1]], translate) {
            return join(head, render(g[2], as: .label, translate: translate), separator: ": ")
        }
        // "Output 2", and "Output 2 ownership", "Token 1 allowance (raw units)"
        if let g = groups("(\(numberedParts)) ([0-9]+)", english), let whole = numbered("\(g[0]) %@", [g[1]], translate) { return whole }
        if let g = groups("(\(numberedParts)) ([0-9]+) (.+)", english), let whole = numbered("\(g[0]) %@ \(g[2])", [g[1]], translate) { return whole }
        if let g = groups("Safe: (.+)", english), let safe = translate("Safe:") {
            return join(Rendered(text: safe, complete: true), render(g[0], as: .label, translate: translate), separator: " ")
        }
        // "Amount (USDC)": the stem translates, the symbol is the engine's value. A
        // bracket that says something — "(stored, not enforced)", "(raw units)" — is
        // part of the label, which then has to be in the catalogue whole.
        if let g = groups("(.+?) \\(([A-Za-z0-9.$-]+)\\)", english) {
            let stem = render(g[0], as: .label, translate: translate)
            guard stem.complete else { return .english(english) }
            return Rendered(text: stem.text + " (" + g[1] + ")", complete: true)
        }
        return .english(english)
    }

    /// The labels the engine puts on a warning that belongs to one part of a batch:
    /// "Call 3", "Order 2", "All 40 orders", "Orders 1, 3 (+5 more)".
    private static let warningLabel = "Call [0-9]+|Order [0-9]+|All [0-9]+ orders|Orders [0-9]+(?:, [0-9]+)*(?: \\(\\+[0-9]+ more\\))?"

    private static func warningLabel(_ label: String, _ translate: Lookup) -> Rendered {
        if let g = groups("(Call|Order) ([0-9]+)", label), let r = numbered("\(g[0]) %@", [g[1]], translate) { return r }
        if let g = groups("All ([0-9]+) orders", label), let r = numbered("All %@ orders", [g[0]], translate) { return r }
        if let g = groups("Orders (.+) \\(\\+([0-9]+) more\\)", label), let r = numbered("Orders %@ (+%@ more)", g, translate) { return r }
        if let g = groups("Orders (.+)", label), let r = numbered("Orders %@", g, translate) { return r }
        return .english(label)
    }

    private static func sentenceParts(_ english: String, _ translate: Lookup) -> Rendered {
        // A numbered sentence is put back together only when every part of it
        // translates. Otherwise it is drawn exactly as the engine wrote it: in
        // English the parts would come back in a different order.
        let composed = numberedSentence(english, translate)
        return composed?.complete == true ? composed! : .english(english)
    }

    private static func numberedSentence(_ english: String, _ translate: Lookup) -> Rendered? {
        // "HIGH RISK: Order 2: You receive nothing…" is "HIGH RISK: You receive
        // nothing…" said of order 2. The sentence keeps its marker; the label leads.
        if let g = groups("(HIGH RISK|HIGH FEE): (\(warningLabel)): (.+)", english) {
            return join(warningLabel(g[1], translate), render("\(g[0]): \(g[2])", as: .sentence, translate: translate), separator: ": ")
        }
        // "UNLIMITED spending approval (Call 3)."
        if let g = groups("(.+) \\((\(warningLabel))\\)\\.", english) {
            var inner = render(g[0] + ".", as: .sentence, translate: translate)
            if !inner.complete { inner = render(g[0], as: .sentence, translate: translate) }
            let label = warningLabel(g[1], translate)
            return Rendered(text: inner.text + " (" + label.text + ")", complete: inner.complete && label.complete)
        }
        if let g = groups("(\(warningLabel)): (.+)", english) {
            return join(warningLabel(g[0], translate), render(g[1], as: .sentence, translate: translate), separator: ": ")
        }
        return nil
    }

    /// One engine warning whose text carries values. `english` is the source
    /// sentence with `%@` where a value goes; it is both the translation key and
    /// the pattern the engine's output is matched against, so the two cannot
    /// drift apart.
    struct Template {
        let english: String
        private let expression: NSRegularExpression?

        init(_ english: String) {
            self.english = english
            // The engine and the catalogue do not agree on apostrophes: five of the
            // HIGH RISK warnings came out of the engine as "transaction's" while
            // their keys read "transaction’s", and every one of them stayed in
            // English. Either form now matches either; values are captured from
            // the original text, untouched.
            let pattern = english
                .components(separatedBy: "%@")
                .map { NSRegularExpression.escapedPattern(for: $0)
                        // One form first, then widen it once: widening first would
                        // rewrite the ’ inside the class it had just inserted.
                        .replacingOccurrences(of: "\u{2019}", with: "'")
                        .replacingOccurrences(of: "'", with: "['\u{2019}]") }
                .joined(separator: "(.+?)")
            expression = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators])
        }

        /// The values this warning filled in, or nil when it is a different warning.
        func match(_ text: String) -> [String]? {
            guard let expression else { return nil }
            let whole = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let m = expression.firstMatch(in: text, options: [.anchored], range: whole) else { return nil }
            return (1..<m.numberOfRanges).compactMap { index in
                Range(m.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    /// A `%@`, or a numbered `%2$@`. A translation that reorders the values has to
    /// number them — many languages do, so "%@ of this instruction\u{2019}s %@ accounts"
    /// becomes "this instruction\u{2019}s %2$@ accounts, %1$@ of which" in Japanese.
    private static let specifier = try? NSRegularExpression(pattern: "%(?:[0-9]+\\$)?@")

    /// Substitutes `values` into a translated template, or nil when its
    /// placeholders do not match the values — the caller then shows the engine's
    /// English, rather than a sentence with "%@" or "(null)" in it.
    /// `scripts/write-localizations.py` rejects those at build time, so this only
    /// guards a hand-edited .strings file.
    static func substitute(_ template: String, _ values: [String]) -> String? {
        guard let specifier else { return nil }
        let whole = NSRange(template.startIndex..<template.endIndex, in: template)
        guard specifier.numberOfMatches(in: template, range: whole) == values.count else { return nil }
        // A percent sign that is not a placeholder ("%@% (%@ bps)") is text, which
        // String(format:) reads as the start of a specifier unless it is doubled.
        let literal = template.replacingOccurrences(of: "%(?!(?:[0-9]+\\$)?@)", with: "%%", options: .regularExpression)
        return String(format: literal, arguments: values.map { $0 as CVarArg })
    }

    /// The translation of `english`, or nil when the table has no entry for it.
    static func translation(of english: String) -> String? {
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
    ///
    /// The whole part is carried as a string, never parsed into an integer. A
    /// request can name any fee the engine can represent — far beyond `Int` —
    /// and this runs while drawing the review, before anyone has authorized
    /// anything. Parsing and adding would trap on an overflow and take the app
    /// down on a request it was supposed to be warning about.
    private static func increment(whole: String, fraction: String) -> String? {
        guard let carriedFraction = carried(Array(fraction)) else { return nil }
        guard carriedFraction.carry else { return whole + "." + String(carriedFraction.digits) }
        guard let carriedWhole = carried(Array(whole)) else { return nil }
        let head = carriedWhole.carry ? "1" : ""
        return head + String(carriedWhole.digits) + "." + String(carriedFraction.digits)
    }

    /// Adds one to a run of decimal digits, reporting whether it carried past
    /// the front. Nil if anything in it is not a digit.
    private static func carried(_ digits: [Character]) -> (digits: [Character], carry: Bool)? {
        var digits = digits, carry = true, index = digits.count - 1
        while carry && index >= 0 {
            guard let value = digits[index].wholeNumberValue else { return nil }
            if value == 9 { digits[index] = "0" } else { digits[index] = Character(String(value + 1)); carry = false }
            index -= 1
        }
        return (digits, carry)
    }
}
