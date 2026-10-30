import KnitTestSupport
import Testing

@testable import KnitWire

/// knit-next's name key contract (`vectors/name-key-v1.json`, knit-next #228), checked as `NameKeyVectorTest` checks it on
/// Android: the fold and drop tables are this port's own literal constants, and every name gives the key, the display
/// blank and the cleaned text the file states. A case answered differently is a name the two platforms discriminate, or
/// show, differently.
@Suite struct NameKeyVectorTests {
    private static let file = NameKeyVectors.file

    @Test func theFoldTableIsTheVectors() throws {
        var stated: [UInt32: String] = [:]
        for entry in Self.file.fold {
            let from = try #require(NameKeyVectors.codePoint(entry.from), "\(entry.from)")
            #expect(stated.updateValue(entry.to, forKey: from) == nil, "\(entry.from) is listed once")
        }
        let ours = Dictionary(uniqueKeysWithValues: NameKey.lookalikes.map { ($0.key.value, String($0.value)) })
        #expect(ours == stated)
    }

    @Test func theDropRangesAreTheVectors() throws {
        let stated = try Self.file.drop.map { range in
            try #require(NameKeyVectors.codePoint(range.first))...(try #require(NameKeyVectors.codePoint(range.last)))
        }
        let ours = NameKey.dropped.map { $0.lowerBound.value...$0.upperBound.value }
        #expect(ours.sorted { $0.lowerBound < $1.lowerBound } == stated.sorted { $0.lowerBound < $1.lowerBound })
    }

    @Test func theLimitsAreOurs() {
        #expect(Self.file.limits.displayName == TextLimits.displayName)
        #expect(Self.file.limits.status == TextLimits.status)
        #expect(Self.file.limits.groupName == TextLimits.groupName)
    }

    /// Each answer compares scalar by scalar, as Kotlin's `==` compares code units: Swift's `==` takes a composed and a
    /// decomposed accent as equal, and the key's NFKC step is what the case is there to pin.
    @Test(arguments: NameKeyVectors.file.cases.indices)
    func everyCaseMatches(index: Int) {
        let entry = Self.file.cases[index]
        let label = Comment(rawValue: entry.label)
        #expect(scalars(NameKey.of(entry.input)) == scalars(entry.key), label)
        #expect(NameKey.isBlankName(entry.input) == entry.displayBlank, label)
        #expect(scalars(TextLimits.cleanReceived(entry.input, limit: Self.file.limits.displayName)) == scalars(entry.cleanedName), label)
        #expect(scalars(TextLimits.cleanReceived(entry.input, limit: Self.file.limits.status)) == scalars(entry.cleanedStatus), label)
    }

    private func scalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }
}
