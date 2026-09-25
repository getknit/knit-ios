import Foundation
import Testing

/// The fuzz package in Fuzz/ is a root package of its own, so SwiftPM resolves it from Fuzz/Package.resolved
/// and never from the main one. This keeps the two pinned to the same revisions, so a harness always fuzzes
/// the code the app ships.
@Suite struct FuzzPinsTests {
    @Test func fuzzPackageResolvesTheSameRevisions() throws {
        let main = try pins(in: "Package.resolved")
        let fuzz = try pins(in: "Fuzz/Package.resolved")
        #expect(fuzz == main)
    }

    private func pins(in path: String) throws -> [String: String] {
        let resolved = try JSONDecoder().decode(ResolvedFile.self, from: try RepoFiles.data(path))
        return Dictionary(uniqueKeysWithValues: resolved.pins.map { ($0.identity, $0.state.revision) })
    }
}

private struct ResolvedFile: Decodable {
    let pins: [ResolvedPin]
}

private struct ResolvedPin: Decodable {
    struct State: Decodable { let revision: String }
    let identity: String
    let state: State
}
