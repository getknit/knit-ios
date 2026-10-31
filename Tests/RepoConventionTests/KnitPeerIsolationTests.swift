import Foundation
import Testing

/// knit-peer's lies stay out of the app by construction (`door-cap-lying-peers`): `KnitPeer`, where every trial switch
/// lives, is in no target the `Knit` library links, only `knit-peer` and its tests depend on it, nothing else under
/// `Sources/` imports it, and the control surface the app's debug bridge speaks names none of the lying commands.
@Suite struct KnitPeerIsolationTests {
    /// The lying commands, answered by `PeerNode` alone.
    private static let lyingCommands = ["lie-blobhas", "junk", "advertise-photo", "pad-profile", "ask-blob"]

    /// Each target in `Package.swift` and the targets it names as dependencies. Read from the manifest's text: a
    /// `.target`, `.executableTarget`, `.testTarget` or `.systemLibrary` call, its `name`, and the quoted names in its
    /// `dependencies` list, where a `.product(…)` is another package's and is skipped. A dependency held in a variable
    /// (`crypto`, `dbus`) names a product or a system library, neither of which reaches `KnitPeer`. Comment lines are
    /// dropped first.
    private static func targets() throws -> [String: Set<String>] {
        // Comment lines go first: a quote in one would read as a name.
        let manifest = try RepoFiles.text("Package.swift").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        var targets: [String: Set<String>] = [:]
        var index = manifest.startIndex
        while let start = nextTarget(in: manifest, from: index) {
            let call = balanced(manifest, from: manifest.index(before: start.upperBound), open: "(", close: ")")
            index = call.upperBound
            // A `.target(name:condition:)` inside a dependency list is a dependency, read with its list.
            guard let name = firstQuoted(after: "name:", in: manifest[call]), targets[name] == nil else {
                continue
            }
            var dependencies: Set<String> = []
            if let list = manifest[call].range(of: "dependencies:") {
                let open = try #require(manifest[list.upperBound...].firstIndex(of: "["))
                var text = String(manifest[balanced(manifest, from: open, open: "[", close: "]")])
                while let product = text.range(of: ".product(") {
                    let skipped = balanced(text, from: text.index(before: product.upperBound), open: "(", close: ")")
                    text.removeSubrange(product.lowerBound..<skipped.upperBound)
                }
                dependencies = Set(quoted(in: text))
            }
            targets[name] = dependencies
        }
        return targets
    }

    @Test func theAppLinksNothingFromKnitPeer() throws {
        let targets = try Self.targets()
        var closure: Set<String> = []
        var queue = ["Knit"]
        while let name = queue.popLast() {
            guard closure.insert(name).inserted else {
                continue
            }
            queue += targets[name, default: []]
        }
        // The walk reached what the app is known to link, so its absence below means something.
        #expect(closure.isSuperset(of: ["Knit", "KnitBLE", "KnitControl", "KnitMesh", "KnitStoreSQL", "KnitSync", "KnitWire"]))
        #expect(!closure.contains("KnitPeer"), "the Knit library links KnitPeer through \(closure.sorted())")
        #expect(!closure.contains("knit-peer"))
    }

    @Test func onlyKnitPeerAndItsTestsDependOnKnitPeer() throws {
        let targets = try Self.targets()
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
        for path in try swiftFiles(under: sources) where !allowed.contains(where: path.hasPrefix) {
            let text = try RepoFiles.text(path)
            if text.components(separatedBy: "\n").contains(where: { $0.contains(pattern) }) {
                importers.append(path)
            }
        }
        #expect(importers.isEmpty, "imports KnitPeer: \(importers)")
        #expect(try swiftFiles(under: sources).contains("Sources/knit-peer/KnitPeerMain.swift"), "the walk found the sources")
    }

    @Test func theControlSurfaceNamesNoLyingCommand() throws {
        let control = try swiftFiles(under: RepoFiles.root.appendingPathComponent("Sources/KnitControl"))
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

    // MARK: Reading

    /// The repository-relative paths of the Swift files under `directory`, sorted.
    private func swiftFiles(under directory: URL) throws -> [String] {
        let root = RepoFiles.root.standardizedFileURL.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .map { String($0.standardizedFileURL.path.dropFirst(root.count)) }.sorted()
    }

    /// Where the next target's call starts in `text` from `index`, its opening bracket last.
    private static func nextTarget(in text: String, from index: String.Index) -> Range<String.Index>? {
        let calls = [".target(", ".executableTarget(", ".testTarget(", ".systemLibrary("]
        return calls.compactMap { text.range(of: $0, range: index..<text.endIndex) }.min { $0.lowerBound < $1.lowerBound }
    }

    /// The range from the bracket at `start` to its match, both included.
    private static func balanced(_ text: String, from start: String.Index, open: Character, close: Character) -> Range<String.Index> {
        var depth = 0
        var index = start
        var inString = false
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                inString.toggle()
            } else if !inString, character == open {
                depth += 1
            } else if !inString, character == close {
                depth -= 1
                if depth == 0 {
                    return start..<text.index(after: index)
                }
            }
            index = text.index(after: index)
        }
        return start..<text.endIndex
    }

    /// The string literals in `text`, in order.
    private static func quoted(in text: String) -> [String] {
        text.split(separator: "\"", omittingEmptySubsequences: false).enumerated().compactMap { part in
            part.offset % 2 == 1 ? String(part.element) : nil
        }
    }

    /// The first string literal after `label` in `text`.
    private static func firstQuoted(after label: String, in text: Substring) -> String? {
        guard let found = text.range(of: label) else {
            return nil
        }
        return quoted(in: String(text[found.upperBound...])).first
    }
}
