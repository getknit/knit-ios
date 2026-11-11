public import KnitMesh

/// Where `advert` keeps the blinded advert's runtime switch, and what only the host reads of its radio (ADR 2026-11.prsp, "The
/// bridge and the harness"): a debug build's app keeps the switch in its defaults (`debug.launch.blind`) and reads its
/// CoreBluetooth server, and knit-peer keeps it in memory and has no server to report. A release build has no bridge.
public protocol AdvertHost: Sendable {
    /// The build gate, as the links were configured (``LinkManager/Configuration/blindsAdvert``).
    var build: Bool { get }
    /// The switch while nothing is stored: a debug build's default, knit-peer's `--blind`.
    var defaultSwitch: Bool { get }
    /// The stored switch: `on` or `off`, or `clear` while nothing is stored and the default stands.
    func stored() async -> AdvertSwitchChange
    /// Stores the switch, or with `clear` forgets it.
    func store(_ change: AdvertSwitchChange) async
    /// The radio's GATT server, read where the radio keeps it, or `nil` for a radio with none to report.
    func serving() async -> GattServingReport?
}

/// How long `advert`'s `blind` waits for the air to follow (about 6 s, as Android's bridge waits), and how often it looks.
public struct AdvertWait: Sendable {
    /// How many looks after the first.
    public let looks: Int
    /// The pause between looks.
    public let every: Duration

    /// Android's bound, about 6 s.
    public static let standardLooks = 30
    public static let standardEveryMilliseconds = 200
    public static let standardEvery = Duration.milliseconds(standardEveryMilliseconds)

    /// ``standardLooks`` looks ``standardEvery`` apart, unless a test says otherwise.
    public init(looks: Int = standardLooks, every: Duration = standardEvery) {
        self.looks = looks
        self.every = every
    }
}

/// Whether the switch, stored as `want`, is on the air (Android's `AdvertSwitch.verdict`, `AdvertDiag.kt` at `cad69c77b`). The
/// writer airs what ``LinkManager/blinds`` says, never the switch alone: with no presence keys attached it stays clear
/// whatever is stored. So the wait ends when the form on the air, and the radio's server, match what the writer should air.
/// Pure.
public enum AdvertSwitch {
    /// Why it did not apply, as the reply names it.
    public enum Why: String, Sendable, Equatable {
        case notRunning = "transport not running"
        /// The radio is down: the switch applies at the next bring-up.
        case radioDown = "radio down"
        /// Asked on, the writer airs the clear form: it has no presence keys to mint tags from.
        case noMarkStore = "no mark store"
        /// A rotation's tag was still being chosen at the bound.
        case pending = "pending"
        case timeout = "timeout"
    }

    /// Applied, or not and why, or neither yet (``waiting``).
    public struct Verdict: Sendable, Equatable {
        public let applied: Bool
        public let why: Why?

        /// Not applied and no reason yet: the air may still follow.
        public static let waiting = Self(applied: false, why: nil)
    }

    /// The verdict now, ``Verdict/waiting`` to keep waiting: `running` is the mesh's, `status` the link manager's, `serving`
    /// the radio's server (`nil` for a radio with none), `timedOut` whether the bound passed.
    public static func verdict(running: Bool, want: Bool, status: AdvertStatus, serving: GattServingReport?, timedOut: Bool) -> Verdict {
        guard running else {
            return Verdict(applied: false, why: .notRunning)
        }
        guard status.radioUp else {
            return Verdict(applied: false, why: .radioDown)
        }
        let wanted: AdvertStatus.Kind = status.blinding ? .tag : .clear
        let served = serving.map { $0.applied(blinded: status.blinding) } ?? true
        guard !status.pending, status.form == wanted, served else {
            return timedOut ? Verdict(applied: false, why: status.pending ? .pending : .timeout) : .waiting
        }
        return status.blinding == want ? Verdict(applied: true, why: nil) : Verdict(applied: false, why: .noMarkStore)
    }
}

/// What `advert`'s `blind` asks of the blinded advert's runtime switch, and what a host says it holds.
public enum AdvertSwitchChange: Equatable, Sendable {
    /// On.
    case on
    /// Off.
    case off
    /// Nothing stored: the build's default stands.
    case clear

    /// The change `word` names: `on`, `off` or `clear`, and nothing else.
    init?(word: String) {
        switch word {
        case "on":
            self = .on
        case "off":
            self = .off
        case "clear":
            self = .clear
        default:
            return nil
        }
    }
}

