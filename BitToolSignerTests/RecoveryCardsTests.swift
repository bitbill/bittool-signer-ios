import SwiftUI
import Testing
import UIKit
@testable import BitToolSigner

struct RecoveryCardsTests {
    @Test(arguments: [12, 15, 18, 21, 24])
    func anyTwoCardsRestoreEveryWordAndOneCardLacksAThird(wordCount: Int) {
        let positions = Set(0..<wordCount)
        for card in 0..<RecoveryCards.count {
            let omitted = RecoveryCards.omittedPositions(on: card, wordCount: wordCount)
            #expect(omitted.count == wordCount / 3)
            #expect(omitted == omitted.sorted())
            #expect(omitted.allSatisfy { !RecoveryCards.shows($0, on: card) })
            #expect(positions.subtracting(omitted).allSatisfy { RecoveryCards.shows($0, on: card) })
        }
        for first in 0..<RecoveryCards.count {
            for second in 0..<RecoveryCards.count where second != first {
                let covered = positions.filter { RecoveryCards.shows($0, on: first) || RecoveryCards.shows($0, on: second) }
                #expect(covered == positions, "Cards \(first + 1) and \(second + 1) restore all \(wordCount) words.")
            }
        }
        // Every word is left out by exactly one card.
        #expect(positions.allSatisfy { position in
            (0..<RecoveryCards.count).filter { !RecoveryCards.shows(position, on: $0) }.count == 1
        })
    }

    @Test func eachRowOfThreeLeavesOutOneWordPerCard() {
        for row in 0..<8 {
            let omittedBy = (0..<3).map { RecoveryCards.cardOmitting(row * 3 + $0) }
            #expect(Set(omittedBy) == [0, 1, 2])
        }
        // The layout is fixed, so cards written down at different times match.
        #expect(RecoveryCards.omittedPositions(on: 0, wordCount: 24) == [0, 5, 7, 9, 14, 16, 18, 23])
        #expect(RecoveryCards.omittedPositions(on: 1, wordCount: 12) == [1, 3, 8, 10])
    }

    @Test func shortPhrasesAreFlaggedAsWeakForSplitBackups() {
        #expect(RecoveryCards.remainingEntropyBits(wordCount: 12) == 40)
        #expect(RecoveryCards.remainingEntropyBits(wordCount: 15) == 50)
        #expect(RecoveryCards.remainingEntropyBits(wordCount: 18) == 60)
        #expect(RecoveryCards.remainingEntropyBits(wordCount: 24) == 80)
        #expect(RecoveryCards.singleCardIsWeak(wordCount: 12))
        #expect(RecoveryCards.singleCardIsWeak(wordCount: 15))
        #expect(!RecoveryCards.singleCardIsWeak(wordCount: 18))
        #expect(!RecoveryCards.singleCardIsWeak(wordCount: 24))
    }

    // Grid width on a 375-pt iPhone (SE, 13 mini) and a 402-pt one (17 Pro):
    // screen − 2×20 page padding − 2×12 card padding.
    @Test func wordGridsDropColumnsBeforeCuttingWordsOff() {
        let grid = WordGridColumns(cellPadding: 10, indexSample: "24", indexMinWidth: 18)
        let long = ["abandon", "abstract", "zoo"]
        #expect(grid.count(width: 402 - 64, words: long, dynamicTypeSize: .large) == 3)
        #expect(grid.count(width: 375 - 64, words: long, dynamicTypeSize: .large) == 2, "8-letter words must not be cut off on small phones.")
        #expect(grid.count(width: 375 - 64, words: ["zoo", "army"], dynamicTypeSize: .large) == 3)
        #expect(grid.count(width: 402 - 64, words: long, dynamicTypeSize: .xxxLarge) == 2)
        #expect(grid.count(width: 402 - 64, words: long, dynamicTypeSize: .accessibility5) == 1)
        // One size for every word: the widest word decides it, and it never exceeds the text style.
        let pro = grid.layout(width: 402 - 64, words: long, dynamicTypeSize: .large)
        let short = grid.layout(width: 402 - 64, words: ["zoo", "army"], dynamicTypeSize: .large)
        #expect(pro.wordSize <= short.wordSize && short.wordSize == 15)
        #expect(pro.wordSize >= 15 * WordGridColumns.minimumScale)
        let widest = ("abstract" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: pro.wordSize, weight: .semibold)]).width
        let cell = (402 - 64 - 2 * WordGridColumns.gridSpacing) / 3
        #expect(widest <= cell - 2 * 10 - 18 - 6, "The shared size fits the widest word in its cell.")
        // Before layout (width 0) the old default applies.
        #expect(grid.count(width: 0, words: long, dynamicTypeSize: .large) == 3)
        #expect(grid.count(width: 0, words: long, dynamicTypeSize: .accessibility1) == 2)
    }
}
