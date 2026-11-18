import Foundation
import Testing

/// The spool's socket and the relay settings reach a debug build alone (ADR 2026-11.adrq, P5 and P6): `KnitSpoolNet` is linked
/// by the `Knit` target and its own tests alone and exported by no product, every file of it is a debug build's, the app's
/// one import of it and its one composition line sit inside `#if DEBUG`, every relay path in the app does too, the release
/// gate looks for each debug-only marker, and nothing under `Sources/` names the test socket or the stub server.
@Suite struct SpoolNetIsolationTests {
    /// What only tests may name: the daemon suite's socket and raw connection, and the adapter suite's stub.
    private static let testOnly = ["SpoolTestSocket", "SpoolTestTCP", "SpoolDaemonLine", "StubServer", "Loopback"]
    /// The strings only debug code holds, each with the one file that holds it, which `check_release_app` greps a store build
    /// for: the factory's line, the relay settings' composition line, an opened invite's line, the relay list's defaults key
    /// and the relay addresses' Keychain service.
    private static let markers = [
        ("spool sockets are on in this debug build", "Sources/KnitSpoolNet/URLSessionSpoolSocketFactory.swift"),
        ("internet relays are on in this debug build", "Sources/Knit/App/AppEnvironment+Relays.swift"),
        ("a relay invite opened in this debug build", "Sources/Knit/App/Launch.swift"),
        ("debug.spool.relays", "Sources/Knit/Platform/DefaultsPreferences.swift"),
        ("app.getknit.knit.spool-relay", "Sources/Knit/Platform/KeychainRelayStore.swift"),
    ]
    /// What in the app reaches relays: each line naming one must sit inside `#if DEBUG`.
    private static let debugOnlyNames = [
        "import KnitSpoolNet", "URLSessionSpoolSocketFactory", "InternetRelaySection(", ".relayPrompts(", "requestedRelayInvite = ",
        "startRelays(", "spoolSockets(log:", "KeychainRelayStore(", "RelayIntake.isInviteLink",
    ]

    @Test func onlyTheAppTargetAndItsOwnTestsLinkKnitSpoolNetAndNoProductExportsIt() throws {
        let targets = try PackageManifest.targets()
        #expect(targets["KnitSpoolNet"] != nil, "the manifest was read")
        let dependents = Set(targets.filter { $0.value.contains("KnitSpoolNet") }.keys)
        #expect(dependents == ["Knit", "KnitSpoolNetTests"])
        #expect(!PackageManifest.closure(of: "KnitAppCore", in: targets).contains("KnitSpoolNet"), "the platform-free app core never")
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

    /// Only a debug build reaches the factory: the app imports `KnitSpoolNet` and makes its factory in one place each, inside
    /// `#if DEBUG`, the line with link previews' `seam_url_loading` disable before it, and every other relay path in the app is
    /// a debug build's too.
    @Test func onlyADebugBuildReachesTheFactoryOrTheRelaySettings() throws {
        let files = try PackageManifest.swiftFiles(under: RepoFiles.root.appendingPathComponent("Sources/Knit"))
        var imports = 0
        var factories = 0
        for path in files {
            let lines = try RepoFiles.text(path).components(separatedBy: "\n")
            let debug = Self.debugOnly(lines)
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for name in Self.debugOnlyNames where line.contains(name) {
                    #expect(debug[index], "\(path):\(index + 1) names \(name) outside #if DEBUG")
                }
                imports += line.contains("import KnitSpoolNet") ? 1 : 0
                if line.contains("URLSessionSpoolSocketFactory(") {
                    factories += 1
                    #expect(index > 0 && lines[index - 1].contains("swiftlint:disable:next seam_url_loading"), "\(path):\(index + 1)")
                }
            }
        }
        #expect(imports == 1 && factories == 1, "one import and one composition line: \(imports), \(factories)")
    }

    @Test func theReleaseGateLooksForEveryMarkerAndOnlyItsFileHoldsIt() throws {
        let gate = try RepoFiles.text("scripts/check.sh")
        let release = try #require(gate.range(of: "check_release_app() {"))
        let sources = try PackageManifest.swiftFiles(under: RepoFiles.root.appendingPathComponent("Sources"))
        for (marker, home) in Self.markers {
            #expect(gate[release.upperBound...].contains(marker), "check_release_app greps a store build for \(marker)")
            #expect(marker.utf8.count > 15, "stored whole, not inside the instructions: \(marker)")
            let lines = try RepoFiles.text(home).components(separatedBy: "\n")
            let debug = Self.debugOnly(lines)
            let places = lines.indices.filter { lines[$0].contains("\"\(marker)\"") }
            #expect(!places.isEmpty && places.allSatisfy { debug[$0] }, "\(home) holds \(marker) inside #if DEBUG")
            for path in sources where path != home {
                #expect(try !RepoFiles.text(path).contains(marker), "\(path) holds \(marker), which a store build may carry")
            }
        }
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

    /// The reader itself: a line counts as debug-only inside an `#if DEBUG` branch, at any depth, and not in its `#else`.
    @Test func theConditionReaderFollowsNestingAndElse() {
        let lines = ["a", "#if os(iOS)", "b", "#if DEBUG", "c", "#if canImport(X)", "d", "#endif", "#else", "e", "#endif", "f", "#endif"]
        let debug = Self.debugOnly(lines)
        #expect(lines.indices.filter { debug[$0] }.map { lines[$0] } == ["c", "#if canImport(X)", "d", "#endif"])
    }

    /// For each line, whether it compiles only under `DEBUG`: inside an `#if DEBUG` branch, however deep, short of its `#else`.
    private static func debugOnly(_ lines: [String]) -> [Bool] {
        var stack: [Bool] = []
        return lines.map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                let inside = stack.contains(true)
                stack.append(line == "#if DEBUG")
                return inside
            }
            if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                if !stack.isEmpty {
                    stack[stack.count - 1] = false
                }
                return stack.contains(true)
            }
            if line.hasPrefix("#endif") {
                let inside = stack.contains(true)
                _ = stack.popLast()
                return inside
            }
            return stack.contains(true)
        }
    }
}
