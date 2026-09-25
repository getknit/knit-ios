import KnitCrypto
import Testing

/// The device tag, ported from knit-next's `DeviceTagTest`, plus a golden computed in Python.
@Suite struct DeviceTagTests {
    @Test func theTagIsTheSaltedDigestsFirstEightBytes() {
        #expect(DeviceTag.derive("android-id-123") == "4ae8c496d608c50a")
    }

    @Test func tagsAreStableSixteenHexDigits() {
        for seed in 0..<500 {
            let tag = DeviceTag.derive("android-id-\(seed)")
            #expect(tag == DeviceTag.derive("android-id-\(seed)"))
            #expect(tag?.count == 16)
            #expect(tag?.allSatisfy { $0.isHexDigit && !$0.isUppercase } == true)
        }
    }

    @Test func aMissingOrBlankIdHasNoTag() {
        #expect(DeviceTag.derive(nil) == nil)
        #expect(DeviceTag.derive("") == nil)
        #expect(DeviceTag.derive("   ") == nil)
    }

    @Test func distinctIdsGiveDistinctTagsAndNeverTheRawId() {
        let tags = Set((1...5000).compactMap { DeviceTag.derive("device-\($0)") })
        #expect(tags.count == 5000)
        #expect(DeviceTag.derive("9774d56d682e549c") != "9774d56d682e549c")
    }
}
