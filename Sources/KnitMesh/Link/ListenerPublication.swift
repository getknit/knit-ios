/// The L2CAP listener of a radio whose stack publishes and unpublishes it asynchronously, as CoreBluetooth's
/// `publishL2CAPChannel` and `unpublishL2CAPChannel` do: what to ask the stack for, and what each answer means. KnitBLE
/// keeps one; KnitBlueZ's listener is a socket it opens and closes synchronously, so it needs none.
///
/// Before this type the radio kept the PSM through `stop()`, and a `start()` one round trip later, as `interop.py
/// iphone-react` sends it, found it still set and published nothing. The late unpublish answer then cleared it, and the
/// iPhone served PSM 192 with nothing listening until the next stop and start: the Pixels that dial it failed for 7
/// minutes (`.agents/context/linux-peer.md`, "What the reaction runs showed").
///
/// So `stop()` forgets the PSM at once, and the next start publishes only once the unpublish is answered. A publish
/// sent behind an unanswered unpublish was handed another PSM, 193 after 192 and back on the next restart, and the
/// Android phones that dial the iPhone first dialed the PSM they had read, failed, and linked only after reading it
/// again, the Pixel 8 at about 35 s. A publish with nothing outstanding gets 192 back, and the Pixel 8 linked on its
/// first dial in 3.5 to 11 s (the iPhone 12, 2026-10-14; "What A4 showed"). The answer came about 0.2 s after the stop.
///
/// The wait is bounded at ``answerWaitMilliseconds``, since a manager that refuses the unpublish never answers it: a
/// stop arms a deadline under a generation, and ``waitEnded(_:)`` with that generation gives up on the answers still
/// owed. A deadline an earlier stop armed does nothing. An answer is matched to its request by counting, never by its
/// PSM, which the new channel may share, and the stack answers in the order it was asked, so the oldest owed answer goes
/// first: a late one is logged and ignored, and clears nothing live.
///
/// A wait that runs out no longer publishes on the same peripheral manager while a recycle is left. In run `3a7576`
/// (knit/knit-ios#53, `.agents/context/linux-peer.md`, "What the blinded GATT reads reruns showed") an unpublish went
/// unanswered, the next publish was answered with PSM 193, and bluetoothd had no endpoint for it: it rejected every
/// incoming channel until Knit was relaunched, which published 192 again. Why is not known. So an expired wait answers
/// ``Expiry/recycle(expired:ordinal:)``: the radio drops the peripheral manager and makes a new one, this type forgets
/// the listener and every answer owed, as at a power-off, and holds the publish until the new manager is powered on
/// (``managerPoweredOn()``). One recycle runs at a time, and at most ``maximumRecycles`` in a process; after that a
/// wait that runs out answers ``Expiry/publish(expired:)``, counts its answers as late and publishes on the same
/// manager, as the radio did before. One case stays open there: a genuine unasked drop that arrives while a late answer
/// is still owed is taken for that answer, and the radio keeps a PSM nothing listens on until its next stop and start
/// or power cycle.
///
/// A stopped radio holds no listener: a publish that lands after a stop is unpublished at once, and the next start
/// publishes anew, so every start that publishes reports the PSM again, and the link manager advertises it.
public struct ListenerPublication: Sendable, Equatable {
    /// How long a start waits for an unpublish's answer before it publishes anyway: well past the 0.2 s seen on the
    /// iPhone 12 with four links up, and the 4 s after which every publish in the A4 series got its PSM back.
    public static let answerWaitMilliseconds = 5000
    /// How many times a process replaces its peripheral manager after an unanswered unpublish before it publishes on the
    /// same one anyway: the maintainer's cap (2026-11-12, knit/knit-ios#53), so a manager that never answers cannot
    /// churn forever.
    public static let maximumRecycles = 3

    /// An unpublish to send, and the generation of the deadline to arm for its answer.
    public struct Unpublish: Sendable, Equatable {
        /// The PSM to unpublish.
        public let psm: UInt16
        /// What to pass ``waitEnded(_:)`` once ``answerWaitMilliseconds`` have passed.
        public let wait: UInt64
    }

    /// What a published answer asks of the radio.
    public enum Published: Sendable, Equatable {
        /// Listen on the PSM, and report it.
        case listening(UInt16)
        /// The radio stopped while the publish was in flight: unpublish the PSM, arm its deadline, and report nothing.
        case unpublish(Unpublish)
    }

    /// What a deadline that came due asks of the radio (``waitEnded(_:)``).
    public enum Expiry: Sendable, Equatable {
        /// Every answer came, or a newer unpublish replaced the deadline: nothing.
        case answered
        /// `expired` answers never came. Drop the peripheral manager and make a new one, the process's `ordinal`th, and
        /// publish once it is powered on (``ListenerPublication/managerPoweredOn()``).
        case recycle(expired: Int, ordinal: Int)
        /// `expired` answers never came, and every recycle is spent or one is already under way: they are late from
        /// now on, and a running radio publishes on the manager it has.
        case publish(expired: Int)
    }

