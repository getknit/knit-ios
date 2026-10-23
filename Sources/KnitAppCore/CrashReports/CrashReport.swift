import Foundation
import KnitWire

/// A diagnostic as the text a report file holds (knit-next `CrashStore.kt`'s format, ADR 028): an ASCII header of
/// `key: value` lines, the separator, then each thread's frames, the attributed thread first so that an excerpt cut to
/// fit a URL keeps it. Frames are written as MetricKit gives them, unsymbolicated: `scripts/symbolicate.py` resolves
/// them against the release's dSYM on a Mac.
public struct CrashReport: Sendable, Equatable {
    /// The binaries that hold the app's own code, whose first frame a summary names: the executable, and the dylib an
    /// Xcode debug build moves the code into (seen on the lab iPhone, 2026-10-23).
    public static let appBinaries: Set = ["Knit", "Knit.debug.dylib"]
    /// Where the header ends.
    public static let separator = "----"
    /// The longest crash report kept, in characters.
    public static let maxCrashCharacters = 60_000
    /// The longest hang report kept: a hang's sampled tree runs longer than a crash's stack, as Android's ANR does.
    public static let maxHangCharacters = 120_000
    /// The most frame lines written for one thread; a stack overflow repeats one frame hundreds of times.
    public static let maxFramesPerThread = 256

    /// The kind.
    public var kind: CrashDiagnostic.Kind
    /// When it happened, in wall milliseconds.
    public var at: Int64
    /// Eight hex digits naming the failure: the kind, the exception and the innermost frames. Two reports of one crash
    /// loop share it.
    public var fingerprint: String
    /// Sixteen hex digits naming this one diagnostic, the same each time MetricKit hands it over.
    public var key: String
    /// The one line a row and an issue's title show.
    public var summary: String
    /// The whole text, cut to its kind's cap.
    public var text: String

    /// `diagnostic`'s report.
    public init(_ diagnostic: CrashDiagnostic) {
        kind = diagnostic.kind
        at = diagnostic.at
        let tree = CallStackTree.decode(diagnostic.callStacks)
        let stacks = tree.map(Self.attributedFirst) ?? []
        let innermost = stacks.first.map(Self.heaviestPath) ?? []
        summary = Self.summary(diagnostic, path: innermost)
        let failure = [
            diagnostic.kind.name,
            diagnostic.exceptionType.map(String.init) ?? "",
            diagnostic.signal.map(String.init) ?? "",
            diagnostic.objectiveC?.name ?? "",
        ]
        let frames = innermost.prefix(Self.fingerprintFrames).map { "\($0.binaryUUID)+\($0.offsetIntoBinaryTextSegment)" }
        fingerprint = Self.hex(UInt32(truncatingIfNeeded: StoreDigest.hash((failure + frames).joined(separator: "|"))))
        var lines = Self.header(diagnostic, summary: summary)
        lines.append(Self.separator)
        if tree == nil {
            lines.append("(MetricKit's call stacks could not be read)")
        }
        for (index, stack) in stacks.enumerated() {
            if index > 0 {
                lines.append("")
            }
            lines.append(Self.threadTitle(index, stack, kind: diagnostic.kind))
            lines += Self.frameLines(stack.callStackRootFrames, kind: diagnostic.kind)
        }
        let whole = lines.joined(separator: "\n") + "\n"
        key = Self.hex(StoreDigest.hash(whole))
        text = Self.cut(whole, to: diagnostic.kind == .crash ? Self.maxCrashCharacters : Self.maxHangCharacters)
    }

    private static let fingerprintFrames = 3
    private static let hexDigitsPerAddress = 16
    private static let hexRadix = 16
    private static let bitsPerHexDigit = 4

