import KnitStore
import KnitStoreSQL
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// One round of a paced answer (ADR 2026-10.f5zs, the `custody-carry-policy` contract, §1 and §2): at most
/// ``CustodySync/roundBytes`` with the keys ahead, picked from the index in four tiers, minus what crossed the link,
/// stopping at its budget and never skipping.
@Suite struct CustodySyncRoundTests: CustodySyncCase {
    @Test func aDMBehindFourHundredGroupFramesThePeerIsNotInFollowsThemOnceEach() {
        // A group frame goes to a non-member that lacks it (knit-next ADR 2026-10.hr9f), so each takes its bytes: the newer
        // group frames fill the first rounds, and the DM, oldest received, goes in the last. That is the back-fill, once per
        // frame, the crossings keeping each slice from coming again.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("dm", to: bob), in: store, now: now) { true }
        let senders = (60..<64).map(fixtureNodeId)
        for index in 0..<400 {
            // Two groups, each with every sender in it, so each roster derives and names its sender.
            let members = (index < 200 ? [alice, bob] : [alice]) + senders
            _ = sync.carry(frame("g\(index)", from: senders[index % 4], members: members), in: store, now: now + 1) { true }
        }
        #expect(store.liveIds(now: now).count == 401)
        var crossed: Set<String> = []
        var rounds: [[String]] = []
        for _ in 0..<100 {
            let reply = round(sync, for: zed, in: store, crossed: crossed)
            crossed.formUnion((reply.keys + reply.frames).map(Self.frameKey))
            rounds.append(ids(reply))
            #expect(reply.bytes <= CustodySync.roundBytes)
            guard reply.isCapped else {
                break
            }
        }
        #expect(rounds.count > 2, "\(rounds.count) rounds of 16 KiB")
        #expect(rounds.last?.last == "dm", "the DM, oldest received, in the last")
        let served = rounds.flatMap(\.self)
        #expect(Set(served).count == served.count, "no id twice across the rounds")
        #expect(Set(served) == Set(store.liveIds(now: now)), "every frame the peer lacks")
    }

    @Test func aLargeProfileGoesFirstAloneAndItsChatFollowsWithNoKey() {
        // The first pick always goes, and the round stops at the next one rather than skipping it for the chat
        // behind: the chat would otherwise reach the peer before the key that verifies it. A frame past the round's whole
        // budget is over custody's byte cap (knit-next #227) and its profile cap (ADR 2026-10.r88m), so it stands for a row a
        // build without the caps stored, which the round serves until the sweep deletes it.
        let store = MemoryCustodyStore(limits: CustodyLimits(maxSignedBytes: 1_000_000, maxProfileSignedBytes: 1_000_000))
        var sync = CustodySync()
        _ = sync.carry(frame("profile-b", type: .profile, from: bob, payloadBytes: 300 * 1024), in: store, now: now) { true }
        for id in ["c1", "c2", "c3"] {
            _ = sync.carry(frame(id, from: bob), in: store, now: now + 1) { true }
        }
        let first = round(sync, for: zed, in: store)
        #expect(ids(first) == ["profile-b"])
        #expect(first.isCapped)
        #expect(first.bytes > CustodySync.roundBytes, "the first pick goes whatever its size")
        #expect(first.keys.isEmpty, "the profile is the key")
        let crossed = Set(first.frames.map(Self.frameKey))
        let second = round(sync, from: ["profile-b"], for: zed, in: store, crossed: crossed)
        #expect(ids(second) == ["c3", "c2", "c1"])
        #expect(second.keys.isEmpty)
        // A peer that did not keep the profile still holds it from the crossing, and its chat is not given a key.
        #expect(round(sync, for: zed, in: store, crossed: crossed).keys.isEmpty)
    }

