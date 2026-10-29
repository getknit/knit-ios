import KnitMesh
import KnitStore
import KnitStoreSQL
import KnitTestSupport
import KnitWire
import Testing

/// A capped reply round (ADR 2026-10.f5zs): at most ``CustodySync/roundFrames`` frames or ``CustodySync/roundBytes`` with
/// the keys ahead, picked from the index, minus what crossed the link, stopping at its budget and never skipping.
@Suite struct CustodySyncRoundTests: CustodySyncCase {
    @Test func aDMBehindFourHundredGroupFramesThePeerIsNotInFollowsThemOnceEach() {
        // A group frame goes to a non-member that lacks it (knit-next ADR 2026-10.hr9f), so each takes a slot: the newer
        // group frames fill the first two rounds of 200, and the DM goes in the third. That is the back-fill, once per frame,
        // the crossings keeping each slice from coming again. Before, a group frame without the peer skipped ahead of the
        // budget check, and the DM went alone in the first round.
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
        for _ in 0..<5 {
            let reply = round(sync, for: zed, in: store, crossed: crossed)
            crossed.formUnion((reply.keys + reply.frames).map(Self.frameKey))
            rounds.append(ids(reply))
            #expect(reply.bytes <= CustodySync.roundBytes, "200 group frames and their keys fit the bytes: the frame count caps")
            guard reply.isCapped else {
                break
            }
        }
        #expect(rounds.map(\.count) == [CustodySync.roundFrames, CustodySync.roundFrames, 1], "three rounds, the budget's own")
        #expect(rounds.last == ["dm"], "the DM, oldest received, in the last")
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
        #expect(reply.isCapped, "150 frames alone fit; with their keys they do not")
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

    @Test func aRoundServesAtMostTwoHundredFrames() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        for index in 0..<250 {
            _ = sync.carry(frame("m\(index)", from: fixtureNodeId(40 + index % 5), to: bob), in: store, now: now + Int64(index)) { true }
        }
        let first = round(sync, for: zed, in: store)
        #expect(first.frames.count == CustodySync.roundFrames)
        #expect(first.isCapped)
        #expect(ids(first).first == "m249", "newest received first")
        let second = round(sync, for: zed, in: store, crossed: Set((first.frames + first.keys).map(Self.frameKey)))
        #expect(second.frames.count == 50)
        #expect(!second.isCapped)
        #expect(Set(ids(first) + ids(second)).count == 250)
    }

    @Test func aRoundServesAtMostItsBytes() {
        let store = MemoryCustodyStore()
        var sync = CustodySync()
        for index in 0..<40 {
            _ = sync.carry(frame("m\(index)", to: bob, payloadBytes: 10 * 1024), in: store, now: now + Int64(index)) { true }
        }
        let reply = round(sync, for: zed, in: store, keyBytes: 0)
        let each = reply.frames.first?.encoded.count ?? 0
        #expect(reply.isCapped)
        #expect(reply.bytes <= CustodySync.roundBytes)
        #expect(reply.bytes + each > CustodySync.roundBytes)
        #expect(reply.frames.count == 25)
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

    @Test func aPeerThatKeepsOneFrameInFiveIsServedEveryKeepableFrameInFiveRounds() {
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
        for _ in 0..<5 {
            let reply = round(sync, from: kept, for: zed, in: store, crossed: crossed)
            crossed.formUnion((reply.keys + reply.frames).map(Self.frameKey))
            kept += ids(reply).filter(keepable.contains)
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