    private static func header(_ diagnostic: CrashDiagnostic, summary: String) -> [String] {
        let version = "\(diagnostic.appVersion) (\(diagnostic.appBuild))"
        var lines = [
            diagnostic.kind == .crash
                ? "Knit for iOS crash report - redacted on the iPhone. Nothing was uploaded."
                : "Knit for iOS hang report (Knit stopped responding) - redacted on the iPhone. Nothing was uploaded.",
            "summary: \(summary)",
            "app: \(version) \(diagnostic.channel.rawValue)",
            "time: \(Date(milliseconds: diagnostic.at).formatted(.iso8601)) (\(diagnostic.at))",
            "device: \(diagnostic.device)",
            "ios: \(diagnostic.system)",
            "arch: \(diagnostic.architecture)",
        ]
        if let exception = exceptionLine(diagnostic) {
            lines.append("exception: \(exception)")
        }
        if let reason = diagnostic.terminationReason {
            lines.append("termination: \(redacted(reason))")
        }
        if let region = diagnostic.regionInfo {
            lines.append("region: \(redacted(region))")
        }
        if let objectiveC = diagnostic.objectiveC {
            lines.append(
                "objc: \(redacted(objectiveC.name)), class \(redacted(objectiveC.className)), format \"\(redacted(objectiveC.format))\"")
        }
        if let seconds = diagnostic.hangSeconds {
            lines.append("hang: \(Self.seconds(seconds)) on the main thread")
        }
        lines.append("symbols: unsymbolicated - scripts/symbolicate.py resolves the frames with the dSYM of \(version)")
        return lines.map(ascii)
    }

    /// `line` with anything past ASCII as `?`: the system's own fields could carry a character the header rules out,
    /// and the redactor sees only the free-text ones.
    private static func ascii(_ line: String) -> String {
        guard !line.unicodeScalars.allSatisfy(\.isASCII) else {
            return line
        }
        return String(String.UnicodeScalarView(line.unicodeScalars.map { $0.isASCII ? $0 : "?" }))
    }

    /// `text` redacted, or withheld when the redactor cannot run.
    private static func redacted(_ text: String) -> String {
        CrashRedactor.redact(text) ?? "(withheld)"
    }