    @Test func keysAheadAreChargedToTheRoundBeforeTheirFrames() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        let senders = (0..<150).map { fixtureNodeId(100 + $0) }
        for (index, sender) in senders.enumerated() {
            _ = sync.carry(frame("s\(index)", from: sender, to: bob, payloadBytes: 1000), in: store, now: now + Int64(index)) { true }
        }
        let reply = round(sync, for: zed, in: store, keyBytes: 1000)
        let keyBytes = reply.keys.reduce(0) { $0 + $1.encoded.count }
        let frameBytes = reply.frames.reduce(0) { $0 + $1.encoded.count }
        #expect(reply.isCapped, "150 frames and their keys pass a round")
        #expect(reply.keys.count == reply.frames.count)
        #expect(reply.bytes == keyBytes + frameBytes)
        #expect(reply.bytes <= CustodySync.roundBytes)
        #expect(
            reply.bytes + 2 * (reply.frames.first?.encoded.count ?? 0) > CustodySync.roundBytes,
            "it stopped at the first pick past the budget")
    }

    @Test func aKeyTheLinkCarriedIsNeitherSentNorCharged() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("r1", from: alice), in: store, now: now) { true }
        _ = sync.carry(frame("s1", from: bob), in: store, now: now) { true }
        let reply = round(sync, for: zed, in: store, crossed: [Self.frameKey(Self.key(of: alice))])
        #expect(reply.keysAhead == [bob])
        #expect(ids(reply).sorted() == ["r1", "s1"])
        #expect(reply.bytes == reply.frames.reduce(0) { $0 + $1.encoded.count } + Self.key(of: bob).encoded.count)
    }

    @Test func aRoundServesAtMostItsBytes() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        for index in 0..<40 {
            _ = sync.carry(frame("m\(index)", to: bob, payloadBytes: 1024), in: store, now: now + Int64(index)) { true }
        }
        let reply = round(sync, for: zed, in: store, keyBytes: 0)
        let each = reply.frames.first?.encoded.count ?? 0
        #expect(reply.isCapped)
        #expect(reply.bytes <= CustodySync.roundBytes)
        #expect(reply.bytes + each > CustodySync.roundBytes)
        #expect(reply.frames.count == CustodySync.roundBytes / each)
        #expect(ids(reply).first == "m39", "newest received first")
    }

    @Test func aFrameThatCrossedTheLinkIsLeftOut() {
        // Either way: one the peer gave us, or one we served it inside the crossing's window.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        for id in ["r1", "r2", "r3"] {
            _ = sync.carry(frame(id), in: store, now: now) { true }
        }
        let crossed = Self.frameKey(WireEnvelope(sig: Self.signature("r2"), signed: []))
        let served = round(sync, for: zed, in: store, crossed: [crossed])
        #expect(ids(served).sorted() == ["r1", "r3"])
    }

    @Test func aPeerThatKeepsOneFrameInFiveIsServedEveryKeepableFrameOnce() {
        // A slice the peer refuses is not served again while its crossing lasts, so each round moves on to the next.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        for index in 0..<1000 {
            _ = sync.carry(frame("m\(index)", from: fixtureNodeId(40 + index % 5), to: bob), in: store, now: now + Int64(index)) { true }
        }
        #expect(store.liveIds(now: now).count == 1000)
        let keepable = Set((0..<1000).filter { $0.isMultiple(of: 5) }.map { "m\($0)" })
        var kept: [String] = []
        var crossed: Set<String> = []
        for _ in 0..<1000 {
            let reply = round(sync, from: kept, for: zed, in: store, crossed: crossed)
            crossed.formUnion((reply.keys + reply.frames).map(Self.frameKey))
            kept += ids(reply).filter(keepable.contains)
            guard reply.isCapped else {
                break
            }
        }
        #expect(Set(kept) == keepable)
        #expect(kept.count == keepable.count, "no frame twice")
    }

    @Test func aRowWhoseBytesNoLongerDecodeIsSkippedAtItsLoadAndTakesNoSlot() throws {
        // The index lists it, as liveIds does (knit-ios #14), and only the load finds it damaged: the round moves on to
        // the frames behind it and charges it nothing.
        let store = SQLCustodyStore(try KnitDatabase.inMemory { Issue.record($0) })
        let older = frame("m1", to: bob)
        let newer = frame("m2", to: bob)
        let damaged = frame("m3", to: bob)
        store.store(older, origin: .relayed, now: now)
        store.store(newer, origin: .relayed, now: now + 1)
        store.store(CarriedFrame(envelope: damaged.envelope, sig: damaged.sig, signed: [0xFF]), origin: .relayed, now: now + 2)
        #expect(store.liveIndex(now: now).map(\.id) == ["m3", "m2", "m1"])
        #expect(store.frame("m3", now: now) == nil)
        let reply = CustodySync().missing(from: [], for: zed, in: store, now: now)
        #expect(ids(reply) == ["m2", "m1"])
        #expect(reply.bytes == newer.reserved.encoded.count + older.reserved.encoded.count)
        #expect(!reply.isCapped)
    }

    @Test func anUnsignedRowHasNoFrameKeySoTheLinkIsNeverAskedAndItIsServed() {
        // A row an older build stored without a signature: nothing the link carried can match it.
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("s1", to: bob), in: store, now: now) { true }
        let bare = frame("u1", to: bob)
        store.store(CarriedFrame(envelope: bare.envelope, sig: [], signed: bare.signed), origin: .relayed, now: now + 1)
        var asked: [String] = []
        let reply = sync.missing(from: [], for: zed, in: store, now: now) { key in
            asked.append(key)
            return true
        }
        #expect(ids(reply) == ["u1"], "every signed frame crossed; the unsigned one cannot have")
        #expect(asked == [Self.frameKey(WireEnvelope(sig: Self.signature("s1"), signed: []))])
    }
}

