public import KnitMesh

/// How the app was launched: `-seedDemo`, the radio state the demo reports (`-demoRadio off`), so a screen can be
/// checked in a state no real phone here is in, the unsupported device's among them (MVP item 10), the scene it
/// seeds (`-demoScene marketing`), whether it starts at onboarding (`-demoOnboarding`), what the camera answers
/// (`-demoCamera denied`), whether Choose photo picks a demo photo (`-demoPhoto`) or a GIF made of them
/// (`-demoPhoto gif`), whether the demo posts a notification to tap (`-demoNotification`), and whether every photo and
/// every message from someone else looks explicit or abusive to the content filter (`-demoSensitive`), words the
/// share sheet left for the room (`-demoShare "words"`), whether a crash and a hang wait in Diagnostics
/// (`-demoCrash`), and whether the mic records a bundled clip (`-demoVoice`).
public struct LaunchOptions: Sendable, Equatable {
    /// Whether to run the demo: seeded stores in memory, a radio that goes nowhere, and a fixed identity.
    public var seedDemo = false
    /// What the demo's radio says of itself.
    public var demoRadio = RadioState.on
    /// Who and what the demo seeds.
    public var demoScene = DemoScene.edgeCases
    /// Whether the demo starts at onboarding, as a first run does, rather than at the chat list. The UI tests walk it.
    public var demoOnboarding = false
    /// What the demo's camera answers, or `nil` for the device's own: the Simulator has no scanner, so the UI tests reach
    /// the refused and failed states only through this.
    public var demoCamera: DemoCamera.Answer?
    /// Whether Choose photo hands the cropper a demo photo rather than opening the photo library, in the demo and in
    /// a debug build's live launch: the system's picker runs outside Knit, out of a UI test's reach.
    public var demoPhoto = false
    /// Whether that picture is a GIF that moves, made of demo photos, so a UI test can watch one play in a thread.
    public var demoPhotoMoves = false
    /// Whether the demo asks to notify as it launches, then posts the room's notification each time Knit goes to the
    /// background: the demo's radio brings no messages, so a UI test would have no notification to tap.
    public var demoNotification = false
    /// Whether the demo's classifiers find every photo explicit and every message abusive, so the UI tests can walk what
    /// the content filter hides, asks and refuses; otherwise they find none so. Nothing in the repository is explicit or
    /// abusive to test with.
    public var demoSensitive = false
    /// Words the share sheet left for the room as the demo launches, which the UI tests walk (ADR 2026-10.z7a8).
    public var demoShare: String?
    /// Whether the demo's saved reports hold a crash and a hang (``DemoCrash``), so the UI tests reach a report's screen
    /// without crashing Knit (ADR 2026-10.qhsv).
    public var demoCrash = false
    /// Whether the composer's mic records the clip a debug build bundles, with the microphone allowed, in the demo and in
    /// a debug build's live launch: the Simulator has no microphone a UI test can speak into (``DemoVoiceCapture``).
    public var demoVoice = false
    /// Whether a live launch turns the forward-secrecy ratchet's switch on (`MeshConfiguration.ratchet`, ADR 2026-10.5sk9):
    /// `-ratchet on|off`, or the choice an earlier launch kept, else on (``Choice``). A release build reads no choice, so
    /// it is always on.
    public var ratchet = true
    /// What this launch's `-ratchet` chose, for the app to keep, or `nil` when it chose nothing.
    public var ratchetChoice: Choice?

    /// The options in `arguments`, the process's own, with `storedRatchet` the choice an earlier `-ratchet` kept, or `nil`
    /// for none. Anything unknown is left for the system.
    public init(arguments: [String], storedRatchet: Choice? = nil) {
        seedDemo = arguments.contains("-seedDemo")
        if let flag = arguments.firstIndex(of: "-demoRadio"), arguments.indices.contains(flag + 1) {
            demoRadio = Self.radioStates[arguments[flag + 1]] ?? .on
        }
        if let flag = arguments.firstIndex(of: "-demoScene"), arguments.indices.contains(flag + 1) {
            demoScene = DemoScene(rawValue: arguments[flag + 1]) ?? .edgeCases
        }
        demoOnboarding = arguments.contains("-demoOnboarding")
        if let flag = arguments.firstIndex(of: "-demoCamera"), arguments.indices.contains(flag + 1) {
            demoCamera = Self.cameraAnswers[arguments[flag + 1]]
        }
        if let flag = arguments.firstIndex(of: "-demoPhoto") {
            demoPhoto = true
            demoPhotoMoves = arguments.indices.contains(flag + 1) && arguments[flag + 1] == "gif"
        }
        demoNotification = arguments.contains("-demoNotification")
        demoSensitive = arguments.contains("-demoSensitive")
        demoCrash = arguments.contains("-demoCrash")
        demoVoice = arguments.contains("-demoVoice")
        demoShare = arguments.firstIndex(of: "-demoShare").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        ratchetChoice = Choice(after: "-ratchet", in: arguments)
        ratchet = (ratchetChoice ?? storedRatchet) != .off
    }

    private static let radioStates: [String: RadioState] = [
        "on": .on, "off": .off, "unauthorized": .unauthorized, "unsupported": .unsupported,
    ]

    private static let cameraAnswers: [String: DemoCamera.Answer] = ["denied": .denied, "allowed": .allowed]
}
