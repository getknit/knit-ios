import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A sealed ctl of ours whose store unit is undone leaves our custody as it was, over both store kinds (ADR 2026-10.5sk9,
/// phase P5e; the blobs review's undone units). ``MeshEngine/sealControl(_:to:in:plan:)`` takes an originated frame into
/// our custody inside its unit, before the unit commits, so a unit that fails and one its caller opened and abandons must
/// take that row with them, or our custody would serve a frame that never went, sealed with a chain key the store forgot.
@Suite struct SealedControlUndoTests {
    /// Which ctl of ours is sealed.
    enum Sealing: CaseIterable, Sendable {
        /// Our reaction to a DM.
        case reaction
        /// Our sealed profile, from the fan-out.
        case profile
        /// The answer an init is owed.
        case answer
    }

    /// How its unit is undone.
    enum Undoing: CaseIterable, Sendable {
        /// A store write fails inside it.
        case failed
        /// It runs inside a unit its caller opened, which abandons.
        case abandoned
    }

    /// One ctl, and how its unit is undone.
    struct Undone: Sendable, CustomTestStringConvertible {
        let sealing: Sealing
        let undoing: Undoing

        var testDescription: String { "\(sealing), \(undoing)" }

        /// Every pair.
        static let all = Sealing.allCases.flatMap { sealing in Undoing.allCases.map { Self(sealing: sealing, undoing: $0) } }
    }

    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on over `stores`, and Alice an Android phone pinned with its prekey and the ratchet's bits.
    /// Her first DM started the session, which we hold confirmed, and our answer to its init went; our profile was then
    /// edited, so its sealed copy went to her too. The clock is past the answer's floor, so the DM's init is due one more
    /// answer. Returns the DM's header, which carries that init.
    private func rig(stores: MeshStores) throws -> (EngineFixture, RatchetHeader) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let dm = try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now)
        fixture.deliver(dm, from: android)
        fixture.engine.updateProfile(name: "Dana", status: "", openToChat: false)
        #expect(fixture.engine.answers.introsAnswered == 1 && fixture.ratchetRecords(of: alice).session?.confirmed == true)
        fixture.clock.advance(RatchetAnswers.floorMilliseconds)
        fixture.transport.clear()
        return (fixture, try #require(try ChatContent(decoding: dm.envelope.payload).enc?.ratchet))
    }

    /// Seals `sealing` toward Alice: a reaction to her DM, our sealed profile once more, the fan-out's dedupe forgotten so it
    /// is owed, or the answer her DM's init is due.
    private func seal(_ sealing: Sealing, _ fixture: EngineFixture, header: RatchetHeader) {
        switch sealing {
        case .reaction:
            _ = fixture.engine.react(to: "dm-1", with: "👍")
        case .profile:
            fixture.engine.presentation.sealedProfileVersions[alice.nodeId] = nil
            fixture.engine.broadcastSealedProfile()
        case .answer:
            fixture.engine.answerInit(in: header, from: alice.nodeId)
        }
    }

    /// A reaction, a profile and an answer, each in a unit that fails and in one its caller abandons, over both store kinds:
    /// our custody's live ids stand as they were, no chain advanced, and nothing went on the air. Inside a caller's unit the
    /// fan-out reads no target set and seals nothing at all.
    @Test(arguments: StoreKind.allCases, Undone.all)
    func anUndoneUnitLeavesOurCustodyAsItWas(kind: StoreKind, undone: Undone) throws {
        let directory = scratchDirectory("undone-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let (fixture, header) = try rig(stores: stores)
        let carried = Set(stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
        let records = stores.ratchet.records(of: alice.nodeId)

        switch undone.undoing {
        case .failed:
            refusing.refusesWrites = true
            seal(undone.sealing, fixture, header: header)
            refusing.refusesWrites = false
        case .abandoned:
            let outer = stores.transactor.atomically { () -> Void? in
                seal(undone.sealing, fixture, header: header)
                return nil
            }
            guard case .abandoned = outer else {
                Issue.record("the outer unit abandons: \(outer)")
                return
            }
        }
        let after = Set(stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
        #expect(after == carried, "our custody as it was")
        #expect(stores.ratchet.records(of: alice.nodeId) == records, "no chain advanced")
        #expect(fixture.transport.written.isEmpty, "nothing on the air")
    }
}
