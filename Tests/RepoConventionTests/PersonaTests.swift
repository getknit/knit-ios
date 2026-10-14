import Foundation
import Testing

/// The owner and reviewer personas (ADR 2026-10.zjmx, `.agents/rules/owners.md`) work only while their pieces agree:
/// each persona is linked from `.claude/agents/` under its own name, each owner has a reviewer, each reviewer has one
/// line in the Stop hook's conf and cannot edit, and every path and ADR id a persona cites still exists. A catalogue
/// that names a file the code no longer has sends its next reader nowhere.
@Suite struct PersonaTests {
    private static let personas = ".agents/personas"
    private static let agents = ".claude/agents"
    private static let conf = ".claude/hooks/review-gate.conf"
    private static let owners = ".agents/rules/owners.md"

    @Test func everyPersonaIsNamedForItsFileAndLinkedForClaudeCode() throws {
        let names = try personaNames()
        #expect(!names.isEmpty)
        for name in names {
            let fields = try frontmatter(of: name)
            #expect(fields["name"] == name, "\(name).md declares name \(fields["name"] ?? "nothing")")
            for key in ["description", "tools", "model", "effort"] {
                #expect(fields[key] != nil, "\(name).md has no \(key)")
            }
            let link = RepoFiles.root.appendingPathComponent("\(Self.agents)/\(name).md").path
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link)
            #expect(target == "../../\(Self.personas)/\(name).md", "\(Self.agents)/\(name).md is not a link to it")
        }
        let linked = try FileManager.default.contentsOfDirectory(atPath: RepoFiles.root.appendingPathComponent(Self.agents).path)
        #expect(Set(linked) == Set(names.map { "\($0).md" }), "\(Self.agents) holds a link to no persona")
    }

    @Test func everyOwnerHasAReviewerAndEveryReviewerOneGateLine() throws {
        let names = Set(try personaNames())
        for owner in names where owner.hasSuffix("-owner") {
            let reviewer = owner.replacingOccurrences(of: "-owner", with: "-reviewer")
            #expect(names.contains(reviewer), "\(owner) has no \(reviewer)")
        }
        let gated = try gateLines().map(\.name)
        #expect(Set(gated).count == gated.count, "a reviewer has two lines in \(Self.conf)")
        #expect(Set(gated) == names.filter { $0.hasSuffix("-reviewer") }, "\(Self.conf) and the reviewers disagree")
    }

    @Test func theGateWatchesOnlyPathsThatExist() throws {
        for line in try gateLines() {
            #expect(line.followUp > 0, "\(line.name)'s follow-up is not a count of lines")
            for path in line.paths where !path.hasPrefix(":(") {
                #expect(exists(path), "\(line.name) gates \(path), which does not exist")
            }
        }
    }

    @Test func reviewersCannotEdit() throws {
        for name in try personaNames() where name.hasSuffix("-reviewer") {
            let tools = try frontmatter(of: name)["tools"] ?? ""
            let granted = Set(tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            #expect(granted.isDisjoint(with: ["Edit", "Write", "MultiEdit", "NotebookEdit"]), "\(name) can edit")
        }
    }

    @Test func theOwnersRuleNamesEveryPersona() throws {
        let rule = try RepoFiles.text(Self.owners)
        for name in try personaNames() {
            #expect(rule.contains("`\(name)`"), "\(Self.owners) never names \(name)")
        }
    }

    @Test func everyPathAPersonaCitesExists() throws {
        for (file, text) in try citingFiles() {
            for path in citedPaths(in: text) {
                #expect(exists(path), "\(file) cites \(path), which does not exist")
            }
        }
    }

    @Test func everyDecisionAPersonaCitesExists() throws {
        let decisions = try FileManager.default.contentsOfDirectory(
            atPath: RepoFiles.root.appendingPathComponent(".agents/memory/decisions").path
        )
        for (file, text) in try citingFiles() {
            for id in citedDecisions(in: text) {
                let prefix = id.replacingOccurrences(of: ".", with: "-") + "-"
                #expect(decisions.contains { $0.hasPrefix(prefix) }, "\(file) cites ADR \(id), which does not exist")
            }
        }
    }

    // MARK: - Reading the pieces

    private struct GateLine {
        let name: String
        let followUp: Int
        let paths: [String]
    }

    private func personaNames() throws -> [String] {
        let directory = RepoFiles.root.appendingPathComponent(Self.personas).path
        return try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(".md".count)) }
            .sorted()
    }

    /// The `key: value` lines between the opening `---` and the next. A folded value (`>-`) counts as present.
    private func frontmatter(of name: String) throws -> [String: String] {
        let lines = try RepoFiles.text("\(Self.personas)/\(name).md").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            return [:]
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] where !line.hasPrefix(" ") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            fields[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    private func gateLines() throws -> [GateLine] {
        try RepoFiles.text(Self.conf).components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in
                let fields = line.components(separatedBy: "\t")
                #expect(fields.count == 4, "\(Self.conf) has a line without four tab-separated fields: \(line)")
                let padded = fields + Array(repeating: "", count: max(0, 4 - fields.count))
                return GateLine(
                    name: padded[0],
                    followUp: Int(padded[1]) ?? 0,
                    paths: padded[2].split(separator: " ").map(String.init)
                )
            }
    }

    private func citingFiles() throws -> [(String, String)] {
        let files = try personaNames().map { "\(Self.personas)/\($0).md" } + [Self.owners]
        return try files.map { ($0, try RepoFiles.text($0)) }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: RepoFiles.root.appendingPathComponent(path).path)
    }

    /// Every inline code span that starts with a repository path: the whole span, or for a command such as
    /// `scripts/check.sh format lint`, its first word. A path with a placeholder, a glob or an ellipsis is a pattern,
    /// not a path, and is skipped.
    private func citedPaths(in text: String) -> Set<String> {
        let roots = ["Sources/", "Tests/", "scripts/", "App/", ".agents/", ".claude/"]
        var paths: Set<String> = []
        for line in text.components(separatedBy: "\n") where !line.hasPrefix("```") {
            let spans = line.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            let cited = spans.compactMap { $0.split(separator: " ").first.map(String.init) }.filter { path in
                roots.contains { path.hasPrefix($0) } && !path.contains { "<>{}*…".contains($0) }
            }
            paths.formUnion(cited)
        }
        return paths
    }

    /// Every minted id written as `ADR YYYY-MM.xxxx`, except one that knit-next's own ADRs carry.
    private func citedDecisions(in text: String) -> Set<String> {
        let pieces = text.components(separatedBy: "ADR ")
        var ids: Set<String> = []
        for (before, after) in zip(pieces, pieces.dropFirst()) where !before.suffix(16).contains("knit-next") {
            let id = String(after.prefix(12))
            if isMinted(id) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// `2026-10.zjmx`: a year, a month and a four-character suffix.
    private func isMinted(_ id: String) -> Bool {
        let characters = Array(id)
        guard characters.count == 12, characters[4] == "-", characters[7] == "." else {
            return false
        }
        let digits = characters[0..<4] + characters[5..<7]
        return digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
            && characters[8...].allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }
}
