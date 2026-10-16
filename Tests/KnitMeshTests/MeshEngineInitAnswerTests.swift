import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The answer an init is owed, through an engine with the switch on and Android's own session layer (``AndroidPeer``; ADR
/// 2026-10.5sk9, phase P5e): IntroSync's answer half (`IntroSync.kt:185-240`, at knit-next `cbf2a487`), whose pure rules
/// ``RatchetAnswersTests`` ports case by case. A frame whose header still carries Android's init opens and commits, and our
/// sealed profile answers it, the frame that confirms Android's side: once per init, again only after the floor, once
/// more for a reset marked under it, and owed, not dropped, while we cannot seal to Android yet.
@Suite struct MeshEngineInitAnswerTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private static let minute: Int64 = 60_000
    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on and Alice an Android phone, pinned with its prekey and the ratchet's bits, or, unless
    /// `prekeyPinned`, with the bits alone, as a profile that does not carry the prekey yet leaves her.
    private func rig(stores: MeshStores = .inMemory(), prekeyPinned: Bool = true) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        if prekeyPinned {
            try fixture.pin(android)
        } else {
            fixture.deliver(try alice.profile(publishedAt: now, capabilities: AndroidPeer.capabilities), from: alice)
        }
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// Our answers so far, each once, in the order they went.
    private func answerFrames(_ fixture: EngineFixture) -> [Written] {
        let answers = fixture.answerIds
        return EngineFixture.once(fixture.transport.written(.chat)).filter { answers.contains(ExactKey($0.envelope.id)) }
    }

    /// The init `frame` carries, as its header names it.
    private func initial(of frame: TestFrame) throws -> RatchetInit? {
        try #require(try ChatContent(decoding: frame.envelope.payload).enc?.ratchet).initial
    }

    /// Android initiated, so its init rides its DM; our sealed profile answers it, ahead of the DM's receipt as Kotlin's
    /// commit runs the answer first (`InboundPipeline.kt:1059-1067`), originated and carried. Android's open of it confirms
    /// its side, and its next frame carries no init, which nothing answers. A copy of the DM served again past the router
    /// meets the exists-gate and opens nothing, so it earns no second answer.
    @Test func anAndroidInitiatorIsAnsweredOnceAndItsInitStopsRiding() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let first = try android.dm("hello", to: me, prekey: prekey, id: "dm-1", sentAt: now, v3: true)
        #expect(try initial(of: first) != nil, "Android initiated: its init rides")
        fixture.deliver(first, from: android)

        let answers = answerFrames(fixture)
        let answer = try #require(answers.first)
        #expect(answers.count == 1 && answer.to == nil && answer.wire.relay, "one, originated")
        #expect(fixture.transport.written(.chat).first?.envelope.id == answer.envelope.id, "ahead of the DM's receipt")
        #expect(me.keys.bundle.isValidSignature(answer.wire.sig, for: answer.wire.signed), "signed once, and it verifies")
        #expect(fixture.stores.custody.contains(answer.envelope.id), "carried for its day, as Kotlin's originate carries it")
        #expect(try ChatContent(decoding: answer.envelope.payload).attachmentHash == nil, "no photo, so nothing in the clear")
        let content = try #require(android.peek(answer, from: me))
        #expect(content.ctl == MessageContent.Control.profile && content.pr?.version == 0, "our profile, never edited")
        #expect(fixture.engine.answers == RatchetAnswerCounts(introsAnswered: 1))

        #expect(android.session(with: me)?.confirmed == false)
        #expect(plaintext(try android.open(answer, from: me, now: now)) != nil)
        #expect(android.session(with: me)?.confirmed == true, "our answer confirmed Android's side")
        let second = try android.dm("again", to: me, prekey: prekey, id: "dm-2", sentAt: now + 1, v3: true)
        #expect(try initial(of: second) == nil, "and its init rides no more")
        fixture.deliver(second, from: android)
        fixture.deliverPastRouter(first, from: carol)
        #expect(fixture.engine.answers.introsAnswered == 1, "a frame with no init, and a re-served copy, earn nothing")
    }

    /// `an init-bearing frame is answered once per floor` (`IntroSyncTest.kt:153-173`): Android reads nothing of ours, so its
    /// init rides every frame, and the same init is answered again only once the hour has passed.
    @Test func theSameInitIsAnsweredAgainOnlyAfterTheFloor() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("one", to: me, prekey: prekey, id: "dm-1", sentAt: now), from: android)
        fixture.clock.advance(RatchetAnswers.floorMilliseconds - 1)
        fixture.deliver(try android.dm("two", to: me, prekey: prekey, id: "dm-2", sentAt: now + 1), from: android)
        #expect(fixture.engine.answers.introsAnswered == 1, "inside the floor")
        fixture.clock.advance(1)
        fixture.deliver(try android.dm("three", to: me, prekey: prekey, id: "dm-3", sentAt: now + 2), from: android)
        #expect(fixture.engine.answers.introsAnswered == 2, "and again once it has passed")
    }

    /// `a new init is answered inside the floor, once` (`IntroSyncTest.kt:242-256`, knit-next #87): Android, confirmed, resets
    /// under a fresh root. Its re-seals reuse ids we hold, so only our answer under the new root can confirm it, however
    /// recently we answered the old init; the new init's own repeats stay floored.
    @Test func aResetsNewInitIsAnsweredInsideTheOldOnesFloorOnce() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: "dm-1", sentAt: now), from: android)
        let first = try #require(answerFrames(fixture).first)
        #expect(plaintext(try android.open(first, from: me, now: now)) != nil)
        let oldRoot = try #require(android.session(with: me)).root

        fixture.clock.advance(Self.minute)
        let reset = try android.resetDm(to: me, prekey: prekey, id: "reset", at: now + Self.minute)
        let header = try #require(try ChatContent(decoding: reset.envelope.payload).enc?.ratchet)
        #expect(header.initial != nil && header.flags & RatchetHeader.resetFlag != 0, "a fresh init, flagged")
        fixture.deliver(reset, from: android)
        #expect(fixture.engine.answers.introsAnswered == 2, "the reset's new init, answered inside the floor")
        fixture.deliver(try android.dm("after", to: me, prekey: prekey, id: "dm-2", sentAt: now + Self.minute + 1), from: android)
        #expect(fixture.engine.answers.introsAnswered == 2, "its own repeats stay floored")

        let latest = try #require(answerFrames(fixture).last)
        #expect(plaintext(try android.open(latest, from: me, now: now + Self.minute)) != nil)
        let session = try #require(android.session(with: me))
        #expect(session.confirmed && session.root != oldRoot, "and the answer confirms Android under its new root")
    }

    /// `an init marked as a reset is answered once more inside the floor` (`IntroSyncTest.kt:259-273`): Android, still
    /// unconfirmed, marks the init it waits on as a reset (knit-next ADR 2026-09.qerd), and the marked frame earns that init
    /// one more answer; the plain frames after it stay floored.
    @Test func aResetMarkedUnderAnInitWeAnsweredEarnsItOneMoreAnswer() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let first = try android.dm("hello", to: me, prekey: prekey, id: "dm-1", sentAt: now)
        fixture.deliver(first, from: android)
        #expect(fixture.engine.answers.introsAnswered == 1)

        fixture.clock.advance(Self.minute)
        let marked = try android.resetDm(to: me, prekey: prekey, id: "marked", at: now + Self.minute)
        let header = try #require(try ChatContent(decoding: marked.envelope.payload).enc?.ratchet)
        #expect(header.flags & RatchetHeader.resetFlag != 0, "flagged")
        #expect(header.initial?.eph == (try initial(of: first))?.eph, "under the init it still waits on")
        fixture.deliver(marked, from: android)
        #expect(fixture.engine.answers.introsAnswered == 2, "the mark earns its init one more answer")
        fixture.deliver(try android.dm("plain", to: me, prekey: prekey, id: "dm-2", sentAt: now + Self.minute + 1), from: android)
        #expect(fixture.engine.answers.introsAnswered == 2, "and the plain frames after it stay floored")
    }

    /// `an init that opens before its sender's profile pins is answered when the profile pins` (`IntroSyncTest.kt:176-197`,
    /// knit-next `937cf785`): opening needs only the pinned bundle, sealing the prekey too. Android's DM opens while the
    /// profile pinned for it carries none, so the answer is owed, and goes once a profile carrying it pins, before the
    /// frames parked for it land. A re-flooded profile finds nothing more to answer.
    @Test func anInitThatOpensBeforeItsSendersPrekeyPinsIsAnsweredWhenTheProfilePins() throws {
        let (fixture, android) = try rig(prekeyPinned: false)
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now), from: android)
        #expect(fixture.stores.messages.message("dm-1")?.body == "hello", "it opened")
        #expect(fixture.engine.answers.introsAnswered == 0, "but nothing could be sealed to Android yet")

        fixture.deliver(try android.profile(publishedAt: now + 1), from: alice)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.prekey != nil)
        #expect(fixture.engine.answers.introsAnswered == 1, "the owed answer, at the pin")
        let answer = try #require(answerFrames(fixture).first)
        #expect(android.peek(answer, from: me)?.ctl == MessageContent.Control.profile)
        fixture.deliver(try android.profile(publishedAt: now + 2), from: alice)
        #expect(fixture.engine.answers.introsAnswered == 1, "owed once")
    }

    /// The answer half of `a pending intro is withdrawn when the peer's profile arrives without the ratchet`
    /// (`IntroSyncTest.kt:481-493`, `IntroSync.kt:186-188`): a profile without the ratchet forgives the debt, so the next pin
    /// answers nothing, and only Android's next frame carrying its init owes again.
    @Test func aDebtIsForgivenWhenAProfileWithoutTheRatchetPins() throws {
        let (fixture, android) = try rig(prekeyPinned: false)
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: "dm-1", sentAt: now), from: android)
        fixture.deliver(try alice.profile(publishedAt: now + 1, capabilities: 0xF), from: alice)
        fixture.deliver(try android.profile(publishedAt: now + 2), from: alice)
        #expect(fixture.engine.answers.introsAnswered == 0, "forgiven, so the pin found nothing owed")
        fixture.deliver(try android.dm("again", to: me, prekey: prekey, id: "dm-2", sentAt: now + 3), from: alice)
        #expect(fixture.engine.answers.introsAnswered == 1, "nothing was answered, so the next frame owes again")
    }

    /// The start's replay only delivers (``RatchetInbound/Origin/startReplay``): a DM whose open's unit failed, still in our
    /// custody with no row after a restart, opens there and is delivered, and its init is not answered, though no answer
    /// went for it before the restart either: its first verdict never committed. It is left to Android's next frame, and the
    /// next live one, its init still riding, is answered.
    @Test func theStartsReplayAnswersNoInitAndTheNextLiveFrameDoes() throws {
        let directory = scratchDirectory("answer-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.memory.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let first = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        let prekey = try first.ourPrekey()

        refusing.refusesRows = true
        first.deliver(try android.dm("hello", to: me, prekey: prekey, id: "dm-1", sentAt: now), from: android)
        refusing.refusesRows = false
        #expect(first.engine.dropped[.storeRefused] == 1 && stores.custody.contains("dm-1"), "custody kept it, with no row")
        #expect(first.engine.answers.introsAnswered == 0, "a unit that failed answers nothing")

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + Self.minute)
        #expect(stores.messages.message("dm-1")?.body == "hello", "the start's replay delivered it")
        #expect(restarted.engine.answers.introsAnswered == 0 && restarted.answerIds.isEmpty, "and answered nothing")
        restarted.deliver(try android.dm("live", to: me, prekey: prekey, id: "dm-2", sentAt: now + Self.minute), from: android)
        #expect(restarted.engine.answers.introsAnswered == 1, "the next live frame is answered")
    }

    /// A store that fails mid-answer, over both store kinds: nothing goes on the air and no chain advances, and the debt is
    /// kept, as Kotlin's throw out of its `canSeal` leaves it, so the next pin answers it.
    @Test(arguments: StoreKind.allCases)
    func aStoreThatFailsMidAnswerSendsNothingAndKeepsTheDebt(kind: StoreKind) throws {
        let directory = scratchDirectory("answer-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let (fixture, android) = try rig(stores: stores, prekeyPinned: false)
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now), from: android)
        let held = stores.ratchet.records(of: alice.nodeId)
        fixture.transport.clear()

        refusing.refusesWrites = true
        fixture.deliver(try android.profile(publishedAt: now + 1), from: alice)
        refusing.refusesWrites = false
        #expect(fixture.transport.written(.chat).isEmpty, "nothing sealed went")
        #expect(stores.ratchet.records(of: alice.nodeId) == held, "no chain advanced")
        #expect(fixture.engine.answers.introsAnswered == 0)

        fixture.deliver(try android.profile(publishedAt: now + 2), from: alice)
        #expect(fixture.engine.answers.introsAnswered == 1, "the debt was kept, and the next pin answers it")
    }

    /// An answer sealed inside a unit its caller opened, which nothing opens around an open's follow-up: the seal joins that
    /// unit, so nothing goes before an outer commit it never sees, and the debt stays owed for the next pin. The abandoned
    /// unit takes the joined seal with it.
    @Test func anAnswerSealedInsideAUnitPutsNothingOnTheAirAndKeepsTheDebt() throws {
        let (fixture, android) = try rig()
        let frame = try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now)
        fixture.deliver(frame, from: android)
        #expect(fixture.engine.answers.introsAnswered == 1)
        fixture.clock.advance(RatchetAnswers.floorMilliseconds)
        let header = try #require(try ChatContent(decoding: frame.envelope.payload).enc?.ratchet)
        let held = fixture.ratchetRecords(of: alice)
        fixture.transport.clear()

        let outer = fixture.stores.transactor.atomically { () -> Void? in
            fixture.engine.answerInit(in: header, from: alice.nodeId)
            return nil
        }
        guard case .abandoned = outer else {
            Issue.record("the outer unit abandons: \(outer)")
            return
        }
        #expect(fixture.transport.written.isEmpty, "nothing on the air")
        #expect(fixture.ratchetRecords(of: alice) == held, "and the joined seal undone with the unit")
        #expect(fixture.engine.answers.introsAnswered == 1)
        let row = try #require(fixture.stores.peers.peer(alice.nodeId))
        fixture.engine.answerOwedInit(of: alice.nodeId, pinned: row)
        #expect(fixture.engine.answers.introsAnswered == 2, "the debt was kept for the next pin")
    }

    /// Our own profile unreadable when an answer is due, as a database read before the first unlock is: nothing is sealed,
    /// and the debt is kept, as for a store that fails, so the next pin answers it once the store reads again.
    @Test func anAnswerDueWhileOurProfileCannotBeReadIsOwed() throws {
        let profiles = LockedOwnProfileStore(OwnProfile())
        profiles.locked = false
        let (fixture, android) = try rig(stores: .inMemory(ownProfileStore: profiles))
        profiles.locked = true
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: "dm-1", sentAt: now), from: android)
        #expect(fixture.stores.messages.message("dm-1")?.body == "hello")
        #expect(fixture.engine.answers.introsAnswered == 0 && fixture.answerIds.isEmpty, "nothing sealed")
        profiles.locked = false
        fixture.deliver(try android.profile(publishedAt: now + 1), from: alice)
        #expect(fixture.engine.answers.introsAnswered == 1, "the debt was kept, and the next pin answers it")
    }

    /// A seal the facade cannot make toward a peer who could read one (here no session, and a prekey Alice signed that X25519
    /// refuses, which Kotlin's seal throws on) drops the debt and sets no floor, as Kotlin's failed send removes both
    /// (`IntroSync.kt:239`): the pin of a usable prekey finds nothing owed, and the same init, carried again, is answered
    /// at once.
    @Test func aSealTheFacadeCannotMakeDropsTheDebtAndSetsNoFloor() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let lowOrder = [UInt8](repeating: 0, count: RatchetCrypto.keyByteCount)
        let signature = try alice.keys.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: lowOrder))
        let refused = PrekeyInfo(id: 1, pub: lowOrder, sig: signature)
        fixture.deliver(try alice.profile(publishedAt: now, capabilities: AndroidPeer.capabilities, prekey: refused), from: alice)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.prekey != nil, "a prekey the peer signed, pinned")
        fixture.transport.clear()
        let initial = RatchetInit(eph: [UInt8](repeating: 7, count: 32), pkid: 1, at: now)
        let header = RatchetHeader(se: 1, ek: [UInt8](repeating: 9, count: 32), pe: 0, n: 0, initial: initial)

        fixture.engine.answerInit(in: header, from: alice.nodeId)
        #expect(fixture.transport.written.isEmpty && fixture.engine.answers.introsAnswered == 0, "nothing sealed")
        #expect(fixture.ratchetRecords(of: alice).session == nil, "and no session started")
        fixture.deliver(try AndroidPeer(alice).profile(publishedAt: now + 1), from: alice)
        #expect(fixture.engine.answers.introsAnswered == 0, "the pin found no debt: the failed seal dropped it")
        fixture.engine.answerInit(in: header, from: alice.nodeId)
        #expect(fixture.engine.answers.introsAnswered == 1, "and no floor held the same init back")
    }
}
