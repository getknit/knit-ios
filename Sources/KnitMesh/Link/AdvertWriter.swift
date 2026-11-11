import KnitWire

/// The one writer of our advert (`AdvertWriter`, `AdvertWriter.kt:34-289` at knit-next `cad69c77b`; ADR 2026-11.prsp): every
/// push builds from one snapshot, the form on the air, the form before it and the PSM it names (``Aired``), replaced whole
/// and only by ``install(form:previous:psm:)`` (a rotation, a bring-up, a switch flip) or ``repoint(psm:)`` (the listener
/// came back on another PSM under the same forms).
///
/// The rules it keeps, each pinned by `AdvertWriterTests`:
/// - **Nothing airs while a tag is pending.** Between ``begin()`` (or a blinding ``up(pendingTag:)``) and the install,
///   ``push(_:)`` hands nothing over; it notes that a push was wanted, and the install's push serves it.
/// - **A blinded snapshot never airs the id.** Every payload a push would hand the radio is checked last: bytes 1–16 must be
///   the snapshot's form and its flag must say so, a tag never the node id and the id never under the flag. Any other is
///   dropped and counted (``clearRefused``).
/// - **A snapshot the radio went down under stays down** (``down()``) until an install replaces it, so a bring-up never
///   restarts the last session's form.
///
/// Android's writer also guards an install against a teardown that came first on another thread (its epoch), and swaps
/// advertising sets, retiring the old ones before the new start. Here the link manager chooses and installs a tag in one call
/// on the `Mesh` actor, so no teardown can come between, and an iPhone has one GATT value, which the radio replaces (Phase 3's
/// add-before-remove): a push hands one payload to ``Radio/advertise(_:)``. Pure and single-threaded.
internal struct AdvertWriter {
    /// What is on the air: the form, the one before it, and the PSM, from one install (`Aired`, `:58-73`). `installs` is
    /// how many snapshots this writer had installed when it put this one up, counting it.
    struct Aired: Equatable, CustomStringConvertible {
        let form: AdvertOrder.Form
        let previous: AdvertOrder.Form?
        let psm: UInt16
        let installs: Int

        /// The form's own redacted printing, never the tag.
        var description: String { "Aired(\(form), installs: \(installs))" }
    }

    /// This node, which a clear snapshot's payload must name and a blinded one's never.
    let localId: NodeId
    /// The snapshot on the air, or the last one while the radio is down; `nil` before the first.
    private(set) var aired: Aired?
    /// Whether the radio is up (``up(pendingTag:)`` since the last ``down()``).
    private(set) var isUp = false
    /// Whether a rotation's tag is being chosen.
    private(set) var pending = false
    /// Whether a push was asked for while a tag was pending.
    private(set) var pushWanted = false
    /// Payloads dropped because they did not carry the snapshot's form alone.
    private(set) var clearRefused = 0
    /// Snapshots installed so far.
    private(set) var installs = 0
    /// The snapshot was stopped by ``down()`` and nothing has replaced it since: nothing pushes it again.
    private var stale = false

    /// A writer for `localId`'s advert.
    init(localId: NodeId) {
        self.localId = localId
    }

    /// The radio came up: while blinding (`pendingTag`), nothing airs until a rotation installs its tag (`up`, `:125-145`).
    mutating func up(pendingTag: Bool) {
        isUp = true
        pending = pendingTag
        pushWanted = false
    }

    /// A rotation begins: nothing airs until its install (`begin`, `:148-152`).
    mutating func begin() {
        pending = true
    }

    /// The radio went down (a stop, Bluetooth off): pushes stop until a bring-up installs again (`down`, `:169-181`).
    mutating func down() {
        isUp = false
        stale = true
        pending = false
        pushWanted = false
    }

    /// Puts a new snapshot on the air; the caller pushes next (`install`, `:191-210`). The caller installs only while the
    /// radio is up.
    mutating func install(form: AdvertOrder.Form, previous: AdvertOrder.Form?, psm: UInt16) {
        installs += 1
        aired = Aired(form: form, previous: previous, psm: psm, installs: installs)
        stale = false
        pending = false
        pushWanted = false
    }

    /// The listener came back on `psm` under the same forms: the snapshot is replaced whole, its stamp kept, as Android's
    /// Coded power change keeps it (`replaceCoded`, `:213-228`). Nothing while no snapshot stands.
    mutating func repoint(psm: UInt16) {
        guard let current = aired, current.psm != psm else {
            return
        }
        aired = Aired(form: current.form, previous: current.previous, psm: psm, installs: current.installs)
    }

    /// The payload to hand the radio now, built by `encode` from the snapshot, or `nil`: the radio is down or its snapshot
    /// stale, a tag is pending (noted, so the install pushes), or the payload does not carry the snapshot's form alone
    /// (dropped and counted) (`push`, `:235-264`).
    mutating func push(_ encode: (Aired) -> AdvertPayload) -> AdvertPayload? {
        guard isUp, !stale else {
            return nil
        }
        guard !pending else {
            pushWanted = true
            return nil
        }
        guard let current = aired else {
            return nil
        }
        let payload = encode(current)
        guard carriesOnly(current.form, payload) else {
            clearRefused += 1
            return nil
        }
        return payload
    }

    /// The last check before bytes reach the radio (`carriesOnly`, `:270-278`): a blinded form's payload carries its tag
    /// under the flag and never the id; a clear one carries the id without the flag.
    private func carriesOnly(_ form: AdvertOrder.Form, _ payload: AdvertPayload) -> Bool {
        guard payload.blinded == form.blinded else {
            return false
        }
        guard form.blinded else {
            return payload.advertised == localId
        }
        return payload.advertised == form.advertised && payload.advertised != localId
    }
}
