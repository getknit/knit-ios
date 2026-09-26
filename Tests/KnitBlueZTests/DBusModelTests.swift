import Testing

@testable import KnitBlueZ

/// Signatures, values and names, checked before anything reaches libdbus, which aborts on a malformed one.
@Suite struct DBusModelTests {
    // MARK: Types

    @Test(arguments: [
        "y", "b", "n", "q", "i", "u", "x", "t", "d", "s", "o", "g", "v", "ay", "as", "a{sv}", "a{oa{sa{sv}}}", "(ss)", "a(yv)",
    ])
    func aCompleteSignatureRoundTrips(_ signature: String) throws {
        #expect(try #require(DBusType(signature: signature)).signature == signature)
    }

    @Test(arguments: ["", "a", "a{", "a{vs}", "a{ss", "()", "(s", "z", "ss", "{ss}", "a{s}"])
    func aMalformedSignatureIsRefused(_ signature: String) {
        #expect(DBusType(signature: signature) == nil)
    }

    @Test func nestingPastTheLimitIsRefused() {
        #expect(DBusType(signature: String(repeating: "a", count: 63) + "y") != nil)
        #expect(DBusType(signature: String(repeating: "a", count: 64) + "y") == nil)
    }

    @Test func onlyBasicTypesAreBasic() {
        #expect(DBusType.string.isBasic)
        #expect(DBusType.objectPath.isBasic)
        #expect(!DBusType.variant.isBasic)
        #expect(!DBusType.array(.byte).isBasic)
        #expect(!DBusType.structure([.string]).isBasic)
    }

    // MARK: Values

    @Test func valuesKnowTheirTypes() {
        let values: [(DBusValue, String)] = [
            (.byte(1), "y"), (.boolean(true), "b"), (.int16(1), "n"), (.uint16(1), "q"), (.int32(1), "i"), (.uint32(1), "u"),
            (.int64(1), "x"), (.uint64(1), "t"), (.double(1), "d"), (.string("a"), "s"), (.objectPath("/"), "o"),
            (.signature("s"), "g"), (.bytes([1]), "ay"), (.strings(["a"]), "as"), (.properties([]), "a{sv}"),
            (.variant(.string("a")), "v"), (.structure([.string("a"), .int32(1)]), "(si)"),
        ]
        for (value, signature) in values {
            #expect(value.type.signature == signature)
            #expect(value.isWellFormed)
        }
    }

    @Test func malformedValuesAreCaughtBeforeLibdbusSeesThem() {
        #expect(!DBusValue.string("a\u{0}b").isWellFormed)
        #expect(!DBusValue.objectPath("no/slash").isWellFormed)
        #expect(!DBusValue.objectPath("/trailing/").isWellFormed)
        #expect(!DBusValue.signature("a{").isWellFormed)
        #expect(!DBusValue.array(.string, [.int32(1)]).isWellFormed)
        #expect(!DBusValue.array(.byte, [.byte(1)]).isWellFormed, "bytes travel as .bytes")
        #expect(!DBusValue.dictionary(key: .variant, value: .string, []).isWellFormed)
        #expect(!DBusValue.dictionary(key: .string, value: .string, [DBusEntry(key: .int32(1), value: .string("a"))]).isWellFormed)
        #expect(!DBusValue.dictionary(key: .string, value: .string, [DBusEntry(key: .string("\u{0}"), value: .string("a"))]).isWellFormed)
        #expect(!DBusValue.variant(.string("\u{0}")).isWellFormed)
        #expect(!DBusValue.structure([]).isWellFormed)
        #expect(!DBusValue.structure([.objectPath("x")]).isWellFormed)
    }

    @Test func valuesNestedPastTheLimitAreMalformed() {
        var value = DBusValue.string("deep")
        for _ in 0..<70 {
            value = .variant(value)
        }
        #expect(!value.isWellFormed)
    }

