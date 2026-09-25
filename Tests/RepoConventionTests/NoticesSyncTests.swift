import Foundation
import Testing

/// Every package SwiftPM resolves must be accounted for in `THIRD-PARTY-NOTICES.md`: either shipped (and so
/// its license travels with the app) or resolved-but-not-shipped, with the reason. A new dependency fails this
/// test until someone decides which it is. knit-next's `ReleaseClasspathNoticesTest` is the model.
@Suite struct NoticesSyncTests {
    @Test func everyResolvedPackageHasANoticesRow() throws {
        let pins = try resolvedIdentities()
        let rows = try noticeIdentities(in: ["## Shipped in the app", "## Resolved but not shipped"])
        #expect(pins.subtracting(rows).isEmpty, "Package.resolved pins with no notices row: \(pins.subtracting(rows).sorted())")
        #expect(rows.subtracting(pins).isEmpty, "notices rows for packages no longer resolved: \(rows.subtracting(pins).sorted())")
    }

    private struct Resolved: Decodable {
        struct Pin: Decodable { let identity: String }
        let pins: [Pin]
    }

    private func resolvedIdentities() throws -> Set<String> {
        let resolved = try JSONDecoder().decode(Resolved.self, from: try RepoFiles.data("Package.resolved"))
        return Set(resolved.pins.map(\.identity))
    }

    /// The first cell of each table row under the named `##` sections, taken as a SwiftPM package identity.
    private func noticeIdentities(in sections: Set<String>) throws -> Set<String> {
        var identities = Set<String>()
        var inSection = false
        for line in try RepoFiles.text("THIRD-PARTY-NOTICES.md").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                inSection = sections.contains(String(line))
                continue
            }
            guard inSection, line.hasPrefix("| ") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = cells.first, !first.isEmpty, first != "Package", !first.hasPrefix("---") else { continue }
            identities.insert(first.trimmingCharacters(in: CharacterSet(charactersIn: "`")))
        }
        return identities
    }
}
