public import Foundation

/// One diagnostic MetricKit handed over, read into plain values by the app's collector, so that everything after it
/// builds and is tested on Linux. The metadata comes from MetricKit's typed API; only the call-stack tree arrives as
/// its JSON, which ``CallStackTree`` decodes.
public struct CrashDiagnostic: Sendable, Equatable {
    /// Which kind of report it makes.
    public enum Kind: Sendable, Hashable, CaseIterable {
        /// Knit closed: an `MXCrashDiagnostic`.
        case crash
        /// Knit's main thread stopped answering: an `MXHangDiagnostic`.
        case hang

        /// Its name in a report's file name: `crash` or `hang`.
        public var name: String {
            self == .crash ? "crash" : "hang"
        }

        /// The kind `name` names.
        public init?(name text: some StringProtocol) {
            guard let match = Self.allCases.first(where: { $0.name == text }) else {
                return nil
            }
            self = match
        }
    }

    /// Which build the app was, in the words a report's `app:` line uses.
    public enum Channel: String, Sendable, Equatable {
        /// A debug build, `app.getknit.knit.dev`.
        case debug = "debug"
        /// A store build installed from TestFlight.
        case testFlight = "TestFlight"
        /// A store build from the App Store.
        case appStore = "App Store"
    }

    /// An Objective-C exception, as much of it as a report keeps: its name, the class that raised it, and its format
    /// string, which is the code's own constant. The arguments and the message composed from them are runtime values,
    /// so the collector never reads them.
    public struct ObjectiveCException: Sendable, Equatable {
        /// The exception's name, `NSInvalidArgumentException` for one.
        public var name: String
        /// The class that raised it.
        public var className: String
        /// The format string the message was made from.
        public var format: String

        /// An exception.
        public init(name: String, className: String, format: String) {
            self.name = name
            self.className = className
            self.format = format
        }
    }

    /// The kind.
    public var kind: Kind
    /// When MetricKit says it happened: the payload's end, in wall milliseconds.
    public var at: Int64
    /// The version of the build that crashed or hung, which may be an earlier one than the build reading it.
    public var appVersion: String
    /// That build's number.
    public var appBuild: String
    /// That build's channel.
    public var channel: Channel
    /// The model identifier, `iPhone14,2` for one.
    public var device: String
    /// The system and its build, `iPhone OS 18.6 (22G86)` for one.
    public var system: String
    /// The CPU architecture, `arm64e` for one.
    public var architecture: String
    /// The Mach exception type, for a crash.
    public var exceptionType: Int?
    /// The Mach exception code, for a crash.
    public var exceptionCode: Int?
    /// The signal, for a crash.
    public var signal: Int?
    /// What the system said ended the process, for a crash. Free text, so it is redacted before it is kept.
    public var terminationReason: String?
    /// The memory region a bad access touched, for a crash. Free text, redacted too.
    public var regionInfo: String?
    /// The Objective-C exception behind a crash, when there was one.
    public var objectiveC: ObjectiveCException?
    /// How long the main thread stopped answering, in seconds, for a hang.
    public var hangSeconds: Double?
    /// The call-stack tree, as MetricKit's JSON.
    public var callStacks: Data

    /// A diagnostic. The crash fields stay `nil` for a hang, and ``hangSeconds`` for a crash.
    public init(
        kind: Kind,
        at: Int64,
        appVersion: String,
        appBuild: String,
        channel: Channel,
        device: String,
        system: String,
        architecture: String,
        exceptionType: Int? = nil,
        exceptionCode: Int? = nil,
        signal: Int? = nil,
        terminationReason: String? = nil,
        regionInfo: String? = nil,
        objectiveC: ObjectiveCException? = nil,
        hangSeconds: Double? = nil,
        callStacks: Data
    ) {
        self.kind = kind
        self.at = at
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.channel = channel
        self.device = device
        self.system = system
        self.architecture = architecture
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationReason = terminationReason
        self.regionInfo = regionInfo
        self.objectiveC = objectiveC
        self.hangSeconds = hangSeconds
        self.callStacks = callStacks
    }
}

/// MetricKit's call-stack tree (`MXCallStackTree.jsonRepresentation()`): one stack per thread, each a tree of frames.
/// A frame is a binary's UUID and an offset into its text segment, which the release's dSYM turns into a symbol, so a
/// stack holds no string the app wrote. Each root frame is the innermost call, and its sub-frames are its callers. A
/// crash's stack is one frame per level; a hang's is sampled, so a level may branch and each frame counts the samples
/// that passed through it. ``CallStackReader`` reads the JSON.
public struct CallStackTree: Sendable, Equatable {
    /// One thread's stack.
    public struct Stack: Sendable, Equatable {
        /// Whether the crash or hang is attributed to this thread.
        public var threadAttributed: Bool
        /// The innermost frames.
        public var callStackRootFrames: [Frame]

        /// A stack.
        public init(threadAttributed: Bool = false, callStackRootFrames: [Frame] = []) {
            self.threadAttributed = threadAttributed
            self.callStackRootFrames = callStackRootFrames
        }
    }

    /// One frame and its callers. A key MetricKit left out keeps its default: a frame it could not name keeps its
    /// address, with the binary unknown.
    public struct Frame: Sendable, Equatable {
        /// The binary's name, `Knit` or `libswiftCore.dylib`.
        public var binaryName: String
        /// The binary's UUID, which names its dSYM.
        public var binaryUUID: String
        /// The frame's address in the running process.
        public var address: UInt64
        /// The address's offset into the binary's text segment.
        public var offsetIntoBinaryTextSegment: UInt64
        /// How many samples passed through this frame: 1 in a crash.
        public var sampleCount: Int
        /// Its callers.
        public var subFrames: [Self]

        /// A frame.
        public init(
            binaryName: String = "???",
            binaryUUID: String = "",
            address: UInt64 = 0,
            offsetIntoBinaryTextSegment: UInt64 = 0,
            sampleCount: Int = 1,
            subFrames: [Self] = []
        ) {
            self.binaryName = binaryName
            self.binaryUUID = binaryUUID
            self.address = address
            self.offsetIntoBinaryTextSegment = offsetIntoBinaryTextSegment
            self.sampleCount = sampleCount
            self.subFrames = subFrames
        }
    }

    /// The threads' stacks, in MetricKit's order.
    public var callStacks: [Stack]

    /// A tree.
    public init(callStacks: [Stack]) {
        self.callStacks = callStacks
    }

    /// The tree in `json`, or `nil` when it is not one.
    public static func decode(_ json: Data) -> Self? {
        CallStackReader.read(Array(json))
    }
}
