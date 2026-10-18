import Foundation
import Testing
@testable import BitToolSigner

struct BackupVerificationTests {
    @Test(arguments: [12, 15, 18, 21, 24])
    func supportedLengthsBlankRandomPositionsAndOfferExactlyTheirWords(length: Int) async throws {
        // Deterministic, public test entropy; never a user or funded wallet.
        let entropy = (0..<(length * 4 / 3)).map { String(format: "%02x", $0) }.joined()
        let result = try await SigningEngine().run(operation: "mnemonic", parameters: ["entropy": entropy])
        let phrase = try #require(result["mnemonic"] as? String).split(separator: " ").map(String.init)
        var generator = SeededBackupGenerator(seed: UInt64(length))
        let challenge = try BackupVerification(words: phrase, using: &generator)
        #expect(challenge.wordCount == length)
        #expect(challenge.positions.count == (length >= 18 ? 5 : 4))
        #expect(Set(challenge.positions).count == challenge.positions.count)
        #expect(challenge.positions == challenge.positions.sorted())
        #expect(challenge.positions.allSatisfy { phrase.indices.contains($0) })
        // The chips are exactly the blank positions' words, in another order.
        #expect(challenge.chips.map(\.word).sorted() == challenge.positions.map { phrase[$0] }.sorted())
        #expect(challenge.chips.map(\.word) != challenge.positions.map { phrase[$0] })
        #expect(challenge.chips.map(\.id) == Array(challenge.chips.indices))
        #expect(challenge.activePosition == challenge.positions.first)
        #expect(!challenge.isComplete)
        #expect(!challenge.isCorrect)
    }

    @Test func placingInOrderPassesAndAnyOtherOrderFails() async throws {
        let phrase = distinctPhrase
        var generator = SeededBackupGenerator(seed: 83)
        var challenge = try BackupVerification(words: phrase, using: &generator)
        for position in challenge.positions {
            let chip = try #require(challenge.chips.first { $0.word == phrase[position] && !challenge.isPlaced($0) })
            #expect(challenge.activePosition == position)
            let placed = challenge.place(chipID: chip.id)
            #expect(placed)
        }
        #expect(challenge.isComplete)
        #expect(challenge.isCorrect)
        #expect(challenge.activePosition == nil)
        // Nothing more can be placed once every blank is filled.
        let extra = challenge.place(chipID: 0)
        #expect(!extra)

        // Clearing a blank makes it the next one to fill.
        let middle = challenge.positions[1]
        challenge.clear(position: middle)
        #expect(challenge.activePosition == middle)
        #expect(!challenge.isComplete)

        // Two chips swapped: complete, but wrong.
        challenge.resetPlacements()
        let answer = challenge.positions.map { position in challenge.chips.first { $0.word == phrase[position] }!.id }
        var swapped = answer
        swapped.swapAt(0, 1)
        for id in swapped { challenge.place(chipID: id) }
        #expect(challenge.isComplete)
        #expect(!challenge.isCorrect)
        challenge.resetPlacements()
        #expect(challenge.placements.isEmpty)
        #expect(challenge.activePosition == challenge.positions.first)
    }

    @Test func choosingABlankDirectsTheNextWordThere() async throws {
        let phrase = distinctPhrase
        var generator = SeededBackupGenerator(seed: 29)
        var challenge = try BackupVerification(words: phrase, using: &generator)
        let last = try #require(challenge.positions.last)
        challenge.select(position: last)
        #expect(challenge.activePosition == last)
        let chip = try #require(challenge.chips.first { $0.word == phrase[last] })
        challenge.place(chipID: chip.id)
        #expect(challenge.word(at: last) == phrase[last])
        #expect(challenge.activePosition == challenge.positions.first, "After placing, the first empty blank is next.")
        // Masked positions and filled blanks cannot be chosen.
        let masked = try #require(phrase.indices.first { !challenge.isBlank($0) })
        challenge.select(position: masked)
        challenge.select(position: last)
        #expect(challenge.activePosition == challenge.positions.first)
        // Clearing a filled blank makes it the next one to fill.
        challenge.clear(position: last)
        #expect(challenge.activePosition == last)
    }

    @Test func chipsCannotBeUsedTwiceOrInvented() async throws {
        var generator = SeededBackupGenerator(seed: 51)
        var challenge = try BackupVerification(words: distinctPhrase, using: &generator)
        let first = challenge.place(chipID: 0)
        #expect(first)
        let placements = challenge.placements
        let again = challenge.place(chipID: 0)
        let negative = challenge.place(chipID: -1)
        let beyond = challenge.place(chipID: challenge.chips.count)
        #expect(!again && !negative && !beyond)
        #expect(challenge.placements == placements)
    }

    @Test func repeatedWordsAreInterchangeable() async throws {
        // "abandon" ×11 + "about": blanks can hold the same word more than once.
        let phrase = Array(repeating: "abandon", count: 11) + ["about"]
        for seed in 0..<12 {
            var generator = SeededBackupGenerator(seed: UInt64(seed))
            var challenge = try BackupVerification(words: phrase, using: &generator)
            for position in challenge.positions {
                let chip = try #require(challenge.chips.first { $0.word == phrase[position] && !challenge.isPlaced($0) })
                challenge.place(chipID: chip.id)
            }
            #expect(challenge.isCorrect)
        }
    }

    @Test func injectedRandomnessIsRepeatableAndFreshChallengesVary() async throws {
        var first = SeededBackupGenerator(seed: 5), matching = SeededBackupGenerator(seed: 5), different = SeededBackupGenerator(seed: 6)
        let a = try BackupVerification(words: distinctPhrase, using: &first)
        let b = try BackupVerification(words: distinctPhrase, using: &matching)
        let c = try BackupVerification(words: distinctPhrase, using: &different)
        #expect(a.positions == b.positions && a.chips == b.chips)
        #expect(a.positions != c.positions || a.chips != c.chips)
    }

    @Test func malformedInputFailsClosed() {
        for length in [0, 4, 11, 13, 25, 48] {
            #expect(throws: BackupVerification.GenerationError.invalidPhraseLength) {
                try BackupVerification(words: Array(repeating: "abandon", count: length))
            }
        }
    }

    /// Twelve distinct public words (not a valid checksum; the check never needs one).
    private var distinctPhrase: [String] {
        ["abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd", "abuse", "access", "accident"]
    }
}

/// SplitMix64 is a deterministic test fixture, never used for app randomness.
private struct SeededBackupGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
