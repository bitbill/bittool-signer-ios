import Foundation
import Testing
@testable import BitToolSigner

/// The engine writes its review text in English; the interface translates it as
/// it draws. These check the two things that translation must not get wrong:
/// a phrase with no entry still appears, and a shortened fee is never smaller
/// than the one the request actually allows.
struct ReviewTextTests {
    @Test func anUntranslatedPhraseFallsBackToTheEngineWording() {
        // Nothing in any table translates this, so the review still says it.
        #expect(ReviewText.phrase("Dilithium Vault Rebalance") == "Dilithium Vault Rebalance")
        #expect(ReviewText.label("Entangled amount (QBIT)") == "Entangled amount (QBIT)")
        #expect(ReviewText.headline("Warp 0xdeadbeef") == "Warp 0xdeadbeef")
        #expect(ReviewText.phrase("") == "")
    }

    @Test func aHeadlineKeepsTheValueTheEngineFilledIn() {
        // English resolves to itself, so the selector must survive untouched.
        #expect(ReviewText.headline("Method 0x3593564c").hasSuffix(" 0x3593564c"))
        // "Method" with nothing after it is not a prefix match.
        #expect(ReviewText.headline("Method ") == "Method ")
    }

    @Test func aFeeCeilingIsShownToEightDecimalsAndRoundsUp() {
        // The screenshot case: 18 decimals of gas ceiling, cut to eight.
        #expect(ReviewText.shortDecimal("0.000396834604360128 ETH") == "0.00039684 ETH")
        // Rounding up carries through nines, and into the whole part.
        #expect(ReviewText.shortDecimal("0.999999999 ETH") == "1.00000000 ETH")
        #expect(ReviewText.shortDecimal("1.123456789 ETH") == "1.12345679 ETH")
        // Everything dropped is zero, so the kept digits stand as they are.
        #expect(ReviewText.shortDecimal("0.500000000000 ETH") == "0.50000000 ETH")
    }

    @Test func aFeeTooLargeForAnIntegerStillRenders() {
        // A request can name any fee the engine can represent, and this runs
        // while drawing the review — before anyone has authorized anything.
        // Carrying through Int would trap and take the app down.
        #expect(ReviewText.shortDecimal("9223372036854775807.99999999999998 ETH") == "9223372036854775808.00000000 ETH")
        #expect(ReviewText.shortDecimal("99999999999999999999999999.999999999 ETH") == "100000000000000000000000000.00000000 ETH")
        // Carrying into a whole part that is itself all nines grows a digit.
        #expect(ReviewText.shortDecimal("9.999999999") == "10.00000000")
    }

    @Test func shorteningLeavesAnythingItCannotRoundAlone() {
        #expect(ReviewText.shortDecimal("0.0001 ETH") == "0.0001 ETH")   // already short
        #expect(ReviewText.shortDecimal("12 TRX") == "12 TRX")           // no fraction
        #expect(ReviewText.shortDecimal("0.00039683") == "0.00039683")   // no unit
        #expect(ReviewText.shortDecimal("about 0.1 ETH") == "about 0.1 ETH")
        #expect(ReviewText.shortDecimal("") == "")
    }
}
