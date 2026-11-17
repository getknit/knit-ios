import Foundation
import Testing

/// knit-peer's lies stay out of the app by construction (`door-cap-lying-peers`): `KnitPeer`, where every trial switch
/// lives, is in no target the `Knit` library links, only `knit-peer` and its tests depend on it, nothing else under
/// `Sources/` imports it, and the control surface the app's debug bridge speaks names none of the lying commands.
@Suite struct KnitPeerIsolationTests {
    /// The lying commands, answered by `PeerNode` alone.
    private static let lyingCommands = ["lie-blobhas", "junk", "advertise-photo", "pad-profile", "ask-blob"]

    @Test func theAppLinksNothingFromKnitPeer() throws {
        let targets = try PackageManifest.targets()
        let closure = PackageManifest.closure(of: "Knit", in: targets)
        // The walk reached what the app is known to link, so its absence below means something.
        #expect(closure.isSuperset(of: ["Knit", "KnitBLE", "KnitControl", "KnitMesh", "KnitStoreSQL", "KnitSync", "KnitWire"]))
        #expect(!closure.contains("KnitPeer"), "the Knit library links KnitPeer through \(closure.sorted())")
        #expect(!closure.contains("knit-peer"))
    }

    @Test func onlyKnitPeerAndItsTestsDependOnKnitPeer() throws {
        let targets = try PackageManifest.targets()
        #expect(targets["KnitPeer"] != nil && targets["knit-peer"]?.contains("KnitPeer") == true, "the manifest was read")
        let dependents = Set(targets.filter { $0.value.contains("KnitPeer") }.keys)
        #expect(dependents == ["knit-peer", "KnitPeerTests"])
        let manifest = try RepoFiles.text("Package.swift")
        let products = manifest.components(separatedBy: "\n").filter { $0.contains(".library(") || $0.contains(".executable(") }
        #expect(!products.isEmpty && products.allSatisfy { !$0.contains(#""KnitPeer""#) }, "no product exports KnitPeer")
    }

    @Test func nothingElseUnderSourcesImportsKnitPeer() throws {
        let sources = RepoFiles.root.appendingPathComponent("Sources")
        let allowed = ["Sources/KnitPeer/", "Sources/knit-peer/"]
        // An import of the module or of a declaration in it, with any attribute and access level in front.
        let attributes = #"^\s*(@[A-Za-z_]+(\([^)]*\))?\s+)*((public|package|internal|private|fileprivate)\s+)?"#
        let pattern = try Regex(attributes + #"import\s+((struct|class|enum|protocol|func|var|let)\s+)?KnitPeer\b"#)
        var importers: [String] = []
        for path in try PackageManifest.swiftFiles(under: sources) where !allowed.contains(where: path.hasPrefix) {
            let text = try RepoFiles.text(path)
            if text.components(separatedBy: "\n").contains(where: { $0.contains(pattern) }) {
                importers.append(path)
            }
        }
        #expect(importers.isEmpty, "imports KnitPeer: \(importers)")
        #expect(
            try PackageManifest.swiftFiles(under: sources).contains("Sources/knit-peer/KnitPeerMain.swift"), "the walk found the sources")
    }

    @Test func theControlSurfaceNamesNoLyingCommand() throws {
        let control = try PackageManifest.swiftFiles(under: RepoFiles.root.appendingPathComponent("Sources/KnitControl"))
        #expect(!control.isEmpty)
        for path in control {
            let text = try RepoFiles.text(path)
            for command in Self.lyingCommands {
                #expect(!text.contains(#""\#(command)""#), "\(path) names \(command)")
            }
            for command in Self.lyingCommands where command.contains("-") {
                #expect(!text.contains(command), "\(path) names \(command)")
            }
        }
    }
}