    @Test func readingLooksThroughVariants() {
        let properties = DBusValue.properties([
            ("Name", .string("x")), ("On", .boolean(true)), ("Level", .uint16(7)), ("Data", .bytes([1, 2])),
            ("Paths", .array(.objectPath, [.objectPath("/a")])),
        ])
        #expect(properties["Name"]?.text == "x")
        #expect(properties["On"]?.bool == true)
        #expect(properties["Level"]?.integer == 7)
        #expect(properties["Data"]?.byteArray == [1, 2])
        #expect(properties["Paths"]?.textArray == ["/a"])
        #expect(properties["Missing"] == nil)
        #expect(properties.textKeyed?.map(\.key) == ["Name", "On", "Level", "Data", "Paths"])
    }

    @Test func readingTheWrongShapeAnswersNothing() {
        #expect(DBusValue.int32(1).text == nil)
        #expect(DBusValue.string("x").bool == nil)
        #expect(DBusValue.string("x").integer == nil)
        #expect(DBusValue.uint64(.max).integer == nil)
        #expect(DBusValue.string("x").byteArray == nil)
        #expect(DBusValue.string("x").textArray == nil)
        #expect(DBusValue.array(.int32, [.int32(1)]).textArray == nil)
        #expect(DBusValue.string("x").textKeyed == nil)
        #expect(DBusValue.dictionary(key: .int32, value: .string, [DBusEntry(key: .int32(1), value: .string("a"))]).textKeyed == nil)
        #expect(DBusValue.string("x")["key"] == nil)
    }

    @Test func everyIntegerWidens() {
        let integers: [DBusValue] = [.byte(1), .int16(-1), .uint16(1), .int32(-1), .uint32(1), .int64(-1), .uint64(1)]
        #expect(integers.compactMap(\.integer) == [1, -1, 1, -1, 1, -1, 1])
    }

    // MARK: Names

    @Test func objectPathsFollowTheSpecification() {
        for path in ["/", "/org/bluez/hci1", "/org/bluez/hci1/dev_4A_00_00_00_00_EF", "/a_1"] {
            #expect(DBusNames.isObjectPath(path), "\(path)")
        }
        for path in ["", "org", "//", "/a/", "/a//b", "/a-b", "/é"] {
            #expect(!DBusNames.isObjectPath(path), "\(path)")
        }
    }

    @Test func interfacesMembersAndErrorsFollowTheSpecification() {
        #expect(DBusNames.isInterface("org.bluez.Adapter1"))
        #expect(!DBusNames.isInterface("bluez"))
        #expect(!DBusNames.isInterface("org..bluez"))
        #expect(!DBusNames.isInterface("org.1bluez"))
        #expect(!DBusNames.isInterface(String(repeating: "a.", count: 128) + "a"))
        #expect(DBusNames.isErrorName("org.bluez.Error.Failed"))
        #expect(DBusNames.isMember("GetManagedObjects"))
        #expect(!DBusNames.isMember("Get.All"))
        #expect(!DBusNames.isMember("1st"))
        #expect(!DBusNames.isMember(""))
    }

    @Test func busNamesAreUniqueOrWellKnown() {
        #expect(DBusNames.isBusName("org.bluez"))
        #expect(DBusNames.isBusName(":1.42"))
        #expect(DBusNames.isBusName("org.example-app.x"))
        #expect(!DBusNames.isBusName("org"))
        #expect(!DBusNames.isBusName("1org.bluez"))
        #expect(!DBusNames.isBusName("org.b!uez"))
        #expect(!DBusNames.isBusName(String(repeating: "a", count: 300) + ".b"))
    }

    @Test func signaturesMayHoldSeveralTypes() {
        #expect(DBusNames.isSignature(""))
        #expect(DBusNames.isSignature("sa{sv}as"))
        #expect(!DBusNames.isSignature("sa{"))
        #expect(!DBusNames.isSignature(String(repeating: "s", count: 256)))
    }
}
