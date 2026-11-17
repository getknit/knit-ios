import KnitStore
import KnitWire

/// The frames refused for what they are rather than for a failed check, and their counts, which the driver and `status`
/// read under Android's names (`MeshMetrics`).
extension MeshEngine {
    /// Group frames custody refused because their roster is not their own (knit-next ADR 2026-10.7mqm).
    public var groupCustodyRefused: Int { custody.groupRefusedCount }

    /// Frames custody refused because their `signed` is longer than its byte cap (knit-next #227). Each was still delivered
    /// and relayed.
    public var custodyOversizeRefused: Int { custody.oversizeRefusedCount }

    /// Profiles refused because their `signed` is longer than custody's profile cap (ADR 2026-10.r88m): those refused at
    /// the door before they were read, and our own custody refused. A profile the door refuses never reaches custody, so
    /// each is counted once. Each was still relayed.
    public var profileOversizeRefused: Int { profileDoorRefused + custody.profileOversizeRefusedCount }

    /// Whether `frame` is a profile whose `signed` is longer than ``CustodyLimits/maxProfileSignedBytes``, refused before
    /// anything decodes its payload (ADR 2026-10.r88m). The cap is read from custody's store, so the door and custody bound
    /// the same frames and a rig that lowers one lowers both. Only `signed` counts, never `sig`, and exactly the cap is
    /// kept. The largest profile an honest build authors is about an eighth of it, so nothing honest is refused. Counted,
    /// and logged with the id's first characters and the length, never the payload; not a ``DropReason``, so it is never
    /// read as a missing key.
    func refusesOversizeProfile(_ frame: InboundFrame) -> Bool {
        refusesOversizeProfile(type: frame.envelope.type, id: frame.envelope.id, signedCount: frame.wire.signed.count)
    }

    /// ``refusesOversizeProfile(_:)`` over a frame's type, id and `signed` length: what the spool's door reads before it
    /// verifies a candidate (ADR 2026-11.adrq, P4a).
    func refusesOversizeProfile(type: FrameType, id: String, signedCount length: Int) -> Bool {
        guard type == .profile, length > stores.custody.limits.maxProfileSignedBytes else {
            return false
        }
        profileDoorRefused += 1
        log.log(.debug, "mesh refused \(id.prefix(CustodySync.idCharacters)) (profile): \(length) signed bytes over the profile cap")
        return true
    }
}
