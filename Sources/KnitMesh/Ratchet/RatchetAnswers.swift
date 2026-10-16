import KnitWire

/// The answers we owe a peer whose ratchet frames still carry its X3DH init, pure: IntroSync's answer half (`IntroSync.kt`
/// at knit-next `cbf2a487`: `lastAnswered` and `owed`, `:97-115`; `onProfilePinned`, `:185-196`; `onPeerFrameOpened`,
/// `:221-240`; `ANSWER_FLOOR_MS`, `:351-352`), which the engine asks and acts on (ADR 2026-10.5sk9, phase P5e).
///
/// A frame whose header still carries its sender's init proves the sender has seen no frame of ours: an initiator attaches
/// its init until a frame of ours confirms it. One sealed frame from us does, so each init that opens earns one answer,
/// and the same init another only once ``floorMilliseconds`` has passed, since a peer re-floods its init on every frame
/// until it confirms. The floor is the last init answered per peer, not one per peer (knit-next #87): a reset is a new
/// init, whose resetter confirms only on a frame we seal under the new root, and after a reset the peer often has nothing
/// else to send, since its re-seals reuse ids we already hold. A reset marked under an init (`FLAG_RESET`) earns that init
/// one answer more: read first read-only, as a race remnant, the init had its answer under the old session, and the
/// marked frame is the one we adopt. A marked init's answer covers its plain repeats, never the reverse
/// (`IntroSync.kt:229`).
///
/// An init that opens before we can seal to its sender is owed, not dropped (knit-next `937cf785`): opening needs only the
/// pinned bundle, and sealing the `CAP_RATCHET` and the prekey that only the sender's cleartext profile pins. The debt is
/// recorded before the attempt, as Kotlin publishes it before its check (`:231-235`), so an attempt that cannot seal yet
/// leaves it owed until such a profile pins, and a profile that pins without the ratchet forgives it (`:186-188`). One
/// debt is held per peer, the newest init's.
///
/// Held in memory, on our monotonic clock, as Kotlin holds its floors and debts in memory (`:97-115`), where its floors
/// read the wall clock. A restart forgets both. An init still riding is answered once more by its next live frame, which
/// the peer absorbs, and a debt owed when the process ended dies with it: the profile that pins after the restart finds
/// nothing owed, and the init is left to its sender's next frame or to our first frame under the session, since the
/// start's replay answers nothing. The intro send half (contact cards, `pending`, `grace` and the spool's pair scopes)
/// waits for Contacts (ADR 2026-10.5sk9), and the single actor leaves no gap between a check and its use for Kotlin's
/// claim to close (`owed.remove(peerId, debt)`, `:236-237`).
internal struct RatchetAnswers {
    /// How long the same init waits for a second answer (`ANSWER_FLOOR_MS`, `IntroSync.kt:352`): bounds a peer that keeps
    /// re-flooding its init.
    static let floorMilliseconds: Int64 = 3_600_000

    /// An init one of the peer's frames carried: its ephemeral, which names it (knit-next ADR 027), and whether the frame
    /// was marked as a reset.
    struct Init: Equatable {
        /// The init's ephemeral public key.
        let eph: [UInt8]
        /// Whether the frame's header carried `FLAG_RESET`.
        let resetFlagged: Bool

        /// The init `header` carries, or `nil` for a header with none: a confirmed peer, never answered.
        init?(_ header: RatchetHeader) {
            guard let initial = header.initial else {
                return nil
            }
            self.init(eph: initial.eph, resetFlagged: header.flags & RatchetHeader.resetFlag != 0)
        }

        /// An init as given.
        init(eph: [UInt8], resetFlagged: Bool) {
            self.eph = eph
            self.resetFlagged = resetFlagged
        }
    }

    /// The init last answered for one peer, and when (`Answered`, `IntroSync.kt:105-109`).
    private struct Answered {
        let initial: Init
        let at: Int64
    }

    private var answered: [NodeId: Answered] = [:]
    private var owed: [NodeId: Init] = [:]

    /// Whether `initial`, carried by a frame from `peer` that opened at `now`, is due an answer, recorded as owed when it
    /// is (`IntroSync.kt:228-234`): it is, unless the same init was answered less than ``floorMilliseconds`` ago, by an
    /// answer that covers it.
    mutating func owe(_ initial: Init, to peer: NodeId, now: Int64) -> Bool {
        if let last = answered[peer], Self.covers(last.initial, initial), now &- last.at < Self.floorMilliseconds {
            return false
        }
        owed[peer] = initial
        return true
    }

    /// Whether the answer `given` to an init covers `initial`: the same init by its ephemeral's bytes, and a marked one's
    /// answer covers its plain repeats, never the reverse (`IntroSync.kt:229`).
    private static func covers(_ given: Init, _ initial: Init) -> Bool {
        given.eph == initial.eph && (given.resetFlagged || !initial.resetFlagged)
    }

    /// Our answer to `initial` went at `now`: its floor starts and the debt is paid (`IntroSync.kt:236-239`).
    mutating func answered(_ initial: Init, of peer: NodeId, at now: Int64) {
        answered[peer] = Answered(initial: initial, at: now)
        owed[peer] = nil
    }

    /// Our answer to `peer` could not be sealed, though it could read one: the debt goes with no floor, which Kotlin
    /// removes whole when its send fails (`lastAnswered.remove`, `IntroSync.kt:237-239`), so the next frame carrying the
    /// init tries again.
    mutating func unanswered(_ peer: NodeId) {
        answered[peer] = nil
        owed[peer] = nil
    }

    /// The debt owed `peer`, taken, now that a profile of theirs carrying the ratchet pinned (`IntroSync.kt:195`): the
    /// caller tries it again, floor and all, as Kotlin calls `onPeerFrameOpened` with it.
    mutating func takeDebt(of peer: NodeId) -> Init? {
        owed.removeValue(forKey: peer)
    }

    /// Forgives what `peer` is owed: a profile of theirs pinned without the ratchet, so nothing can be sealed to it
    /// (`ratchetless`, `IntroSync.kt:186-188`).
    mutating func forgive(_ peer: NodeId) {
        owed[peer] = nil
    }
}
