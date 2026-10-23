import Foundation
import Testing

@testable import KnitAppCore

/// A diagnostic as a report's text (ADR 2026-10.qhsv): the header, the attributed thread first, a hang's branches, the
/// summary, the fingerprint and the caps.
@Suite struct CrashReportTests {
    static let at: Int64 = 1_792_345_242_000

    private func lines(_ report: CrashReport) -> [String] {
        report.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// A tree of one attributed thread whose root frames are `frames`, as JSON.
    static func attributed(_ frames: String) -> Data {
        Data(#"{"callStacks": [{"threadAttributed": true, "callStackRootFrames": [\#(frames)]}]}"#.utf8)
    }

    /// A one-frame-per-level stack `depth` frames deep, innermost first.
    static func chain(_ depth: Int, threads: Int = 1) -> Data {
        var frame = ""
        for level in (0..<depth).reversed() {
            let callers = frame.isEmpty ? "" : #", "subFrames": [\#(frame)]"#
            frame =
                #"{"binaryName": "Knit", "binaryUUID": "\#(DemoCrash.appUUID)", "address": \#(4_000_000 + level), "#
                + #""offsetIntoBinaryTextSegment": \#(level)\#(callers)}"#
        }
        let stack = #"{"threadAttributed": true, "callStackRootFrames": [\#(frame)]}"#
        return Data(#"{"callStacks": [\#(Array(repeating: stack, count: threads).joined(separator: ", "))]}"#.utf8)
    }

    @Test func aCrashReadsAsItsHeaderThenTheCrashedThreadFirst() throws {
        let report = CrashReport(DemoCrash.crash(at: Self.at))
        let lines = lines(report)
        #expect(
            Array(lines.prefix(10)) == [
                "Knit for iOS crash report - redacted on the iPhone. Nothing was uploaded.",
                "summary: EXC_BREAKPOINT (SIGTRAP) in Knit +0x12c2f0",
                "app: 1.0.0 (4) TestFlight",
                "time: 2026-10-18T17:40:42Z (1792345242000)",
                "device: iPhone14,2",
                "ios: iPhone OS 18.6 (22G86)",
                "arch: arm64e",
                "exception: EXC_BREAKPOINT (6), code 1, signal SIGTRAP (5)",
                "termination: Namespace SIGNAL, Code 5 Trace/BPT trap: 5",
                "symbols: unsymbolicated - scripts/symbolicate.py resolves the frames with the dSYM of 1.0.0 (4)",
            ])
        let body = try #require(lines.firstIndex(of: CrashReport.separator))
        // MetricKit lists the crashed thread second; the report puts it first, where a cut excerpt keeps it.
        #expect(
            Array(lines[(body + 1)...]) == [
                "Thread 0 (crashed)",
                "0 libswiftCore.dylib 0x000000019d0cb664 1B7E3F55-0C2A-3D91-8E64-AF0B9C2D4E18 + 1253476",
                "1 Knit 0x0000000104a162f0 \(DemoCrash.appUUID) + 1229552",
                "2 Knit 0x0000000104a13500 \(DemoCrash.appUUID) + 1217792",
                "3 UIKitCore 0x0000000197d26a80 9C04A2E1-7D3B-35F8-B612-4E8A0F1C6D27 + 2398336",
                "",
                "Thread 1",
                "0 libsystem_kernel.dylib 0x00000001c734fcb4 E3A91B07-4F6C-3A2D-8B15-70D2C9E6F4A3 + 3764",
                "",
            ])
        let ascii = report.text.unicodeScalars.allSatisfy(\.isASCII)
        #expect(ascii)
    }

    @Test func theSummaryNamesKnitsFirstFrameElseTheInnermost() {
        #expect(CrashReport(DemoCrash.crash(at: Self.at)).summary == "EXC_BREAKPOINT (SIGTRAP) in Knit +0x12c2f0")
        var system = DemoCrash.crash(at: Self.at)
        system.callStacks = Self.attributed(#"{"binaryName": "UIKitCore", "offsetIntoBinaryTextSegment": 255}"#)
        system.exceptionType = 1
        system.signal = 11
        #expect(CrashReport(system).summary == "EXC_BAD_ACCESS (SIGSEGV) in UIKitCore +0xff")
        system.callStacks = Data(#"{"callStacks": []}"#.utf8)
        system.exceptionType = nil
        system.signal = 6
        #expect(CrashReport(system).summary == "SIGABRT")
    }

    /// As the lab iPhone's debug build reported it (2026-10-23): the app's code in `Knit.debug.dylib`, and idle threads
    /// with no frames.
    @Test func aDebugBuildsDylibIsKnitsAndAnIdleThreadSaysItHasNoFrames() {
        var crash = DemoCrash.crash(at: Self.at)
        crash.callStacks = Data(
            #"""
            {"callStacks": [
                {"threadAttributed": true, "callStackRootFrames": [{"binaryName": "libswiftCore.dylib", "offsetIntoBinaryTextSegment": 1,
                    "subFrames": [{"binaryName": "Knit.debug.dylib", "offsetIntoBinaryTextSegment": 296292}]}]},
                {"threadAttributed": false, "callStackRootFrames": []}]}
            """#.utf8)
        let report = CrashReport(crash)
        #expect(report.summary == "EXC_BREAKPOINT (SIGTRAP) in Knit.debug.dylib +0x48564")
        #expect(lines(report).contains("Thread 1 (no frames)"))
    }

    @Test func anObjectiveCExceptionKeepsItsFormatStringRedacted() {
        var crash = DemoCrash.crash(at: Self.at)
        crash.exceptionType = 10
        crash.exceptionCode = 0
        crash.signal = 6
        crash.objectiveC = CrashDiagnostic.ObjectiveCException(
            name: "NSInvalidArgumentException",
            className: "NSString",
            format: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil for abcdefghijklmnopqrstuvwxyz"
        )
        let report = CrashReport(crash)
        #expect(report.summary == "NSInvalidArgumentException in Knit +0x12c2f0")
        #expect(
            lines(report).contains(
                #"objc: NSInvalidArgumentException, class NSString, format "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil for [node]""#
            ))
        #expect(lines(report).contains("exception: EXC_CRASH (10), code 0, signal SIGABRT (6)"))
    }

    @Test func aHangFollowsItsHeaviestPathAndIndentsWhereItsSamplesPart() throws {
        let report = CrashReport(DemoCrash.hang(at: Self.at))
        let lines = lines(report)
        #expect(lines[0] == "Knit for iOS hang report (Knit stopped responding) - redacted on the iPhone. Nothing was uploaded.")
        #expect(report.summary == "2.4 s hang in Knit +0x138000")
        #expect(lines.contains("hang: 2.4 s on the main thread"))
        #expect(!lines.contains { $0.hasPrefix("exception:") || $0.hasPrefix("termination:") })
        let body = try #require(lines.firstIndex(of: CrashReport.separator))
        let uiKit = "UIKitCore 0x0000000197d26a80 9C04A2E1-7D3B-35F8-B612-4E8A0F1C6D27 + 2398336"
        #expect(
            Array(lines[(body + 1)...]) == [
                "Thread 0 (hung)",
                "0 libsystem_kernel.dylib 0x00000001c734f8f4 E3A91B07-4F6C-3A2D-8B15-70D2C9E6F4A3 + 2804 [24]",
                "  1 Knit 0x0000000104a22000 \(DemoCrash.appUUID) + 1277952 [18]",
                "  2 \(uiKit) [18]",
                "  1 Knit 0x0000000104a23000 \(DemoCrash.appUUID) + 1282048 [6]",
                "  2 \(uiKit) [6]",
                "",
            ])
    }

    @Test func theFingerprintNamesTheFailureAndTheKeyTheDiagnostic() {
        let first = CrashReport(DemoCrash.crash(at: Self.at))
        let again = CrashReport(DemoCrash.crash(at: Self.at))
        let later = CrashReport(DemoCrash.crash(at: Self.at + 60_000))
        #expect(first.fingerprint.count == 8 && first.key.count == 16)
        #expect(first.fingerprint == later.fingerprint)
        #expect(first.key == again.key)
        #expect(first.key != later.key)
        #expect(first.fingerprint != CrashReport(DemoCrash.hang(at: Self.at)).fingerprint)
        var other = DemoCrash.crash(at: Self.at)
        other.signal = 11
        #expect(first.fingerprint != CrashReport(other).fingerprint)
    }

    @Test func aTreeMetricKitCouldNotWriteStillMakesAReport() {
        var crash = DemoCrash.crash(at: Self.at)
        crash.callStacks = Data("not json".utf8)
        let report = CrashReport(crash)
        #expect(report.summary == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(report.text.hasSuffix("----\n(MetricKit's call stacks could not be read)\n"))
    }

    @Test func aDeepStackIsReadAndCutToItsLines() throws {
        var crash = DemoCrash.crash(at: Self.at)
        crash.callStacks = Self.chain(600)
        // Foundation's decoder stops at 255 frames, a stack overflow's stack runs to hundreds, and the reader keeps 512.
        let tree = try #require(CallStackTree.decode(crash.callStacks))
        var depth = 0
        var level = tree.callStacks.first?.callStackRootFrames ?? []
        while let frame = level.first {
            depth += 1
            level = frame.subFrames
        }
        #expect(depth == CallStackReader.maxFrameDepth)
        let lines = lines(CrashReport(crash))
        let body = try #require(lines.firstIndex(of: CrashReport.separator))
        #expect(lines[body + 2] == "0 Knit 0x00000000003d0900 \(DemoCrash.appUUID) + 0")
        #expect(lines.count == body + 2 + CrashReport.maxFramesPerThread + 2)
        #expect(lines[lines.count - 2] == "... more frames not shown")
    }

    @Test func aReportPastItsCapIsCutAndSaysSo() {
        var crash = DemoCrash.crash(at: Self.at)
        crash.callStacks = Self.chain(300, threads: 4)
        let report = CrashReport(crash)
        #expect(report.text.count > CrashReport.maxCrashCharacters)
        #expect(report.text.count < CrashReport.maxCrashCharacters + 100)
        #expect(report.text.hasSuffix(" more characters]\n"))
        #expect(report.text.contains("\n... [truncated, "))
    }

    @Test func aNumberWithoutANameIsWrittenAsItsNumber() {
        var crash = DemoCrash.crash(at: Self.at)
        crash.exceptionType = 99
        crash.signal = 31
        #expect(lines(CrashReport(crash)).contains("exception: 99, code 1, signal 31"))
        #expect(CrashReport(crash).summary == "Crash in Knit +0x12c2f0")
        crash.exceptionType = 1
        #expect(CrashReport(crash).summary == "EXC_BAD_ACCESS in Knit +0x12c2f0")
        var hang = DemoCrash.hang(at: Self.at)
        hang.hangSeconds = nil
        #expect(CrashReport(hang).summary == "0.0 s hang in Knit +0x138000")
    }

    @Test func aBadAccessKeepsTheRegionItTouchedRedacted() {
        var crash = DemoCrash.crash(at: Self.at)
        crash.regionInfo = "0x10 is not in any region. Its binary: /private/var/containers/Bundle/Application/5F2C/Knit.app/Knit"
        #expect(lines(CrashReport(crash)).contains("region: 0x10 is not in any region. Its binary: [path]"))
    }

    @Test func theHeaderStaysASCIIWhateverTheSystemSays() {
        var crash = DemoCrash.crash(at: Self.at)
        crash.system = "iPhone OS 18.6 (22G86) β"
        crash.terminationReason = "Namespace SIGNAL — Café"
        let report = CrashReport(crash)
        #expect(report.text.contains("ios: iPhone OS 18.6 (22G86) ?"))
        #expect(report.text.contains("termination: Namespace SIGNAL [text] [text]"))
        let ascii = report.text.unicodeScalars.allSatisfy(\.isASCII)
        #expect(ascii)
    }
}

/// The call-stack JSON, read without Foundation's decoder.
@Suite struct CallStackReaderTests {
    @Test func itReadsEscapesUnknownKeysAndWholeAddresses() throws {
        let json = #"""
            {"callStackPerThread": true, "extra": {"nested": [1, 2.5e3, -4, null, false, {"a": "b"}]},
                "callStacks": [{"threadAttributed": true, "callStackRootFrames": [
                    {"binaryName": "Kn\u0069t \"one\"\/\ud83e\uddf6\n", "binaryUUID": "A", "address": 18446744073709551615,
                    "offsetIntoBinaryTextSegment": 9007199254740993, "sampleCount": 3, "unknown": [{"subFrames": [{}]}],
                    "subFrames": [{"binaryName": "UIKitCore", "address": -1, "sampleCount": 2e0}]}]},
                {"callStackRootFrames": []}]}
            """#
        let tree = try #require(CallStackTree.decode(Data(json.utf8)))
        #expect(tree.callStacks.count == 2)
        #expect(tree.callStacks[1] == CallStackTree.Stack())
        let frame = try #require(tree.callStacks.first?.callStackRootFrames.first)
        #expect(frame.binaryName == "Knit \"one\"/🧶\n")
        #expect(frame.address == UInt64.max)
        #expect(frame.offsetIntoBinaryTextSegment == 9_007_199_254_740_993)
        #expect(frame.sampleCount == 3)
        // A number written as an exponent still reads; one that is no whole number reads as nothing.
        #expect(frame.subFrames == [CallStackTree.Frame(binaryName: "UIKitCore", address: 0, sampleCount: 2)])
    }

    @Test func aLoneLowSurrogateReadsAsTheReplacementCharacter() throws {
        let json = #"{"callStacks": [{"callStackRootFrames": [{"binaryName": "\udc00"}]}]}"#
        let tree = try #require(CallStackTree.decode(Data(json.utf8)))
        #expect(tree.callStacks.first?.callStackRootFrames.first?.binaryName == "\u{FFFD}")
    }

    @Test(arguments: [
        "", "[]", #"{"callStacks": [}"#, #"{"a": 1,}"#, #"{"a" 1}"#, #"{"a": tru}"#, #"{"a": "\x"}"#, #"{"a": "\ud83e"}"#,
        #"{"a": 1} {}"#, #"{"a": 1"#, "{\"a\": \"line\nbreak\"}", #"{"a": --1}"#, #"{"a" {}}"#, #"{"a": ]}"#, #"{"a":: 1}"#,
        "{,}", #"{"a": "abc"#, #"{"a": "\"#, #"{"a": "\u12"}"#,
    ])
    func itRefusesWhatIsNotJSON(_ text: String) {
        #expect(CallStackTree.decode(Data(text.utf8)) == nil)
    }

    @Test func itRefusesBytesThatAreNotUTF8() {
        #expect(CallStackTree.decode(Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D])) == nil)
    }
}
