import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our sealed profile with the ratchet's switch on (ADR 2026-10.5sk9, phase P5e): `broadcastSealedProfile`,
/// `currentProfilePayload` and `sendCtlDm` (`MeshManager.kt:2812-2951`, at knit-next `cbf2a487`), read by Android's own
/// session layer (``AndroidPeer``). Each edit of what we present goes as the cleartext profile to everyone and as a sealed
/// `CTL_PROFILE` to every peer we hold a confirmed session with, deduped per peer and version; the heal sends it to the
/// sessions that confirmed since. `MeshManagerTest` names no case of its own for it (its rig keeps the version at 0 to
/// leave the fan-out out, `MeshManagerTest.kt:499`); knit-next's are `ProfileUpdateLabTest`'s, which
/// `RatchetPresentationLabTests` ports through two engines.
@Suite struct MeshEngineSealedProfileTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on, Alice an Android phone pinned with its prekey and the ratchet's bits, and, when
    /// `confirmed`, the session she initiated with her first DM, which our responder side holds confirmed. What that wrote,
    /// our answer to her init and our receipt, is cleared.
    private func rig(stores: MeshStores = .inMemory(), confirmed: Bool = true) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        if confirmed {
            fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now), from: android)
            #expect(fixture.ratchetRecords(of: alice).session?.confirmed == true)
        }
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// Our sealed profiles written to Alice since the transport was cleared, each once: what she reads as a `CTL_PROFILE`,
    /// our init answers aside.
    private func sealedProfiles(_ fixture: EngineFixture, to android: AndroidPeer) -> [Written] {
        let answers = fixture.answerIds
        return fixture.answers(to: android).filter { !answers.contains(ExactKey($0.envelope.id)) }
    }

    /// An edit: the cleartext profile first, flooded and carried, then one sealed `CTL_PROFILE` to the confirmed session,
    /// originated and carried, presenting what the cleartext one does at its version (`watchProfileChanges`,
    /// `MeshManager.kt:2687-2688`). Nothing rides beside the seal but our photo's hash, and there is none.
    @Test func anEditGoesSealedToAConfirmedSessionBesideTheCleartextProfile() throws {
        let (fixture, android) = try rig()
        fixture.engine.updateProfile(name: "Dana", status: "out walking", openToChat: true)
        let written = fixture.transport.written
        let cleartext = try #require(written.first { $0.envelope.type == .profile })
        let sealed = sealedProfiles(fixture, to: android)
        let frame = try #require(sealed.first)
        #expect(sealed.count == 1 && frame.envelope.recipientId == alice.nodeId.string && frame.to == nil && frame.wire.relay)
        let profileAt = written.firstIndex { $0.envelope.type == .profile }
        let sealedAt = written.firstIndex { $0.envelope.id == frame.envelope.id }
        #expect((profileAt ?? .max) < (sealedAt ?? .min), "the cleartext profile first, as `broadcastProfile` goes first")
        #expect(fixture.stores.custody.contains(frame.envelope.id) && fixture.stores.custody.contains(cleartext.envelope.id))
        let shown = try ProfileContent(decoding: cleartext.envelope.payload)
        let content = try #require(android.peek(frame, from: me))
        #expect(content.ctl == MessageContent.Control.profile)
        let payload = ProfilePayload(
            name: shown.name, status: shown.status, avatarHash: shown.avatarHash, version: shown.version ?? 0, openToChat: shown.openToChat)
        #expect(content.pr == payload && payload.version > 0, "what the cleartext profile presents, at its version")
        let chat = try ChatContent(decoding: frame.envelope.payload)
        #expect(chat.attachmentHash == nil && chat.attachmentMime == nil && chat.body.isEmpty && chat.mentions.isEmpty)
        #expect(try #require(chat.enc).version == EncEnvelope.Version.compactRatchet, "compact: Android reads v3")
    }

    /// A session we initiated is confirmed only once Android answers under it, so an edit before then reaches it as the
    /// cleartext profile alone; the next heal sends the sealed copy (`MeshManager.kt:974`), once, and a second edit goes at
    /// once.
    @Test func anUnconfirmedSessionGetsTheCleartextProfileUntilItConfirmsAndTheNextHealSendsTheSealedCopy() throws {
        let (fixture, android) = try rig(confirmed: false)
        let ours = try #require(fixture.engine.sendDirectMessage("hi", to: alice.nodeId))
        let dm = try #require(fixture.transport.written(.chat).first { $0.envelope.id == ours.id })
        fixture.engine.updateProfile(name: "Dana", status: "", openToChat: false)
        #expect(fixture.transport.written(.profile).count == 1)
        #expect(sealedProfiles(fixture, to: android).isEmpty, "our session waits for Android's answer")

        #expect(plaintext(try android.open(dm, from: me, now: now)) != nil)
        fixture.deliver(try android.dm("back", to: me, prekey: try fixture.ourPrekey(), id: "dm-2", sentAt: now + 1), from: android)
        #expect(fixture.ratchetRecords(of: alice).session?.confirmed == true, "confirmed by her answer")
        #expect(fixture.answerIds.isEmpty, "a responder's frame carries no init to answer")
        fixture.advance(MeshConfiguration().healMilliseconds)
        let sealed = sealedProfiles(fixture, to: android)
        #expect(sealed.count == 1 && android.peek(sealed[0], from: me)?.pr?.name == "Dana", "the heal sent the version she lacked")
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(fixture, to: android).count == 1, "once per version")
        fixture.engine.updateProfile(name: "Dana Lee", status: "", openToChat: false)
        #expect(sealedProfiles(fixture, to: android).count == 2, "and the next edit goes at once")
    }

    /// A profile never edited, at version 0, goes sealed to nobody (`if (version <= 0L) return`, `MeshManager.kt:2842`),
    /// though the session is confirmed.
    @Test func aProfileNeverEditedGoesSealedToNobody() throws {
        let (fixture, android) = try rig()
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(fixture, to: android).isEmpty)
    }

    /// Our photo's hash rides beside the seal in the clear, the hash alone and never its type (knit-next ADR 035), so a
    /// carrier that cannot read the frame can pull the photo (`MeshManager.kt:2901-2911`); the copy inside the seal names it
    /// too.
    @Test func thePhotosHashRidesBesideTheSealAndNothingElse() throws {
        let (fixture, android) = try rig()
        let jpeg = Array("a small face".utf8)
        fixture.engine.setAvatar(jpeg)
        let frame = try #require(sealedProfiles(fixture, to: android).first)
        let chat = try ChatContent(decoding: frame.envelope.payload)
        #expect(chat.attachmentHash == BlobHash(of: jpeg).string && chat.attachmentMime == nil, "the hash, and no type")
        #expect(android.peek(frame, from: me)?.pr?.avatarHash == BlobHash(of: jpeg).string)
    }

    /// An engine over `stores` and `keychain` whose session with Alice, an Android phone, confirmed on her first DM, and
    /// which then edited its profile, so its sealed profile went to her once: the run a relaunch follows.
    private func confirmedAndEdited(stores: MeshStores, keychain: KeptSecretStore) throws -> (EngineFixture, AndroidPeer) {
        let first = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        first.deliver(try android.dm("hello", to: me, prekey: try first.ourPrekey(), id: "dm-1", sentAt: now), from: android)
        first.engine.updateProfile(name: "Dana", status: "", openToChat: false)
        #expect(sealedProfiles(first, to: android).count == 1)
        return (first, android)
    }

    /// A relaunch sends a confirmed session nothing it had its chance at: the start seeds the fan-out's dedupe with our
    /// version for every confirmed session (``MeshEngine/seedSealedProfileVersions()``). That is a deliberate difference
    /// from Kotlin, whose `sentProfileVersions` starts empty, so its first heal after a restart sends the version once more
    /// (`MeshManager.kt:2836-2838`), a row of ours in every custody in reach each time the iPhone relaunches to restore
    /// Bluetooth (ADR 2026-10.mueg). The next edit still goes at once.
    @Test func aRelaunchSendsAConfirmedSessionNothingItHadItsChanceAt() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (_, android) = try confirmedAndEdited(stores: stores, keychain: keychain)

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000)
        restarted.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(restarted, to: android).isEmpty, "the relaunch's first heal sends nothing")
        restarted.engine.updateProfile(name: "Dana Lee", status: "", openToChat: false)
        let sealed = sealedProfiles(restarted, to: android)
        #expect(sealed.count == 1 && android.peek(sealed[0], from: me)?.pr?.name == "Dana Lee", "and the next edit goes at once")
    }

    /// A prekey's rotation due when the iPhone relaunches is a new version, which the first heal sends, as it sends one due
    /// at a heal: the seed runs before the start's prekey sync. The copy presents nothing new, since the sealed profile
    /// carries no prekey, which is Kotlin's cost too (`rotatePrekeyIfDue` then `broadcastSealedProfile`, `MeshManager.kt:972-974`).
    @Test func aRotationDueAtTheRelaunchGoesAtItsFirstHeal() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (first, android) = try confirmedAndEdited(stores: stores, keychain: keychain)
        let edited = stores.ownProfile.load()
        let prekey = try #require(first.engine.prekeyRing?.newest?.id)

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + PrekeyRing.rotationMilliseconds)
        let rotated = stores.ownProfile.load()
        #expect(rotated.prekeyId != prekey && rotated.version > edited.version, "the start rotated the prekey, as an edit")
        restarted.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(restarted, to: android).count == 1, "the first heal sent the rotation's version")
        restarted.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(restarted, to: android).count == 1, "once")
    }

    /// A start whose sessions cannot be read in a unit of their own seeds nothing, so its first heal sends the version once
    /// more, as Kotlin's restart does, and the next sends nothing.
    @Test func aRelaunchWhoseSessionsCannotBeReadSeedsNothing() throws {
        let refusing = RefusingRatchetStore()
        let stores = MeshStores.inMemory().replacing(ratchet: refusing, transactor: refusing.transactor)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let (_, android) = try confirmedAndEdited(stores: stores, keychain: keychain)

        refusing.refuse(.reads)
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000)
        refusing.refuse([])
        #expect(restarted.log.all.contains { $0.contains("dedupe not seeded") })
        restarted.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(restarted, to: android).count == 1, "the first heal sends it once more")
        restarted.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(restarted, to: android).count == 1, "and the next sends nothing")
    }

    /// The answer an init is owed bypasses the fan-out's dedupe, as Kotlin's `sendIntroTo` does (`MeshManager.kt:2877-2889`),
    /// and once sealed marks it with the version it carried, which Kotlin's does not (`:2883`): the answer is that
    /// version's sealed profile. An edit made before any session goes sealed to nobody, Android's first DM is answered at
    /// that version, the heal sends her nothing more, and the next edit goes at once.
    @Test func anAnswerMarksTheFanOutsDedupeWithTheVersionItCarried() throws {
        let (fixture, android) = try rig(confirmed: false)
        fixture.engine.updateProfile(name: "Dana", status: "", openToChat: false)
        let version = fixture.stores.ownProfile.load().version
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now), from: android)
        let answer = try #require(fixture.answers(to: android).first)
        #expect(android.peek(answer, from: me)?.pr?.version == version, "the answer carries the current version")
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(fixture, to: android).isEmpty, "so the heal owes her nothing more of it")
        fixture.engine.updateProfile(name: "Dana Lee", status: "", openToChat: false)
        let sealed = sealedProfiles(fixture, to: android)
        #expect(sealed.count == 1 && android.peek(sealed[0], from: me)?.pr?.name == "Dana Lee", "and the next edit goes at once")
    }

    /// The photo's push is queued on every link before a sealed copy names its hash in the clear, as Kotlin's
    /// `broadcastProfile` pushes before `watchProfileChanges` runs `broadcastSealedProfile` (`MeshManager.kt:2787`,
    /// `:2687-2688`). The cleartext profile goes first, as in Kotlin, and an Android neighbour leaves a linked author's photo
    /// to the push (`pullRelayAvatarIfNeeded`); then each linked neighbour's FILE; then the sealed copy, whose clear hash an
    /// Android carrier would turn into a want (`InboundPipeline.onCarriedFrame`). A link sends a file behind the frames
    /// written before it, so on a link with no file streaming each neighbour finds the photo on its way before any frame
    /// asks it to want one. Behind a file already streaming, the push waits for that file's END while the sealed copy goes
    /// between its chunks, as on Android, and the carrier's query is answered SENDING from the queue; this pins the order
    /// the engine writes in, which is the radio's on an idle link.
    @Test func thePhotosPushIsQueuedBeforeASealedCopyNamesItsHash() throws {
        let (fixture, _) = try rig()
        fixture.link(alice, carol)
        fixture.transport.clear()
        let jpeg = Array("a small face".utf8)
        let hash = BlobHash(of: jpeg)
        fixture.engine.setAvatar(jpeg)
        let sequence = fixture.transport.sequence
        let profileAt = sequence.firstIndex { write in
            guard case .frame(let frame) = write else {
                return false
            }
            return frame.envelope.type == .profile
        }
        let namingAt = sequence.firstIndex { write in
            guard case .frame(let frame) = write, frame.envelope.type == .chat else {
                return false
            }
            return (try? ChatContent(decoding: frame.envelope.payload))?.attachmentHash == hash.string
        }
        let cleartext = try #require(profileAt)
        let named = try #require(namingAt, "a sealed copy names it, toward Alice's confirmed session")
        for neighbor in [alice, carol] {
            let fileAt = sequence.firstIndex { write in
                guard case .file(let file) = write else {
                    return false
                }
                return file.hash == hash && file.to == neighbor.nodeId && file.kind == .avatar
            }
            let pushed = try #require(fileAt, "the photo pushed to \(neighbor.nodeId)")
            #expect(cleartext < pushed && pushed < named, "the cleartext profile, then the push, then the sealed copy")
        }
    }

    /// A store that fails mid-seal, over both store kinds: the cleartext profile goes whatever happens here, the sealed copy
    /// does not, and nothing marks it sent, so the next heal sends it.
    @Test(arguments: StoreKind.allCases)
    func aStoreThatFailsMidSealSendsNoSealedProfileAndTheNextHealSendsIt(kind: StoreKind) throws {
        let directory = scratchDirectory("profile-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let (fixture, android) = try rig(stores: stores)
        let held = stores.ratchet.records(of: alice.nodeId)
        refusing.refusesWrites = true
        fixture.engine.updateProfile(name: "Dana", status: "", openToChat: false)
        refusing.refusesWrites = false
        #expect(fixture.transport.written(.profile).count == 1, "the cleartext profile went")
        #expect(fixture.transport.written(.chat).isEmpty && stores.ratchet.records(of: alice.nodeId) == held, "the sealed copy did not")
        fixture.advance(MeshConfiguration().healMilliseconds)
        let sealed = sealedProfiles(fixture, to: android)
        #expect(sealed.count == 1 && android.peek(sealed[0], from: me)?.pr?.name == "Dana", "the next heal sent it")
    }

    /// The fan-out asked for inside a unit its caller opened reads no target set, so nothing is sealed and nothing goes, and
    /// the next heal sends it. The version is owed as an initiator's session leaves it: our edit went before Android's
    /// answer confirmed us, and her answer carries no init, so nothing of ours answered it.
    @Test func theFanOutAskedForInsideAUnitPutsNothingOnTheAir() throws {
        let (fixture, android) = try rig(confirmed: false)
        let ours = try #require(fixture.engine.sendDirectMessage("hi", to: alice.nodeId))
        let dm = try #require(fixture.transport.written(.chat).first { $0.envelope.id == ours.id })
        fixture.engine.updateProfile(name: "Dana", status: "", openToChat: false)
        #expect(plaintext(try android.open(dm, from: me, now: now)) != nil)
        fixture.deliver(try android.dm("back", to: me, prekey: try fixture.ourPrekey(), id: "dm-2", sentAt: now + 1), from: android)
        #expect(fixture.ratchetRecords(of: alice).session?.confirmed == true && fixture.answerIds.isEmpty)
        fixture.transport.clear()
        let outer = fixture.stores.transactor.atomically { () -> Void? in
            fixture.engine.broadcastSealedProfile()
            return ()
        }
        guard case .committed = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(fixture.transport.written.isEmpty, "nothing sealed, nothing on the air")
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(fixture, to: android).count == 1, "the heal sends it")
    }

    /// A confirmed session whose peer's newer profile dropped the bit: the fan-out seals nothing toward it and leaves the
    /// version owed, as Kotlin's refusal in `sendCtlDm` leaves it unmarked (`MeshManager.kt:2922-2924`), so the heal after a
    /// profile with the bit pins again sends it.
    @Test func aConfirmedPeerWhoseProfileDroppedTheBitIsLeftForTheNextHeal() throws {
        let (fixture, android) = try rig()
        fixture.deliver(try alice.profile(publishedAt: now + 1, capabilities: 0xF), from: alice)
        fixture.engine.updateProfile(name: "Dana", status: "", openToChat: false)
        #expect(fixture.transport.written(.profile).count >= 1)
        #expect(sealedProfiles(fixture, to: android).isEmpty, "nothing sealed toward a profile without the bit")
        fixture.deliver(try android.profile(publishedAt: now + 2), from: alice)
        fixture.advance(MeshConfiguration().healMilliseconds)
        #expect(sealedProfiles(fixture, to: android).count == 1, "the version stayed owed, and the heal sent it")
    }
}
