public import Foundation

/// The crash and the hang `-demoCrash` saves, in MetricKit's shapes, so the UI tests and the screenshots reach a report's
/// screen without making Knit crash (ADR 2026-10.qhsv). The tests read them too. Every UUID and address is made up.
public enum DemoCrash {
    /// The made-up UUID of the app's binary.
    public static let appUUID = "5F2C1D3A-8B41-3E77-9A0C-6D2E4F1B7C90"
    private static let swiftCoreUUID = "1B7E3F55-0C2A-3D91-8E64-AF0B9C2D4E18"
    private static let uiKitUUID = "9C04A2E1-7D3B-35F8-B612-4E8A0F1C6D27"
    private static let kernelUUID = "E3A91B07-4F6C-3A2D-8B15-70D2C9E6F4A3"
    private static let millisecondsPerMinute: Int64 = 60_000
    /// `EXC_BREAKPOINT` and `SIGTRAP`, what a Swift trap raises.
    private static let breakpoint = 6
    private static let trap = 5
    private static let hangSeconds = 2.4

    /// A crash and a hang, `minutes` apart, the hang the newer, both ending before `now`.
    public static func diagnostics(now: Int64, minutes: Int64 = 90) -> [CrashDiagnostic] {
        [
            crash(at: now - (minutes + minutes) * millisecondsPerMinute),
            hang(at: now - minutes * millisecondsPerMinute),
        ]
    }

    /// A store of the demo's own in `root`, emptied, then holding ``diagnostics(now:minutes:)``.
    public static func store(
        now: Int64, root: URL = FileManager.default.temporaryDirectory.appending(path: "DemoCrashReports", directoryHint: .isDirectory)
    ) -> CrashStore {
        try? FileManager.default.removeItem(at: root)
        let store = CrashStore(root: root)
        store.importDiagnostics(diagnostics(now: now))
        return store
    }

    /// A Swift trap in Knit's code: `EXC_BREAKPOINT`, `SIGTRAP`, on the main thread, with a second thread beside it.
    public static func crash(at: Int64) -> CrashDiagnostic {
        CrashDiagnostic(
            kind: .crash,
            at: at,
            appVersion: "1.0.0",
            appBuild: "4",
            channel: .testFlight,
            device: "iPhone14,2",
            system: "iPhone OS 18.6 (22G86)",
            architecture: "arm64e",
            exceptionType: breakpoint,
            exceptionCode: 1,
            signal: trap,
            terminationReason: "Namespace SIGNAL, Code 5 Trace/BPT trap: 5",
            callStacks: Data(crashTree.utf8)
        )
    }

    /// The main thread waiting 2.4 seconds on a lock in Knit's code.
    public static func hang(at: Int64) -> CrashDiagnostic {
        CrashDiagnostic(
            kind: .hang,
            at: at,
            appVersion: "1.0.0",
            appBuild: "4",
            channel: .testFlight,
            device: "iPhone14,2",
            system: "iPhone OS 18.6 (22G86)",
            architecture: "arm64e",
            hangSeconds: hangSeconds,
            callStacks: Data(hangTree.utf8)
        )
    }

    private static let crashTree = """
        {"callStackPerThread": true, "callStacks": [
            {"threadAttributed": false, "callStackRootFrames": [
                {"binaryName": "libsystem_kernel.dylib", "binaryUUID": "\(kernelUUID)", "address": 7637105844,
                "offsetIntoBinaryTextSegment": 3764, "sampleCount": 1}]},
            {"threadAttributed": true, "callStackRootFrames": [
                {"binaryName": "libswiftCore.dylib", "binaryUUID": "\(swiftCoreUUID)", "address": 6929823332,
                "offsetIntoBinaryTextSegment": 1253476, "sampleCount": 1, "subFrames": [
                    {"binaryName": "Knit", "binaryUUID": "\(appUUID)", "address": 4372652784,
                    "offsetIntoBinaryTextSegment": 1229552, "sampleCount": 1, "subFrames": [
                        {"binaryName": "Knit", "binaryUUID": "\(appUUID)", "address": 4372641024,
                        "offsetIntoBinaryTextSegment": 1217792, "sampleCount": 1, "subFrames": [
                            {"binaryName": "UIKitCore", "binaryUUID": "\(uiKitUUID)", "address": 6842116736,
                            "offsetIntoBinaryTextSegment": 2398336, "sampleCount": 1}]}]}]}]}]}
        """

    private static let hangTree = """
        {"callStackPerThread": true, "callStacks": [
            {"threadAttributed": true, "callStackRootFrames": [
                {"binaryName": "libsystem_kernel.dylib", "binaryUUID": "\(kernelUUID)", "address": 7637104884,
                "offsetIntoBinaryTextSegment": 2804, "sampleCount": 24, "subFrames": [
                    {"binaryName": "Knit", "binaryUUID": "\(appUUID)", "address": 4372701184,
                    "offsetIntoBinaryTextSegment": 1277952, "sampleCount": 18, "subFrames": [
                        {"binaryName": "UIKitCore", "binaryUUID": "\(uiKitUUID)", "address": 6842116736,
                        "offsetIntoBinaryTextSegment": 2398336, "sampleCount": 18}]},
                    {"binaryName": "Knit", "binaryUUID": "\(appUUID)", "address": 4372705280,
                    "offsetIntoBinaryTextSegment": 1282048, "sampleCount": 6, "subFrames": [
                        {"binaryName": "UIKitCore", "binaryUUID": "\(uiKitUUID)", "address": 6842116736,
                        "offsetIntoBinaryTextSegment": 2398336, "sampleCount": 6}]}]}]}]}
        """
}