/// A store that counts the frames a round loads.
private final class CountingCustody: CustodyStore, @unchecked Sendable {
    let held: MemoryCustodyStore
    private(set) var loads: [String] = []

    init(_ held: MemoryCustodyStore) {
        self.held = held
    }

    var limits: CustodyLimits { held.limits }
    func store(_ frame: CarriedFrame, origin: CustodyOrigin, now: Int64, carry: some CustodyCarry) -> CustodyStoreResult {
        held.store(frame, origin: origin, now: now, carry: carry)
    }
    func liveFrames(now: Int64) -> [CarriedFrame] { held.liveFrames(now: now) }
    func liveIndex(now: Int64) -> [CustodyIndexEntry] { held.liveIndex(now: now) }
    func liveIds(now: Int64) -> [String] { held.liveIds(now: now) }
    func frame(_ id: String, now: Int64) -> CarriedFrame? {
        loads.append(id)
        return held.frame(id, now: now)
    }
    func contains(_ id: String) -> Bool { held.contains(id) }
    func recipient(of id: String) -> String? { held.recipient(of: id) }
    func remove(_ id: String) { held.remove(id) }
    func sweepExpired(now: Int64) -> Int { held.sweepExpired(now: now) }
}

/// The round's four tiers (the `custody-carry-policy` contract, §1, revision 3).
@Suite struct CustodySyncTierTests: CustodySyncCase {
    private var carol: NodeId { fixtureNodeId(3) }

    /// An answer to `peer` whose digest listed `listed`.
    private func answer(_ peer: NodeId, listed: [String] = [], released: [String] = []) -> CustodyAnswers.Answer {
        var answer = CustodyAnswers.Answer(peer: peer, listed: Set(listed.map(ExactKey.init)), arrivedAt: 0)
        answer.released = Dictionary(released.map { (ExactKey($0), 0) }) { first, _ in first }
        return answer
    }

