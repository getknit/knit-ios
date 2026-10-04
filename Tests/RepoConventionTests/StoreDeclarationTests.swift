import Foundation
import Testing

/// What the store build declares about itself (ADR 2026-10.8cy5). `App/PrivacyInfo.xcprivacy` gives a reason for every
/// required-reason API the shipped code calls, and declares none it does not, since App Store Connect refuses an upload
/// that calls one undeclared. `App/Info.plist` answers the export-compliance question, so an upload need not ask.
/// `scripts/check.sh release` checks that both reach the built app.
@Suite struct StoreDeclarationTests {
    /// Apple's required-reason categories, each with the calls in it that Swift here could make.
    private static let categories: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            "creationDate", "creationDateKey", "modificationDate", "fileModificationDate", "contentModificationDateKey",
            "getattrlist", "getattrlistbulk", "fgetattrlist", "stat", "fstat", "fstatat", "lstat",
        ],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacity", "volumeAvailableCapacityKey", "volumeAvailableCapacityForImportantUsageKey",
            "volumeAvailableCapacityForOpportunisticUsageKey", "volumeTotalCapacityKey", "systemFreeSize", "systemSize",
            "statfs", "statvfs", "fstatfs", "fstatvfs",
        ],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
    ]

    /// Code that never reaches the store build: the Linux peer and its radio, and a debug build's bridge.
    private static let unshipped = [
        "Sources/CBluetoothShim", "Sources/CDBus", "Sources/KnitBlueZ", "Sources/KnitPeer", "Sources/knit-peer",
        "Sources/Knit/Debug",
    ]

    @Test func theManifestGivesAReasonForEveryRequiredReasonAPITheAppCalls() throws {
        let declared = try manifest().accessed
        let named = Set(declared.map(\.category))
        let called = try calledCategories()
        #expect(called.subtracting(named).isEmpty, "called with no reason declared: \(called.subtracting(named).sorted())")
        #expect(named.subtracting(called).isEmpty, "declared but never called: \(named.subtracting(called).sorted())")
        #expect(declared.allSatisfy { !$0.reasons.isEmpty }, "a category with no reason")
    }

    /// Messages go from phone to phone and never reach us, so there is nothing to declare as collected.
    @Test func theManifestTracksAndCollectsNothing() throws {
        let manifest = try manifest()
        #expect(!manifest.tracking)
        #expect(manifest.trackingDomains.isEmpty)
        #expect(manifest.collected.isEmpty)
    }

    /// Knit seals messages with its own encryption, beyond what iOS does for it, so it does not take the exempt answer.
    @Test func theExportAnswerSaysKnitUsesItsOwnEncryption() throws {
        let answer = try PropertyListDecoder().decode(ExportAnswer.self, from: try RepoFiles.data("App/Info.plist"))
        #expect(answer.usesNonExemptEncryption)
    }

    private func manifest() throws -> PrivacyManifest {
        try PropertyListDecoder().decode(PrivacyManifest.self, from: try RepoFiles.data("App/PrivacyInfo.xcprivacy"))
    }

    /// The categories whose calls appear in the shipped sources, outside comments.
    private func calledCategories() throws -> Set<String> {
        // Simple word boundaries: Unicode's would read `UserDefaults.standard` as one word.
        let calls = try Self.categories.mapValues { names in
            try Regex("\\b(\(names.joined(separator: "|")))\\b").wordBoundaryKind(.simple)
        }
        var called = Set<String>()
        for file in try shippedSources() {
            for line in try RepoFiles.text(file).split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                for (category, call) in calls where code.contains(call) {
                    called.insert(category)
                }
            }
        }
        return called
    }

    /// Every Swift and C file under `Sources/` that the app compiles, as repository paths.
    private func shippedSources() throws -> [String] {
        let sources = RepoFiles.root.appendingPathComponent("Sources")
        guard let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let prefix = RepoFiles.root.standardizedFileURL.path + "/"
        return walk.compactMap { $0 as? URL }
            .filter { ["swift", "c", "h"].contains($0.pathExtension) }
            .map { String($0.standardizedFileURL.path.dropFirst(prefix.count)) }
            .filter { path in !Self.unshipped.contains { path.hasPrefix($0 + "/") } }
    }
}

/// `App/PrivacyInfo.xcprivacy`, as far as the tests read it.
private struct PrivacyManifest: Decodable {
    let tracking: Bool
    let trackingDomains: [String]
    let collected: [CollectedData]
    let accessed: [APIAccess]

    enum CodingKeys: String, CodingKey {
        case tracking = "NSPrivacyTracking"
        case trackingDomains = "NSPrivacyTrackingDomains"
        case collected = "NSPrivacyCollectedDataTypes"
        case accessed = "NSPrivacyAccessedAPITypes"
    }
}

/// One required-reason category the manifest declares, and its reasons.
private struct APIAccess: Decodable {
    let category: String
    let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case category = "NSPrivacyAccessedAPIType"
        case reasons = "NSPrivacyAccessedAPITypeReasons"
    }
}

/// One kind of data the manifest says the app collects.
private struct CollectedData: Decodable {
    let type: String

    enum CodingKeys: String, CodingKey {
        case type = "NSPrivacyCollectedDataType"
    }
}

/// `App/Info.plist`'s export-compliance answer, which must be there.
private struct ExportAnswer: Decodable {
    let usesNonExemptEncryption: Bool

    enum CodingKeys: String, CodingKey {
        case usesNonExemptEncryption = "ITSAppUsesNonExemptEncryption"
    }
}
