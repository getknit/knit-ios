import Foundation
import Testing

@testable import KnitAppCore

/// The bug form's link (knit-next `CrashIssueUrlTest`): its keys are the form's own ids, the two fields only a person
/// can fill stay blank, and a long report still fits.
@Suite struct CrashIssueURLTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue-\(UUID().uuidString)", isDirectory: true)

    private func saved(_ diagnostic: CrashDiagnostic) throws -> (CrashReportRef, String) {
        let store = CrashStore(root: root)
        store.importDiagnostics([diagnostic])
        let ref = try #require(store.latest(diagnostic.kind))
        return (ref, try #require(store.read(ref)))
    }

    private func link(_ diagnostic: CrashDiagnostic = DemoCrash.crash(at: CrashReportTests.at)) throws -> URL {
        let (ref, text) = try saved(diagnostic)
        return try #require(CrashIssueURL.forReport(ref, text: text))
    }

    /// The query's values, decoded.
    private func params(_ url: URL) throws -> [String: String] {
        let query = try #require(url.absoluteString.split(separator: "?", maxSplits: 1).last)
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            params[String(parts[0])] = try #require(String(parts[1]).removingPercentEncoding as String?)
        }
        return params
    }

    private static let template: String = {
        (try? String(contentsOf: CopyTests.root.appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml"), encoding: .utf8)) ?? ""
    }()

    @Test func everyKeyIsAFieldOfTheForm() throws {
        let pattern = try NSRegularExpression(pattern: #"^\s+id:\s*([\w-]+)\s*$"#, options: .anchorsMatchLines)
        let form = Self.template
        let ids = Set(
            pattern.matches(in: form, range: NSRange(form.startIndex..., in: form)).compactMap { match in
                Range(match.range(at: 1), in: form).map { String(form[$0]) }
            })
        #expect(ids.contains("summary"), "the template was read")
        let crash = try params(link())
        let hang = try params(link(DemoCrash.hang(at: CrashReportTests.at)))
        let keys = Set(crash.keys).union(hang.keys).subtracting(["template", "title"])
        #expect(keys.isSubset(of: ids), "\(keys.subtracting(ids)) are not in bug_report.yml")
        #expect(crash["template"] == "bug_report.yml")
    }

    @Test func theStateIsOneOfTheFormsOptions() throws {
        let state = try #require(params(link())["state"])
        let block = try #require(Self.template.components(separatedBy: "id: state").last?.components(separatedBy: "- type:").first)
        #expect(block.contains("- \(state)\n"))
    }

    @Test func whatOnlyAPersonKnowsStaysBlank() throws {
        let params = try params(link())
        #expect(params["steps"] == nil && params["expected"] == nil)
        #expect(params["title"] == "[Bug]: Crash - EXC_BREAKPOINT (SIGTRAP) in Knit +0x12c2f0")
        #expect(params["version"] == "1.0.0 (4)")
        #expect(params["devices"] == "iPhone14,2, iPhone OS 18.6 (22G86), Knit 1.0.0 (4)")
        let logs = try #require(params["logs"])
        #expect(logs.hasPrefix(CrashIssueURL.marker + "\n"))
        #expect(logs.contains("```text\nKnit for iOS crash report"))
        #expect(logs.contains("Thread 0 (crashed)"))
        #expect(try link(DemoCrash.hang(at: CrashReportTests.at)).absoluteString.contains("title=%5BBug%5D%3A%20Hang%20-%202.4%20s%20hang"))
    }

    @Test func spacesAndAmpersandsAreEncoded() throws {
        let url = try link().absoluteString
        let query = try #require(url.split(separator: "?").last)
        #expect(url.contains("%20") && !query.contains("+"))
        #expect(query.split(separator: "&").allSatisfy { $0.split(separator: "=").count == 2 })
    }

    @Test func aLongReportStillFitsAndKeepsItsTop() throws {
        var crash = DemoCrash.crash(at: CrashReportTests.at)
        crash.callStacks = CrashReportTests.chain(300, threads: 4)
        let url = try link(crash)
        #expect(url.absoluteString.count <= CrashIssueURL.maxURLCharacters)
        let logs = try #require(params(url)["logs"])
        #expect(logs.contains("summary: EXC_BREAKPOINT (SIGTRAP) in Knit +0x0"))
        #expect(logs.contains("\n... truncated, the full report is on your clipboard\n```"))
        let frames = logs.split(separator: "\n").filter { $0.contains(" Knit 0x") }
        #expect(frames.count > 10 && frames.allSatisfy { $0.hasSuffix("7C90 + \($0.split(separator: " ")[0])") })
    }

    @Test func aBudgetTooSmallForALineKeepsOnlyTheNote() {
        #expect(CrashIssueURL.fit("one\ntwo", budget: 0) == CrashIssueURL.truncated)
        #expect(CrashIssueURL.fit("one\ntwo", budget: 5) == CrashIssueURL.truncated)
        #expect(CrashIssueURL.fit("one\ntwo", budget: 100) == "one\ntwo")
    }
}
