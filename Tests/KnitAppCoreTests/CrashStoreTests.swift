import Foundation
import Testing

@testable import KnitAppCore

/// The saved reports (ADR 2026-10.qhsv): each diagnostic once, the caps per kind and per fingerprint, Delete all, and the
/// shared copy.
@Suite struct CrashStoreTests {
    private let root: URL
    private let store: CrashStore

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("crashes-\(UUID().uuidString)", isDirectory: true)
        store = CrashStore(root: root)
    }

    private static let at = CrashReportTests.at
    private static let minute: Int64 = 60_000

    /// A crash of its own fingerprint, by its signal.
    private func crash(signal: Int, at: Int64) -> CrashDiagnostic {
        var crash = DemoCrash.crash(at: at)
        crash.signal = signal
        return crash
    }

    private func hang(seconds: Double, at: Int64, offset: Int = 0) -> CrashDiagnostic {
        var hang = DemoCrash.hang(at: at)
        hang.hangSeconds = seconds
        hang.callStacks = CrashReportTests.attributed(#"{"binaryName": "Knit", "offsetIntoBinaryTextSegment": \#(offset)}"#)
        return hang
    }

    @Test func eachDiagnosticIsSavedOnceAndReadsBack() throws {
        let diagnostics = DemoCrash.diagnostics(now: Self.at)
        #expect(store.importDiagnostics(diagnostics) == 2)
        #expect(store.importDiagnostics(diagnostics) == 0)
        let crash = try #require(store.latest(.crash))
        #expect(crash.summary == "EXC_BREAKPOINT (SIGTRAP) in Knit +0x12c2f0")
        #expect(crash.app == "1.0.0 (4) TestFlight" && crash.version == "1.0.0 (4)")
        #expect(crash.device == "iPhone14,2" && crash.system == "iPhone OS 18.6 (22G86)")
        #expect(crash.at == diagnostics[0].at)
        #expect(store.read(crash) == CrashReport(diagnostics[0]).text)
        #expect(store.latest(.hang)?.summary == "2.4 s hang in Knit +0x138000")
    }

    @Test func aHangShorterThanASecondIsNotKept() {
        var untimed = hang(seconds: 2, at: Self.at)
        untimed.hangSeconds = nil
        #expect(store.importDiagnostics([hang(seconds: 0.6, at: Self.at), untimed]) == 0)
        #expect(store.latest(.hang) == nil)
        #expect(store.importDiagnostics([hang(seconds: 1, at: Self.at)]) == 1)
    }

    @Test func fiveOfAKindAreKeptAndTwoOfOneFailure() {
        let loop = (0..<4).map { crash(signal: 5, at: Self.at + Int64($0) * Self.minute) }
        let others = [4, 6, 10, 11].enumerated().map { crash(signal: $1, at: Self.at - Int64($0 + 1) * Self.minute) }
        #expect(store.importDiagnostics(loop + others) == 8)
        let kept = store.list(.crash)
        #expect(kept.count == CrashStore.maxPerKind)
        #expect(kept.map(\.at) == kept.map(\.at).sorted(by: >))
        let loopPrint = CrashReport(loop[0]).fingerprint
        #expect(kept.filter { $0.fingerprint == loopPrint }.map(\.at) == [loop[3].at, loop[2].at])
        #expect(kept.first?.at == loop[3].at)
    }

    @Test func aRunOfHangsNeverPushesOutACrash() {
        let hangs = (0..<8).map { hang(seconds: 2, at: Self.at + Int64($0) * Self.minute, offset: $0) }
        #expect(store.importDiagnostics([DemoCrash.crash(at: Self.at - Self.minute)] + hangs) == 9)
        #expect(store.list(.hang).count == CrashStore.maxPerKind)
        #expect(store.latest(.crash) != nil)
    }

    @Test func twoDiagnosticsInOneMillisecondAreBothKept() {
        var second = DemoCrash.crash(at: Self.at)
        second.terminationReason = "Namespace SIGNAL, Code 5, a second time"
        #expect(store.importDiagnostics([DemoCrash.crash(at: Self.at), second]) == 2)
        #expect(store.list(.crash).map(\.at) == [Self.at + 1, Self.at])
    }

    @Test func aDeletedReportNeverComesBack() {
        let diagnostics = DemoCrash.diagnostics(now: Self.at)
        store.importDiagnostics(diagnostics)
        store.clear()
        #expect(store.latest(.crash) == nil && store.latest(.hang) == nil)
        #expect(store.importDiagnostics(diagnostics) == 0)
        #expect(store.importDiagnostics([DemoCrash.crash(at: Self.at + Self.minute)]) == 1)
    }

    @Test func aDiagnosticThatCouldNotBeWrittenIsTriedAgain() throws {
        let blocker = root.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: blocker)
        // As before the first unlock: the store's directory cannot be made, so nothing is seen.
        let blocked = CrashStore(root: blocker.appendingPathComponent("reports"))
        #expect(blocked.importDiagnostics(DemoCrash.diagnostics(now: Self.at)) == 0)
        try FileManager.default.removeItem(at: blocker)
        #expect(blocked.importDiagnostics(DemoCrash.diagnostics(now: Self.at)) == 2)
    }

    @Test func aFileNameSaysItsKindTimeAndFingerprint() {
        let name = CrashStore.name(.hang, at: 42, fingerprint: "0123abcd")
        #expect(name == "hang-0000000000042-0123abcd.txt")
        #expect(CrashStore.parse(name)?.kind == .hang && CrashStore.parse(name)?.at == 42)
        for other in [
            "seen", "crash-42-0123abcd.txt", "crash-0000000000042-0123ABCD.txt", "fall-0000000000042-0123abcd.txt",
            "crash-0000000000042-0123abcd.tmp",
        ] {
            #expect(CrashStore.parse(other) == nil, "\(other)")
        }
    }

    @Test func aHeaderWithASummaryAloneStillLists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("summary: something\n----\n".utf8).write(
            to: root.appendingPathComponent(CrashStore.name(.hang, at: 7, fingerprint: "0000abcd")))
        let ref = try #require(store.latest(.hang))
        #expect(ref.summary == "something" && ref.app.isEmpty && ref.device.isEmpty && ref.system.isEmpty)
    }

    @Test func aSeenListThatIsNotTextIsReadAsEmpty() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x0A]).write(to: root.appendingPathComponent("seen"))
        #expect(store.importDiagnostics([DemoCrash.crash(at: Self.at)]) == 1)
    }

    @Test func aFileWithNoHeaderIsPassedOver() throws {
        store.importDiagnostics([DemoCrash.crash(at: Self.at)])
        try Data("garbage".utf8).write(to: root.appendingPathComponent(CrashStore.name(.crash, at: Self.at + 1, fingerprint: "00000000")))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        #expect(store.latest(.crash)?.at == Self.at)
        #expect(store.list(.crash).count == 1)
    }

    @Test func aReferenceIsItsFileAndItsVersionIsTheAppLinesStart() throws {
        store.importDiagnostics([DemoCrash.crash(at: Self.at)])
        let crash = try #require(store.latest(.crash))
        #expect(crash.id == crash.fileName)
        var unknown = crash
        unknown.app = "unknown"
        #expect(unknown.version == "unknown")
    }

    @Test func aReportThatIsNotAFileIsPassedOver() throws {
        store.importDiagnostics([DemoCrash.crash(at: Self.at)])
        let folder = root.appendingPathComponent(CrashStore.name(.crash, at: Self.at + 1, fingerprint: "00000000"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(store.latest(.crash)?.at == Self.at)
    }

    @Test func aCopyThatCannotBeMadeIsNone() throws {
        store.importDiagnostics([DemoCrash.crash(at: Self.at)])
        let crash = try #require(store.latest(.crash))
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        #expect(store.exportForShare(crash, into: blocker.appendingPathComponent("share")) == nil)
        store.clear()
        #expect(store.exportForShare(crash, into: root.appendingPathComponent("share")) == nil)
    }

    @Test func theDemosStoreHoldsACrashAndAHangAndNothingElse() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("left over".utf8).write(to: root.appendingPathComponent(CrashStore.name(.crash, at: 1, fingerprint: "00000000")))
        let demo = DemoCrash.store(now: Self.at, root: root)
        #expect(demo.list(.crash).count == 1 && demo.list(.hang).count == 1)
        #expect(demo.latest(.crash)?.at == Self.at - 180 * Self.minute)
    }

    @Test func aSharedCopyIsNamedForWhatItIsAndAlone() throws {
        store.importDiagnostics(DemoCrash.diagnostics(now: Self.at))
        let directory = root.appendingPathComponent("share")
        let utc = try #require(TimeZone(identifier: "UTC"))
        let crash = try #require(store.latest(.crash))
        let hang = try #require(store.latest(.hang))
        _ = store.exportForShare(crash, into: directory, timeZone: utc)
        let file = try #require(store.exportForShare(hang, into: directory, timeZone: utc))
        #expect(file.lastPathComponent == "knit-hang-1.0.0-20261018-1610.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == store.read(hang))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [file.lastPathComponent])
    }
}
