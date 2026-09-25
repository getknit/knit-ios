import KnitWire
import Testing

/// Wire text keys compare by bytes, the way Kotlin compares strings.
@Suite struct ExactKeyTests {
    @Test func textSwiftCallsEqualIsTwoKeys() {
        // Swift's String == is canonical equivalence; Kotlin's is code units.
        #expect("K" == "\u{212A}")
        #expect(ExactKey("K") != ExactKey("\u{212A}"))
        #expect(ExactKey("\u{E9}") != ExactKey("e\u{301}"))
        #expect(Set([ExactKey("K"), ExactKey("\u{212A}"), ExactKey("K")]).count == 2)
    }

    @Test func aKeyHoldsItsTextsUTF8() {
        #expect(ExactKey("id").bytes == [0x69, 0x64])
        #expect(ExactKey("").bytes.isEmpty)
    }
}
