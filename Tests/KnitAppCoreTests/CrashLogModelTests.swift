import Foundation
import Testing

@testable import KnitAppCore

/// A saved report's screen, and Diagnostics' rows for it.
@MainActor
@Suite struct CrashLogModelTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("crashlog-\(UUID().uuidString)", isDirectory: true)

    private var store: CrashStore { CrashStore(root: root.appendingPathComponent("reports")) }
    private var share: URL { root.appendingPathComponent("share") }

    @Test func theNewestReportOfItsKindIsReadWithItsLinkAndFile() async throws {
        store.importDiagnostics(DemoCrash.diagnostics(now: CrashReportTests.at))
        let model = CrashLogModel(store: store, kind: .hang, shareDirectory: share)
        #expect(!model.isLoaded)
        await model.load()
        let report = try #require(model.report)
        #expect(model.isLoaded)
        #expect(report.ref.kind == .hang)
        #expect(report.text.hasPrefix("Knit for iOS hang report"))
        #expect(report.issue?.absoluteString.hasPrefix(CrashIssueURL.issues + "?template=bug_report.yml") == true)
        let file = try #require(report.shareFile)
        #expect(try String(contentsOf: file, encoding: .utf8) == report.text)
    }

    @Test func deleteAllEmptiesEveryKind() async {
        store.importDiagnostics(DemoCrash.diagnostics(now: CrashReportTests.at))
        let model = CrashLogModel(store: store, kind: .crash, shareDirectory: share)
        await model.load()
        await model.deleteAll()
        #expect(model.report == nil)
        #expect(store.latest(.crash) == nil && store.latest(.hang) == nil)
        #expect(!FileManager.default.fileExists(atPath: share.path))
    }

    @Test func anEmptyStoreLoadsNothing() async {
        let model = CrashLogModel(store: store, kind: .crash, shareDirectory: share)
        await model.load()
        #expect(model.isLoaded && model.report == nil)
    }

    @Test func diagnosticsListsTheNewestOfEachKindCrashFirst() async {
        let rig = AppRig()
        let diagnostics = DiagnosticsModel(session: rig.session, crashes: store)
        await diagnostics.refresh()
        #expect(diagnostics.reports.isEmpty)
        store.importDiagnostics(DemoCrash.diagnostics(now: CrashReportTests.at))
        await diagnostics.refresh()
        #expect(diagnostics.reports.map(\.kind) == [.crash, .hang])
        #expect(DiagnosticsModel(session: rig.session).reports.isEmpty)
    }
}