extension ControlRequest {
    /// `advert` and `advert-rotate` from a line's `cmd` and `blind`, or `nil` for any other command.
    static func advertCommand(_ cmd: String, blind: String?) -> Result<ControlCommand, ControlError>? {
        switch cmd {
        case "advert":
            guard let blind else {
                return .success(.advert(nil))
            }
            return AdvertSwitchChange(word: blind).map { .success(.advert($0)) } ?? .failure(.invalid("blind"))
        case "advert-rotate":
            return .success(.advertRotate)
        default:
            return nil
        }
    }
}

// `advert` and `advert-rotate`: apart from the actor only to keep its file inside the lint's length.
extension MeshControl {
    /// `advert` or `advert-rotate`.
    func answerAdvert(_ command: ControlCommand) async -> Result<[String: JSONValue], ControlError> {
        guard case .advert(let change) = command else {
            return await advertRotate()
        }
        return await advert(change)
    }

    /// `advert`, storing the switch first when `change` asks, then waiting for the air (``AdvertSwitch``).
    func advert(_ change: AdvertSwitchChange?) async -> Result<[String: JSONValue], ControlError> {
        guard let host = advert.host else {
            return .failure(.refused("this node has no blinded advert"))
        }
        var reply: [String: JSONValue] = ["build": .bool(host.build)]
        if let change {
            await host.store(change)
            if host.build {
                let want = change == .clear ? host.defaultSwitch : change == .on
                await mesh.setBlinding(want)
                let verdict = await awaitSwitch(want, host)
                reply["applied"] = .bool(verdict.applied)
                reply["why"] = .text(verdict.why?.rawValue)
            } else {
                reply["applied"] = false
                reply["why"] = "build"
            }
        }
        let stored = await host.stored()
        reply["switch"] = [
            "value": .bool(stored == .clear ? host.defaultSwitch : stored == .on),
            "stored": stored == .clear ? .null : .bool(stored == .on),
            "default": .bool(host.defaultSwitch),
        ]
        for (key, value) in await advertFields(host) where reply[key] == nil {
            reply[key] = value
        }
        return .success(reply)
    }

    /// `advert-rotate`: one forced rotation, refused as ``ForcedRotation`` says, or while the radio's payload add is in
    /// flight, then `advert`'s fields.
    func advertRotate() async -> Result<[String: JSONValue], ControlError> {
        guard let host = advert.host else {
            return .failure(.refused("this node has no blinded advert"))
        }
        let settling = await host.serving()?.pendingSerial != nil
        let result = await mesh.forceRotation(radioSettling: settling)
        var reply: [String: JSONValue] = [
            "build": .bool(host.build),
            "rotated": .bool(result.rotated),
            "why": .text(result.refused?.rawValue),
            "epochBefore": .int(Int64(result.epochBefore)),
            "epochAfter": .int(Int64(result.epochAfter)),
        ]
        for (key, value) in await advertFields(host) where reply[key] == nil {
            reply[key] = value
        }
        return .success(reply)
    }

    /// Waits, bounded by the advert's ``AdvertWait``, for the verdict on `want`.
    private func awaitSwitch(_ want: Bool, _ host: any AdvertHost) async -> AdvertSwitch.Verdict {
        var looks = 0
        var verdict = await judge(want, host, timedOut: false)
        while verdict == .waiting {
            try? await Task.sleep(for: advert.wait.every)
            looks += 1
            verdict = await judge(want, host, timedOut: looks >= advert.wait.looks)
        }
        return verdict
    }

    /// The verdict on `want` now.
    private func judge(_ want: Bool, _ host: any AdvertHost, timedOut: Bool) async -> AdvertSwitch.Verdict {
        let running = await mesh.isRunning
        let status = await mesh.advertStatus
        let serving = await host.serving()
        return AdvertSwitch.verdict(running: running, want: want, status: status, serving: serving, timedOut: timedOut)
    }

    /// The link manager's status and the radio's server as the reply's fields.
    private func advertFields(_ host: any AdvertHost) async -> [String: JSONValue] {
        var fields = ControlLines.fields(of: await mesh.advertStatus)
        fields["running"] = .bool(await mesh.isRunning)
        fields["gatt"] = await host.serving().map(ControlLines.describe) ?? .null
        return fields
    }
}