    /// What an unpublish answer meant.
    public enum Unpublished: Sendable, Equatable {
        /// The answer to an unpublish the radio waits on. Once none is owed, a running radio publishes.
        case asked
        /// The answer to an unpublish whose wait ran out. It clears nothing.
        case late
        /// Nothing was asked, and the PSM was the live one: the stack dropped the listener, and a running radio
        /// publishes again.
        case dropped
        /// Nothing was asked, and the PSM is not the live one: a late answer from before a power cycle. Ignored.
        case stray
    }

    /// The PSM published and reported, or `nil` when the radio listens on none.
    public private(set) var psm: UInt16?
    /// Whether a publish is in flight.
    public private(set) var publishing = false
    /// How many unpublishes are in flight and waited on.
    public private(set) var unpublishing = 0
    /// How many unpublishes are in flight past their wait.
    public private(set) var late = 0
    /// The generation of the newest deadline armed. It only grows, through power cycles and recycles too.
    public private(set) var generation: UInt64 = 0
    /// How many times this process replaced its peripheral manager (``maximumRecycles``). Kept through power cycles.
    public private(set) var recycles = 0
    /// Whether a new peripheral manager is on its way to `.poweredOn`, which holds every publish back: until then it
    /// refuses commands unanswered (CoreBluetooth's API MISUSE). Kept through a power-off, which a new manager may report
    /// first.
    public private(set) var recycling = false

    /// A radio that listens on nothing and has asked for nothing.
    public init() {
        // Every member starts empty.
    }

    /// Whether a running, powered-on radio asks for a publish now: not while one is live or in flight, and not while
    /// an unpublish waits on its answer, and not while a new peripheral manager is on its way to `.poweredOn`. A `true`
    /// marks the publish in flight.
    public mutating func shouldPublish() -> Bool {
        guard psm == nil, !publishing, unpublishing == 0, !recycling else {
            return false
        }
        publishing = true
        return true
    }

    /// The radio stops, and its peripheral manager is powered on, so it can take the unpublish. Answers what to
    /// unpublish, if a PSM is live. A publish still in flight is unpublished when it lands (``published(_:running:)``).
    public mutating func stop() -> Unpublish? {
        guard let psm else {
            return nil
        }
        self.psm = nil
        return owe(psm)
    }

    /// The radio stops while its peripheral manager is not powered on, which would refuse an unpublish and never
    /// answer it. The PSM is forgotten, and no answer is counted on.
    public mutating func forget() {
        psm = nil
    }

    /// The stack published `psm`. `running` is whether the radio runs now: it may have stopped since it asked, and
    /// started again too, which keeps the publish.
    public mutating func published(_ psm: UInt16, running: Bool) -> Published {
        publishing = false
        guard running else {
            return .unpublish(owe(psm))
        }
        self.psm = psm
        return .listening(psm)
    }

    /// The stack could not publish. The next ``shouldPublish()`` asks again.
    public mutating func publishFailed() {
        publishing = false
    }

    /// The stack unpublished `psm`, or answered an unpublish with an error, which counts the same. The oldest owed
    /// answer goes first, and a late one is older than any still waited on.
    public mutating func unpublished(_ psm: UInt16) -> Unpublished {
        if late > 0 {
            late -= 1
            return .late
        }
        if unpublishing > 0 {
            unpublishing -= 1
            return .asked
        }
        guard psm == self.psm else {
            return .stray
        }
        self.psm = nil
        return .dropped
    }

    /// The deadline armed under `wait` came due. Answers ``Expiry/answered`` for a deadline a newer unpublish replaced, or
    /// one whose answers came. Otherwise it gives up on the answers owed: while a recycle is left and none is under way it
    /// forgets everything the old manager owed or held, as ``poweredOff()`` does, so that manager's answer, which never
    /// comes, leaves nothing counted that would file the new manager's first answer as late; else it counts them late.
    public mutating func waitEnded(_ wait: UInt64) -> Expiry {
        guard wait == generation, unpublishing > 0 else {
            return .answered
        }
        let expired = unpublishing
        guard !recycling, recycles < Self.maximumRecycles else {
            late += expired
            unpublishing = 0
            return .publish(expired: expired)
        }
        let spent = recycles + 1
        let next = generation &+ 1
        self = Self()
        generation = next
        recycles = spent
        recycling = true
        return .recycle(expired: expired, ordinal: spent)
    }

    /// The peripheral manager is powered on. Answers whether it was a new one a recycle made, which lets a running radio
    /// publish again: the radio's own state stayed on through the recycle, so nothing else resumes it.
    public mutating func managerPoweredOn() -> Bool {
        defer { recycling = false }
        return recycling
    }

    /// The radio went off, reset or lost its permission. Its channels are taken as gone, as the radio always has, and
    /// the answers still owed are no longer counted on. One that comes late anyway is ``Unpublished/stray``, or at
    /// worst ``Unpublished/dropped``, which costs only a second publish. Any deadline armed before does nothing. The
    /// recycles spent stay spent, and a recycle under way still waits for its manager's `.poweredOn`.
    public mutating func poweredOff() {
        let next = generation &+ 1
        let spent = recycles
        let pending = recycling
        self = Self()
        generation = next
        recycles = spent
        recycling = pending
    }

    private mutating func owe(_ psm: UInt16) -> Unpublish {
        unpublishing += 1
        generation &+= 1
        return Unpublish(psm: psm, wait: generation)
    }
}
