import KnitWire

/// Who dials before a link exists, once a presence advert can name a rotating tag instead of the node id (knit-next ADR
/// 2026-11.xp6d, `AdvertOrder.kt` at `cad69c77b`; ADR 2026-11.sv5t). It replaces every raw `localId > peer` the link
/// manager reads to decide who dials, with this node's own form (``Mine``) as an input. While the iPhone airs its id its form
/// is `clear(localId)` and every rule here reads the classic order; while it blinds, ``Mine`` is the aired snapshot's current
/// and previous forms (ADR 2026-11.prsp).
///
/// The rule, from one phone's side (``iDial(_:_:)``):
/// - **Equal forms never dial.** My own advert, or a tag that collides with mine.
/// - **Against a clear advert:** a blinding phone dials; a clear one keeps the classic order (the larger id dials).
/// - **Against a blinded advert:** a blinding phone dials when its tag sorts above theirs; a clear phone never does,
///   leaving the dial to the blinding side, which dials every clear advert it hears.
///
/// That is antisymmetric for every pair of forms, so exactly one side dials whenever both hear each other's current form.
/// The order compares the 26-character base32 strings as ASCII, which ``NodeId``'s `<` does: digits sort below letters,
/// so it is not byte order (`interop.md`).
///
/// Pure, free of a clock.
internal enum AdvertOrder {
    /// A peer's advertised form: ``advertised`` is advert bytes 1–16 (``AdvertPayload/advertised``), a node id when
    /// ``blinded`` is false and a tag when the advert's `FLAG_BLINDED` was set (`AdvertOrder.Form`, `AdvertOrder.kt:54-69`).
    struct Form: Hashable, Sendable, CustomStringConvertible {
        /// The characters a printed form shows: a tag's are always `zzzz`.
        private static let shown = 4

        /// Advert bytes 1–16, as a 26-character form.
        let advertised: NodeId
        /// Whether the advert said the bytes are a tag.
        let blinded: Bool

        /// Redacted, so no log line pairs a tag with an id: the first four characters only.
        var description: String { "Form(\(advertised.string.prefix(Self.shown))…, blinded: \(blinded))" }

        /// A clear advert: the node id itself.
        static func clear(_ nodeId: NodeId) -> Self {
            Self(advertised: nodeId, blinded: false)
        }

        /// The form of `advert`, as it was heard.
        static func of(_ advert: AdvertPayload) -> Self {
            Self(advertised: advert.advertised, blinded: advert.blinded)
        }

        /// The dialer's form from its HELLO: its `t` field (``Hello/told``), or its node id when the HELLO carries none (a
        /// build that never blinds). A `t` equal to the HELLO's id is clear; any other is a tag (`Form.fromHello`, `:65-68`).
        static func fromHello(_ helloId: NodeId, told: [UInt8]?) -> Self {
            guard let told, let form = NodeId(bytes: told), form != helloId else {
                return clear(helloId)
            }
            return Self(advertised: form, blinded: true)
        }
    }

    /// My own advertised forms, read as one snapshot by every role that judges order: ``current`` is what I air now,
    /// ``previous`` what I aired before my last rotation (`AdvertOrder.Mine`, `:80-92`), both from the one aired snapshot the
    /// writer replaces whole (``AdvertWriter``), so no reader sees a current from one rotation beside a previous from another.
    struct Mine: Hashable, Sendable {
        /// What I air now.
        let current: Form
        /// What I aired before my last rotation, if any.
        let previous: Form?

        /// Whether I air a tag now.
        var blinded: Bool { current.blinded }

        /// A phone that airs its id: every pre-link role then reads the classic order.
        static func clear(_ nodeId: NodeId) -> Self {
            Self(current: .clear(nodeId), previous: nil)
        }
    }

    /// Whether I, advertising `mine`, dial a peer advertising `theirs` before any link (`iDial`, `:94-103`).
    static func iDial(_ mine: Form, _ theirs: Form) -> Bool {
        if mine.advertised == theirs.advertised {
            return false
        }
        if !theirs.blinded {
            return mine.blinded || theirs.advertised < mine.advertised
        }
        if !mine.blinded {
            return false
        }
        return theirs.advertised < mine.advertised
    }

    /// The form of mine a dialer's HELLO `a` names (`dialed`, ``Hello/addressed``), honoured only when it is my `current` or
    /// `previous` advertised form; `nil` when absent or neither (`dialedForm`, `:133-143`).
    static func dialedForm(current: Form, previous: Form?, dialed: NodeId?) -> Form? {
        guard let dialed else {
            return nil
        }
        if dialed == current.advertised {
            return current
        }
        if let previous, dialed == previous.advertised {
            return previous
        }
        return nil
    }

