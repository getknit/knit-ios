import Foundation
import KnitMesh
import Testing

@testable import KnitAppCore

/// The catalog: one place for every string, each key once, and the copies outside Swift kept equal to it.
@Suite struct CopyTests {
    /// The repository root, found by walking up from this file to `Package.swift`.
    static let root: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            directory.deleteLastPathComponent()
        }
        return directory
    }()

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theProductNameIsNeverTranslated() {
        #expect(Copy.productName == "Knit")
    }

    @Test func everyKeyInTheCatalogIsUsedOnce() throws {
        let directory = Self.root.appendingPathComponent("Sources/KnitAppCore/Copy")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        var keys: [String] = []
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let pattern = try NSRegularExpression(pattern: #"NSLocalizedString\(\s*"([^"]+)""#)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                if let key = Range(match.range(at: 1), in: source) {
                    keys.append(String(source[key]))
                }
            }
        }
        #expect(keys.count > 150, "the catalog was read")
        let repeated = Dictionary(grouping: keys, by: \.self).filter { $0.value.count > 1 }.keys.sorted()
        #expect(repeated.isEmpty, "a key the String Catalog would collapse: \(repeated)")
    }

    @Test func noViewTextLivesOutsideTheCatalog() throws {
        let sources = Self.root.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(atPath: sources.path)
        var outside: [String] = []
        while let path = enumerator?.nextObject() as? String {
            guard path.hasSuffix(".swift"), !path.hasPrefix("KnitAppCore/Copy/") else {
                continue
            }
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            if source.contains("NSLocalizedString(") || source.contains("String(localized:") {
                outside.append(path)
            }
        }
        #expect(outside.isEmpty, "localized text outside KnitAppCore/Copy: \(outside)")
    }

    @Test func noViewHandsALiteralToAView() throws {
        // A literal given to Text, Button and the rest is a LocalizedStringKey: text outside the catalog.
        let views = Self.root.appendingPathComponent("Sources/Knit")
        let pattern = try NSRegularExpression(
            pattern: #"\b(Text|Button|Label|TextField|Toggle|Section|NavigationLink|Link|LabeledContent|navigationTitle)\(""#
        )
        let enumerator = FileManager.default.enumerator(atPath: views.path)
        var literals: [String] = []
        while let path = enumerator?.nextObject() as? String {
            guard path.hasSuffix(".swift") else {
                continue
            }
            let source = try String(contentsOf: views.appendingPathComponent(path), encoding: .utf8)
            let count = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            if count > 0 {
                literals.append("\(path) (\(count))")
            }
        }
        #expect(literals.isEmpty, "view text that skips the catalog: \(literals)")
    }

    @Test func infoPlistAsksForBluetoothInTheCatalogsWords() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("App/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSBluetoothAlwaysUsageDescription"] as? String == Copy.System.bluetoothUsage)
    }

    @Test func aboutListsWhatTheNoticesFileShips() throws {
        let notices = try Self.text("THIRD-PARTY-NOTICES.md")
        let shipped = try #require(notices.components(separatedBy: "## Shipped in the app").last?.components(separatedBy: "\n## ").first)
        let rows = shipped.split(separator: "\n").filter { $0.hasPrefix("| `") }
        let ids = rows.compactMap { $0.split(separator: "`").dropFirst().first.map(String.init) }
        #expect(ids.sorted() == ThirdPartyNotice.shipped.map(\.id).sorted())
        for notice in ThirdPartyNotice.shipped {
            let row = rows.first { $0.contains("`\(notice.id)`") }
            #expect(row?.contains(notice.license) == true, "\(notice.id) is \(notice.license) in both")
            #expect(row?.contains(notice.url) == true)
        }
    }

    @Test func countsTakeTheirSingularOnlyForOne() {
        #expect(Copy.Status.linked(1) == "Connected to 1 nearby device")
        #expect(Copy.Status.linked(3) == "Connected to 3 nearby devices")
        #expect(Copy.Status.linked(0) == "Connected to 0 nearby devices")
        #expect(Copy.Chat.remaining(1) == "1 character left")
        #expect(Copy.Notifications.requestBody(2) == "2 people want to message you")
        #expect(Copy.ChatList.requestCount(1) == "1 request waiting")
    }

    @Test func formatsFillEveryPlaceholderInOrder() {
        #expect(Copy.ChatList.preview(speaker: "Sam", body: "hi") == "Sam: hi")
        #expect(Copy.Notifications.roomBody(sender: "Sam", body: "hi") == "Sam: hi")
        #expect(Copy.Onboarding.step(1, of: 2) == "Step 1 of 2")
        #expect(Copy.About.version("0.1.0", build: "7") == "Version 0.1.0 (7)")
        #expect(Copy.Diagnostics.sighting(rssi: -67, secondsAgo: 3) == "-67 dBm, 3 s ago")
        #expect(Copy.Diagnostics.link(version: 3, capabilities: "9") == "v3, caps 9")
        #expect(Copy.Onboarding.nameBody(alias: "OptimallyArtfulFox").contains("OptimallyArtfulFox"))
        #expect(Copy.Chat.encryptionBody("Sam").hasPrefix("Only you and Sam"))
        #expect(Copy.Profile.safetyNumberCaption("Sam").contains("Sam"))
        #expect(Copy.TestIdentity.minted("abc").contains("abc"))
        #expect(Copy.Onboarding.allowLabel("Bluetooth") == "Allow, Bluetooth")
    }

    @Test func aWrappedStringReadsAsOneLine() {
        #expect(!Copy.Chat.encryptionBody("Sam").contains("\n"))
        #expect(!Copy.About.security.contains("\n"))
        #expect(!Copy.System.bluetoothUsage.contains("  "))
    }

    @Test func everyRadioStateAndDropReasonHasWords() {
        let states: [RadioState?] = [nil, .on, .off, .unauthorized, .unsupported]
        #expect(Set(states.map(Copy.Diagnostics.radio)).count == states.count)
        #expect(Set(DropReason.allCases.map(Copy.Drops.reason)).count == DropReason.allCases.count)
    }
}
