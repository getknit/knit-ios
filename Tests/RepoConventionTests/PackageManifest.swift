import Foundation
import Testing

/// `Package.swift` read as text, for the conventions that hold the app's dependency closure (`KnitPeerIsolationTests`,
/// `SpoolNetIsolationTests`), and the Swift files under a directory.
enum PackageManifest {
    /// Each target in `Package.swift` and the targets it names as dependencies. Read from the manifest's text: a
    /// `.target`, `.executableTarget`, `.testTarget` or `.systemLibrary` call, its `name`, and the quoted names in its
    /// `dependencies` list, where a `.product(…)` is another package's and is skipped. A dependency held in a variable
    /// (`crypto`, `dbus`) names a product or a system library, neither of which reaches `KnitPeer` or `KnitSpoolNet`. Comment lines are
    /// dropped first.
    static func targets() throws -> [String: Set<String>] {
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

    /// Every target `name` reaches through `targets`, itself included.
    static func closure(of name: String, in targets: [String: Set<String>]) -> Set<String> {
        var closure: Set<String> = []
        var queue = [name]
        while let next = queue.popLast() {
            guard closure.insert(next).inserted else {
                continue
            }
            queue += targets[next, default: []]
        }
        return closure
    }

    /// The repository-relative paths of the Swift files under `directory`, sorted.
    static func swiftFiles(under directory: URL) throws -> [String] {
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