    @Test func profilesThenTheAskersOwnMailOldestFirstThenItsGroupsThenTheRestNewestFirst() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        let members = [alice, bob, carol]
        _ = sync.carry(frame("rest-old", sentAt: now - 5), in: store, now: now) { true }
        _ = sync.carry(frame("dm-new", to: bob, sentAt: now - 1), in: store, now: now + 1) { true }
        _ = sync.carry(frame("group-new", members: members, sentAt: now - 2), in: store, now: now + 2) { true }
        _ = sync.carry(frame("dm-old", to: bob, sentAt: now - 9), in: store, now: now + 3) { true }
        _ = sync.carry(frame("group-old", from: carol, members: members, sentAt: now - 8), in: store, now: now + 4) { true }
        _ = sync.carry(frame("profile-a", type: .profile, from: carol), in: store, now: now + 5) { true }
        _ = sync.carry(frame("rest-new", to: zed, sentAt: now - 7), in: store, now: now + 6) { true }
        let reply = sync.round(answer(bob), memo: false, in: store, now: now, at: 0)
        #expect(ids(reply) == ["profile-a", "dm-old", "dm-new", "group-old", "group-new", "rest-new", "rest-old"])
        #expect(reply.released.filter(\.addressed).map(\.id) == ["dm-old", "dm-new"])
        // A non-member of that group gets the group frames among the rest, newest received first.
        let other = sync.round(answer(zed), memo: false, in: store, now: now, at: 0)
        #expect(ids(other) == ["profile-a", "rest-new", "group-old", "dm-old", "group-new", "dm-new", "rest-old"])
    }

    @Test func theThirdTierReadsTheRosterOfAGroupThatIsNotOurs() {
        // Alice carries a group of Bob's and Carol's she is not in: the frame's own roster orders it.
        let store = MemoryCustodyStore()
        var sync = CustodySync(own: alice)
        _ = sync.carry(frame("theirs", from: carol, members: [bob, carol]), in: store, now: now) { true }
        _ = sync.carry(frame("rest", from: carol), in: store, now: now + 1) { true }
        let reply = sync.round(answer(bob), memo: false, in: store, now: now, at: 0)
        #expect(ids(reply) == ["theirs", "rest"])
    }

    @Test func aNineMemberRosterAndAnUnclassifiedRowOrderInTheFourthTier() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        let nine = [bob] + (0..<8).map { fixtureNodeId(70 + $0) }
        _ = sync.carry(frame("nine", from: bob, members: nine), in: store, now: now) { true }
        // Stored behind the ledger's back, as a row kept before a restart: unclassified.
        store.store(frame("unread", from: bob, members: [alice, bob]), origin: .relayed, now: now + 1)
        _ = sync.carry(frame("rest", from: carol), in: store, now: now + 2) { true }
        let reply = sync.round(answer(bob), memo: false, in: store, now: now, at: 0)
        #expect(ids(reply) == ["rest", "unread", "nine"], "newest received first, as the fourth tier orders")
        // A row loaded to be sent is classified as it goes.
        #expect(reply.loaded.map(\.id) == ["rest", "unread", "nine"])
    }

    @Test func aRoundWithNothingToReleaseSendsNoKey() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("s1", from: carol), in: store, now: now) { true }
        let reply = sync.round(
            answer(bob, released: ["s1"]), memo: false, in: store, now: now, at: 0, crossed: { _ in false }, key: { Self.key(of: $0) })
        #expect(reply.frames.isEmpty && reply.keys.isEmpty && reply.keysAhead.isEmpty && reply.bytes == 0)
        #expect(reply.live == [ExactKey("s1")] && reply.senders == [ExactKey(carol.string)])
        #expect(!sync.wouldRelease(answer(bob, released: ["s1"]), memo: false, in: store, now: now, at: 0))
        #expect(sync.wouldRelease(answer(bob), memo: false, in: store, now: now, at: 0))
    }

    @Test func aKeyGoesAtMostOncePerAnswer() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("s1", from: carol), in: store, now: now) { true }
        var sent = answer(bob)
        sent.keysSent = [ExactKey(carol.string)]
        let first = sync.round(answer(bob), memo: false, in: store, now: now, at: 0, crossed: { _ in false }, key: { Self.key(of: $0) })
        let later = sync.round(sent, memo: false, in: store, now: now, at: 0, crossed: { _ in false }, key: { Self.key(of: $0) })
        #expect(first.keysAhead == [carol])
        #expect(later.keysAhead.isEmpty && ids(later) == ["s1"])
    }

    @Test func theMemoWithholdsAllButTheAskersOwnMail() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        _ = sync.carry(frame("dm", to: bob), in: store, now: now) { true }
        _ = sync.carry(frame("other", to: zed), in: store, now: now + 1) { true }
        let releases = [CustodySync.Release(id: "dm", addressed: false), CustodySync.Release(id: "other", addressed: false)]
        sync.ledger.released(releases, to: bob, now: 0, linked: [])
        #expect(ids(sync.round(answer(bob), memo: true, in: store, now: now, at: 1)) == ["dm"])
        #expect(ids(sync.round(answer(bob), memo: false, in: store, now: now, at: 1)) == ["dm", "other"])
    }

    @Test func cuttingRoundsLoadsNoRowTheyDoNotSend() {
        // At the cap, a thousand group rows and empty digests across three answers: only the frames sent are loaded.
        let held = MemoryCustodyStore()
        var sync = CustodySync()
        for index in 0..<1000 {
            _ = sync.carry(
                frame("g\(index)", from: carol, members: [carol, alice], payloadBytes: 400), in: held, now: now + Int64(index)
            ) { true }
        }
        let store = CountingCustody(held)
        var sent: [String] = []
        for _ in 0..<3 {
            var open = answer(bob)
            for _ in 0..<4 {
                let reply = sync.round(open, memo: false, in: store, now: now, at: 0)
                for release in reply.released {
                    open.released[ExactKey(release.id)] = 0
                }
                sent += ids(reply)
            }
        }
        #expect(!sent.isEmpty)
        #expect(store.loads == sent)
    }
}