    /// The responder's order check: whether I should have dialed this `dialer` instead (its form from its HELLO,
    /// ``Form/fromHello(_:told:)``), judged on the form of mine it says it dialed (``dialedForm(current:previous:dialed:)``)
    /// so a dial made against my previous tag is judged as the dialer saw it, and otherwise against my current form
    /// (`responderShouldHaveDialed`, `:151-156`). True is the responder's "we dial it" refusal.
    static func responderShouldHaveDialed(current: Form, previous: Form?, dialed: NodeId?, dialer: Form) -> Bool {
        iDial(dialedForm(current: current, previous: previous, dialed: dialed) ?? current, dialer)
    }

    /// Whether a dialer's HELLO `t` and `a` count in ``outOfOrder(_:dialer:told:addressed:honoured:)``: before the proof only
    /// when the HELLO offers one, and after it (`late`) only when it was `proven` (`BleAdmissionPolicy.honours`,
    /// `BleAdmissionPolicy.kt:127-131`; the security design pass of knit-next ADR 2026-11.xp6d). This port registers a
    /// proving dialer only after its proof, so both passes read the same; the gate is pinned here either way.
    static func honours(offersProof: Bool, proven: Bool, late: Bool) -> Bool {
        late ? proven : offersProof
    }

    /// The responder's order check on advertised forms: whether I, airing `mine`, should have dialed the dialer whose HELLO
    /// names `dialer`, tells `told` (its `t`) and says it dialed `addressed` (its `a`), each honoured only when `honoured`
    /// (``honours(offersProof:proven:late:)``), and a `t` other than the id only when it carries the tag prefix
    /// (`BleAdmissionPolicy.outOfOrder`, `:145-155`). True is the "we dial it" refusal. A dialer with neither field, or not
    /// honoured, is judged as `Form.clear(dialer)`: for a clear `mine`, exactly the classic `dialer < local`. So a blinding
    /// Android whose real id sorts below ours, proving itself, is admitted.
    static func outOfOrder(_ mine: Mine, dialer: NodeId, told: [UInt8]?, addressed: [UInt8]?, honoured: Bool) -> Bool {
        let tag = told.flatMap(NodeId.init(bytes:)).flatMap { form in
            honoured && (form == dialer || AdvertForm.hasTagPrefix(form.bytes)) ? form : nil
        }
        let dialed = addressed.flatMap(NodeId.init(bytes:)).flatMap { honoured ? $0 : nil }
        return responderShouldHaveDialed(
            current: mine.current,
            previous: mine.previous,
            dialed: dialed,
            dialer: .fromHello(dialer, told: tag?.bytes)
        )
    }

    /// The held-link row (`heldLinkRow`, `BleAdmissionPolicy.kt:170-181` at knit-next `cad69c77b`; ADR 2026-11.prsp's
    /// `RefuseHeld`): a dialer whose proven link we already hold (`heldProven`) and whose honoured HELLO `a` names a **blinded**
    /// form of mine, current or previous, missed my rotation. It is refused with no reply, and my tag goes to it over the held
    /// link, so a dial and the duplicate it makes cannot close both links.
    ///
    /// Gated on a blinded form, never on any form of mine: every clear dial carries `a` = the dialed id, so a row on "a names
    /// mine" would fire on every redial after a link died on the dialer's side only, and take ADR 2026-09.6es2's replace
    /// away. So it never fires while I air my id and aired none before. A held link whose HELLO carried `CAP_DOORBELL`
    /// never takes it (`heldDoorbell`: its peer may sleep with bytes queued), and nor does a quiet one (`heldQuiet`), so a
    /// link dead on the dialer's side reaches the replace instead.
    static func heldLinkRow( // swiftlint:disable:this function_parameter_count - the row's inputs, each a row's own source
        _ mine: Mine, addressed: [UInt8]?, honoured: Bool, heldProven: Bool, heldQuiet: Bool, heldDoorbell: Bool
    ) -> Bool {
        let live = heldProven && !heldQuiet && !heldDoorbell
        let dialed = addressed.flatMap(NodeId.init(bytes:))
        return honoured && live && dialedForm(current: mine.current, previous: mine.previous, dialed: dialed)?.blinded == true
    }

    /// The blinding-only row (`RefuseLegacy`, `BleAdmissionPolicy.kt:115`): while I air a tag, a dialer whose HELLO lacks
    /// `CAP_BLIND_ADVERT` dialed a form it cannot have meant and would fail at our reply, so it is refused first, with no
    /// reply and no HELLO written.
    static func refusesLegacy(_ mine: Mine, readsTags: Bool) -> Bool {
        mine.blinded && !readsTags
    }
}