    private static func exceptionLine(_ diagnostic: CrashDiagnostic) -> String? {
        var parts: [String] = []
        if let type = diagnostic.exceptionType {
            parts.append(machException(type).map { "\($0) (\(type))" } ?? "\(type)")
        }
        if let code = diagnostic.exceptionCode {
            parts.append("code \(code)")
        }
        if let signal = diagnostic.signal {
            parts.append("signal " + (signalName(signal).map { "\($0) (\(signal))" } ?? "\(signal)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func summary(_ diagnostic: CrashDiagnostic, path: [CallStackTree.Frame]) -> String {
        let what: String
        switch diagnostic.kind {
        case .crash:
            if let objectiveC = diagnostic.objectiveC {
                what = redacted(objectiveC.name)
            } else if let name = diagnostic.exceptionType.flatMap(machException) {
                what = name + (diagnostic.signal.flatMap(signalName).map { " (\($0))" } ?? "")
            } else {
                what = diagnostic.signal.flatMap(signalName) ?? "Crash"
            }
        case .hang:
            what = "\(seconds(diagnostic.hangSeconds ?? 0)) hang"
        }
        guard let frame = path.first(where: { appBinaries.contains($0.binaryName) }) ?? path.first else {
            return what
        }
        return "\(what) in \(frame.binaryName) +0x\(String(frame.offsetIntoBinaryTextSegment, radix: hexRadix))"
    }

    /// A thread's heading. MetricKit lists idle threads with no frames, which the heading says rather than leaving it bare.
    private static func threadTitle(_ index: Int, _ stack: CallStackTree.Stack, kind: CrashDiagnostic.Kind) -> String {
        let empty = stack.callStackRootFrames.isEmpty ? " (no frames)" : ""
        guard stack.threadAttributed else {
            return "Thread \(index)\(empty)"
        }
        return "Thread \(index) (\(kind == .crash ? "crashed" : "hung"))\(empty)"
    }

    /// The stacks with the attributed one first, the rest in MetricKit's order.
    private static func attributedFirst(_ tree: CallStackTree) -> [CallStackTree.Stack] {
        tree.callStacks.filter(\.threadAttributed) + tree.callStacks.filter { !$0.threadAttributed }
    }

    /// From the innermost frame outward, the path most samples took: a crash's only path.
    private static func heaviestPath(_ stack: CallStackTree.Stack) -> [CallStackTree.Frame] {
        var path: [CallStackTree.Frame] = []
        var level = stack.callStackRootFrames
        while let next = heaviest(level), path.count < maxFramesPerThread {
            path.append(next)
            level = next.subFrames
        }
        return path
    }

    private static func heaviest(_ frames: [CallStackTree.Frame]) -> CallStackTree.Frame? {
        frames.enumerated().max { ($0.element.sampleCount, $1.offset) < ($1.element.sampleCount, $0.offset) }?.element
    }

    /// Each frame on a line of its own, numbered by its depth, siblings heaviest first. A chain stays flat; where a hang's
    /// samples part, each branch is indented under the frame they parted at.
    private static func frameLines(_ roots: [CallStackTree.Frame], kind: CrashDiagnostic.Kind) -> [String] {
        var lines: [String] = []
        // Depth first, without recursion: a stack overflow's stack is hundreds of frames deep.
        var pending = [(frames: ArraySlice(ordered(roots)), depth: 0, indent: 0)]
        while var level = pending.popLast() {
            guard let frame = level.frames.popFirst() else {
                continue
            }
            guard lines.count < maxFramesPerThread else {
                lines.append("... more frames not shown")
                break
            }
            lines.append(String(repeating: "  ", count: level.indent) + line(frame, depth: level.depth, kind: kind))
            pending.append(level)
            let indent = level.indent + (frame.subFrames.count > 1 ? 1 : 0)
            pending.append((frames: ArraySlice(ordered(frame.subFrames)), depth: level.depth + 1, indent: indent))
        }
        return lines
    }

    private static func ordered(_ frames: [CallStackTree.Frame]) -> [CallStackTree.Frame] {
        frames.enumerated().sorted { ($0.element.sampleCount, $1.offset) > ($1.element.sampleCount, $0.offset) }.map(\.element)
    }

    private static func line(_ frame: CallStackTree.Frame, depth: Int, kind: CrashDiagnostic.Kind) -> String {
        let address = String(frame.address, radix: hexRadix)
        let padded = String(repeating: "0", count: max(0, hexDigitsPerAddress - address.count)) + address
        let samples = kind == .hang ? " [\(frame.sampleCount)]" : ""
        return "\(depth) \(frame.binaryName) 0x\(padded) \(frame.binaryUUID) + \(frame.offsetIntoBinaryTextSegment)\(samples)"
    }

    /// `text` cut at `limit` characters, saying how much was left out.
    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        return "\(text.prefix(limit))\n... [truncated, \(text.count - limit) more characters]\n"
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    private static func hex(_ value: some FixedWidthInteger) -> String {
        let digits = String(value, radix: hexRadix)
        return String(repeating: "0", count: max(0, value.bitWidth / bitsPerHexDigit - digits.count)) + digits
    }

    /// The Mach exception types, from 1 (`<mach/exception_types.h>`).
    private static let machExceptions = [
        "EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_EMULATION", "EXC_SOFTWARE", "EXC_BREAKPOINT", "EXC_SYSCALL",
        "EXC_MACH_SYSCALL", "EXC_RPC_ALERT", "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD", "EXC_CORPSE_NOTIFY",
    ]

    /// Darwin's signals, from 1 (`<sys/signal.h>`).
    private static let signals = [
        "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGEMT", "SIGFPE", "SIGKILL", "SIGBUS", "SIGSEGV", "SIGSYS",
        "SIGPIPE", "SIGALRM", "SIGTERM",
    ]

    private static func machException(_ type: Int) -> String? {
        machExceptions.indices.contains(type - 1) ? machExceptions[type - 1] : nil
    }

    private static func signalName(_ signal: Int) -> String? {
        signals.indices.contains(signal - 1) ? signals[signal - 1] : nil
    }
}
