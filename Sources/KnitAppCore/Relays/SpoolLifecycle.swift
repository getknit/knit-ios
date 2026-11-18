public import KnitMesh
public import KnitWire

/// Where the app's scene stands, as SwiftUI's `ScenePhase` says it.
public enum AppPhase: Sendable, Equatable {
    /// Gone from the screen: iOS may suspend Knit.
    case background
    /// On screen under Control Center, an alert or the app switcher.
    case inactive
    /// At the front.
    case active
}

/// When the spool runs (ADR 2026-11.adrq, P6): only at the front, with the gate open. A pure value: what the one serial
/// stream into the mesh (``MeshPhases``) folds each input into, in order.
///
/// - **One wanted state:** `wanted = gate && foreground`. `foreground` starts `false` (a launch, Bluetooth's restoration
///   in the background among them, has no scene yet), turns `true` on ``AppPhase/active``, `false` on
///   ``AppPhase/background``, and stays on ``AppPhase/inactive``, so Control Center or an alert over Knit keeps the
///   sockets.
/// - **Steps only on an edge.** The spool resumes when `wanted` turns true (the process's first `.active`, the first
///   `.active` after a `.background`, or the switch turned on at the front) and pauses when it turns false. Nothing else
///   resumes: a launch's own reading of the application's state sets the links' background alone.
public struct SpoolLifecycle: Sendable, Equatable {
    /// What the stream carries in.
    public enum Input: Sendable, Equatable {
        /// The environment started, in the background or not: the links hear it, the spool does not.
        case launched(background: Bool)
        /// The scene moved to `phase`.
        case scene(AppPhase)
        /// The gate (a debug build, the switch on, the consent current) opened or closed.
        case gate(Bool)
        /// Carry `handle` at `url` from now on.
        case add(SpoolRelayHandle, AcceptedSpoolURL)
        /// Drop `handle`.
        case remove(SpoolRelayHandle)
    }

    /// What the mesh is told, in order.
    public enum Step: Sendable, Equatable {
        case background(Bool)
        case pause
        case resume
        case add(SpoolRelayHandle, AcceptedSpoolURL)
        case remove(SpoolRelayHandle)
    }

    /// Whether the gate is open.
    public private(set) var gate = false
    /// Whether the scene is at the front, or under something that keeps it on screen.
    public private(set) var foreground = false

    /// A lifecycle before any scene: paused.
    public init() {
        // Nothing wanted until a scene comes to the front with the gate open.
    }

    /// Whether the spool should run.
    public var wanted: Bool { gate && foreground }

    /// Folds `input` in and answers what the mesh is told, in order.
    public mutating func apply(_ input: Input) -> [Step] {
        let was = wanted
        var steps: [Step] = []
        switch input {
        case .launched(let background):
            return [.background(background)]
        case .scene(let phase):
            steps.append(.background(phase == .background))
            switch phase {
            case .active:
                foreground = true
            case .background:
                foreground = false
            case .inactive:
                break
            }
        case .gate(let open):
            gate = open
        case .add(let handle, let url):
            return [.add(handle, url)]
        case .remove(let handle):
            return [.remove(handle)]
        }
        if wanted != was {
            steps.append(wanted ? .resume : .pause)
        }
        return steps
    }
}
