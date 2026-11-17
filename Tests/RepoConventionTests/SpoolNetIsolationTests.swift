import Foundation
import Testing

/// The spool's socket stays out of the app until the app's phase (ADR 2026-11.adrq, P5; P6 wires it): `KnitSpoolNet` is in
/// no target the `Knit` library links and in no product, only its own tests depend on it, every file of it is a debug
/// build's alone, the release gate looks for the line its factory logs, and nothing under `Sources/` names the test socket
/// or the stub server.
@Suite struct SpoolNetIsolationTests {
    /// What only tests may name: the daemon suite's socket and raw connection, and the adapter suite's stub.
    private static let testOnly = ["SpoolTestSocket", "SpoolTestTCP", "SpoolDaemonLine", "StubServer", "Loopback"]
    /// The line `URLSessionSpoolSocketFactory` logs as it is made.
    private static let marker = "spool sockets are on in this debug build"

    @Test func theAppLinksNoSpoolSocketYet() throws {
        let targets = try PackageManifest.targets()
        let closure = PackageManifest.closure(of: "Knit", in: targets)
        #expect(closure.isSuperset(of: ["Knit", "KnitMesh", "KnitWire"]), "the walk reached what the app links")
        #expect(!closure.contains("KnitSpoolNet"), "the Knit library links KnitSpoolNet through \(closure.sorted())")
    }

    @Test func onlyItsTestsDependOnKnitSpoolNetAndNoProductExportsIt() throws {
        let targets = try PackageManifest.targets()
        #expect(targets["KnitSpoolNet"] != nil, "the manifest was read")
        let dependents = Set(targets.filter { $0.value.contains("KnitSpoolNet") }.keys)
        #expect(dependents == ["KnitSpoolNetTests"])
        let products = try RepoFiles.text("Package.swift").components(separatedBy: "\n").filter { line in
            line.contains(".library(") || line.contains(".executable(")
        }
        #expect(!products.isEmpty && products.allSatisfy { !$0.contains(#""KnitSpoolNet""#) }, "no product exports KnitSpoolNet")
    }

    @Test func everyFileOfKnitSpoolNetIsADebugBuildsAlone() throws {
        let files = try PackageManifest.swiftFiles(under: RepoFiles.root.appendingPathComponent("Sources/KnitSpoolNet"))
        #expect(!files.isEmpty)
        for path in files {
            let code = try RepoFiles.text(path).components(separatedBy: "\n").first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("//")
            }
            #expect(code?.hasPrefix("#if DEBUG") == true, "\(path) opens with \(code ?? "nothing") rather than #if DEBUG")
        }
    }

    @Test func theReleaseGateLooksForTheFactorysMarker() throws {
        let factory = try RepoFiles.text("Sources/KnitSpoolNet/URLSessionSpoolSocketFactory.swift")
        #expect(factory.contains("\"\(Self.marker)\""), "the factory logs the marker")
        let gate = try RepoFiles.text("scripts/check.sh")
        let release = try #require(gate.range(of: "check_release_app() {"))
        #expect(gate[release.upperBound...].contains("\"\(Self.marker)\""), "check_release_app greps a store build for it")
    }

    @Test func nothingUnderSourcesNamesTheTestSocketOrTheStub() throws {
        let sources = try PackageManifest.swiftFiles(under: RepoFiles.root.appendingPathComponent("Sources"))
        #expect(sources.contains("Sources/KnitSpoolNet/URLSessionSpoolSocketFactory.swift"), "the walk found the sources")
        for path in sources {
            let text = try RepoFiles.text(path)
            for name in Self.testOnly {
                #expect(!text.contains(name), "\(path) names \(name)")
            }
        }
    }
}
