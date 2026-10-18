import Foundation

/// An in-memory backup check: a few random positions are blank and their words
/// are offered as shuffled chips, to be placed back in order. Correctness is
/// evaluated for the whole challenge only; chip IDs are their display order and
/// say nothing about where a word belongs.
struct BackupVerification {
    struct Chip: Identifiable, Equatable {
        let id: Int
        let word: String
    }

    enum GenerationError: LocalizedError, Equatable {
        case invalidPhraseLength

        var errorDescription: String? {
            String(localized: "A backup check requires a supported BIP39 phrase length.", bundle: AppText.bundle)
        }
    }

    let wordCount: Int
    /// Blank positions (zero-based), ascending.
    let positions: [Int]
    /// The blank positions' words, shuffled.
    let chips: [Chip]
    /// Blank position → placed chip ID.
    private(set) var placements: [Int: Int] = [:]
    /// An empty blank the person chose to fill next.
    private(set) var selectedPosition: Int?
    private let correctWords: [Int: String]

    /// Four blanks for 12–15 words, five for longer phrases.
    static func blankCount(for wordCount: Int) -> Int { wordCount >= 18 ? 5 : 4 }

    init(words: [String]) throws {
        var generator = SystemRandomNumberGenerator()
        try self.init(words: words, using: &generator)
    }

    init<R: RandomNumberGenerator>(words: [String], using generator: inout R) throws {
        guard BIP39.supportedLengths.contains(words.count) else { throw GenerationError.invalidPhraseLength }
        wordCount = words.count
        let positions = Array(words.indices.shuffled(using: &generator).prefix(Self.blankCount(for: words.count))).sorted()
        self.positions = positions
        correctWords = Dictionary(uniqueKeysWithValues: positions.map { ($0, words[$0]) })
        let answer = positions.map { words[$0] }
        var order = Array(answer.indices)
        // Never present the chips already in answer order (unless all blanks share one word).
        if Set(answer).count > 1 {
            repeat { order.shuffle(using: &generator) } while order.map({ answer[$0] }) == answer
        }
        chips = order.enumerated().map { Chip(id: $0.offset, word: answer[$0.element]) }
    }

    /// Where the next chip goes: the chosen blank, else the first empty one.
    var activePosition: Int? {
        if let selectedPosition, placements[selectedPosition] == nil { return selectedPosition }
        return positions.first { placements[$0] == nil }
    }
    var isComplete: Bool { placements.count == positions.count }
    var isCorrect: Bool { isComplete && positions.allSatisfy { word(at: $0) == correctWords[$0] } }

    func isBlank(_ position: Int) -> Bool { correctWords[position] != nil }
    func word(at position: Int) -> String? {
        placements[position].flatMap { id in chips.first { $0.id == id }?.word }
    }
    func isPlaced(_ chip: Chip) -> Bool { placements.values.contains(chip.id) }

    /// Puts a chip into the active blank.
    @discardableResult
    mutating func place(chipID: Int) -> Bool {
        guard let position = activePosition, chips.contains(where: { $0.id == chipID }),
              !placements.values.contains(chipID) else { return false }
        placements[position] = chipID
        selectedPosition = nil
        return true
    }

    /// Makes an empty blank the next one to fill.
    mutating func select(position: Int) {
        guard isBlank(position), placements[position] == nil else { return }
        selectedPosition = position
    }

    /// Takes the word out of a blank, making it the next one to fill.
    mutating func clear(position: Int) {
        guard isBlank(position) else { return }
        placements[position] = nil
        selectedPosition = position
    }

    mutating func resetPlacements() { placements.removeAll(); selectedPosition = nil }
}
