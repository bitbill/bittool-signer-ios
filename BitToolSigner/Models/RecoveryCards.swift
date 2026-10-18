import Foundation

/// Splits a recovery phrase across three cards so that any two restore it.
///
/// Word positions are laid out in rows of three, and each card leaves out one
/// word per row, shifting by one position every row. Every card therefore lacks
/// exactly a third of the words, and each missing word is present on the other
/// two cards.
///
/// The layout depends only on the word count, never on the words themselves:
/// opening the cards again, or on another device, always gives the same three
/// cards, so cards written down at different times still fit together. The
/// layout is not secret; each card shows which positions it leaves out.
enum RecoveryCards {
    static let count = 3

    /// The card (0, 1 or 2) that leaves out the word at `position` (zero-based).
    static func cardOmitting(_ position: Int) -> Int {
        (position / count + position % count) % count
    }

    static func shows(_ position: Int, on card: Int) -> Bool {
        cardOmitting(position) != card
    }

    /// Zero-based positions the card leaves out, ascending.
    static func omittedPositions(on card: Int, wordCount: Int) -> [Int] {
        (0..<wordCount).filter { cardOmitting($0) == card }
    }

    /// Bits an attacker must still guess with one card: 11 bits per missing
    /// word, less the checksum bits (one per three words) that let a guess be
    /// rejected without any further work.
    static func remainingEntropyBits(wordCount: Int) -> Int {
        let missing = wordCount / count
        return missing * 11 - wordCount / 3
    }

    /// One card of a 12- or 15-word phrase leaves too little to guess
    /// (40 or 50 bits) to stand up to a determined attacker.
    static func singleCardIsWeak(wordCount: Int) -> Bool {
        remainingEntropyBits(wordCount: wordCount) < 60
    }
}
