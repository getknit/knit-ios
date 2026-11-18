import Foundation
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The honest path behind ``SpoolSeenSetsTests/aStaleCopyFromTheRetiringScopeCountsNothingAndTheSecondPassLands(servedAfter:)``
/// (spool.md, "Before P7"): Bob's radio failures seal his reset and Alice adopts it, but her custody keeps X's first bytes,
/// so once the fresh root's scope exists her heal pushes her custodied X into it, a live `event` to Bob. However late the
/// push, the reset or the reopen's memo, the copy that fails leaves no mark (ADR 2026-11.adrq, P7 prep), and the second
/// pass lands X. Bob's own push into the fresh scope is held, every push refused for proof of work until Alice joins, as a
/// spool that already listed his copy would leave Alice nothing to push. In the lab Alice's original and Bob's stale copy
/// are different seals, so the cheap path never settles Alice's copy: it is opened once and fails.
extension SpoolSeenSetsTests {
    /// What ``healPushAfterReset(_:)`` varies beyond the reset's timing.
    private struct HealPush {
        var timing = ResetTiming()
        /// How long after Alice's adoption her heal pushes.
        var delay: Int64
        /// Whether X is gone from Bob's custody before the push.
        var evicted = false
        /// Runs just before Alice joins the relay.
        var beforePush: ((SpoolLab) -> Void)?
    }

    /// Runs the honest path as `push` says, and answers how Bob's router admitted Alice's copy of X: through the reopen's
    /// cheap path, or as a first sight.
    @discardableResult
    private static func healPushAfterReset(_ push: HealPush) throws -> (reopened: Int, admitted: Int) {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let (aliceNode, bobNode) = (lab[0], lab[1])
        var timing = push.timing
        timing.beforeConfirm = { lab.spool.refusesEveryPushPow = true }
        let left = try staleCopyAfterAReset(lab, timing)
        let frameX = left.ids[2]
        let fresh = try #require(lab.scopes(1).first { !$0.retiring }, "the fresh root's scope")
        #expect(lab.spool.liveIds(fresh.id).isEmpty, "Bob's push into it is held")
        lab.spool.refusesEveryPushPow = false
        if push.evicted {
            // Alice's custody would re-serve X by radio at the next digest, a radio copy whose mark is the radios' own
            // concern (spool.md, the accepted limits); the radio is held until the spool's copy has landed.
            lab.radio.hold(from: 0, to: 1)
            bobNode.stores.custody.remove(frameX)
        }
        lab.advance(max(0, left.adoptedAt + push.delay - aliceNode.clock.monotonicMilliseconds()))
        push.beforePush?(lab)

        let counted = counted(bobNode)
        let aeadBefore = aeadFails(bobNode)
        let before = bobNode.engine.routerCounters
        lab.connect(0)
        lab.run(1)
        let pushed = bobNode.engine.routerCounters
        let admitted = (reopened: pushed.spoolReopened - before.spoolReopened, admitted: pushed.spoolAdmitted - before.spoolAdmitted)
        #expect(admitted.reopened + admitted.admitted >= 1, "Alice's heal brought X")
        #expect(aeadFails(bobNode) == aeadBefore + 1, "a seal other than the one custody holds is opened once")
        #expect(!spoolMarks(bobNode, left.stale[2]), "and the copy that failed leaves no mark")
        #expect(pushed.spoolBridged == before.spoolBridged, "nor did it go onto the radios")
        if push.evicted {
            #expect(bobNode.stores.custody.frame(frameX, now: bobNode.clock.wallMilliseconds()) != nil, "custody carries X again")
            lab.radio.release(from: 0, to: 1) { items in
                items.filter { item in
                    guard case .frame(let written) = item else {
                        return true
                    }
                    return ExactKey(written.envelope.id) != ExactKey(frameX)
                }
            }
        }
        secondPassLands(lab, left, after: pushed.deduplicated, counted: counted)
        return admitted
    }

    /// Steps a minute at a time until X lands or Alice's second pass is past, and holds both sides to the one root.
    static func secondPassLands(_ lab: SpoolLab, _ left: ResetLeaves, after duplicates: Int, counted: Int) {
        let (aliceNode, bobNode) = (lab[0], lab[1])
        let frameX = left.ids[2]
        var unlanded = duplicates
        while bobNode.stores.messages.message(frameX) == nil, aliceNode.clock.monotonicMilliseconds() <= left.secondPassDue {
            unlanded = bobNode.engine.routerCounters.deduplicated
            lab.advance(minute)
        }
        #expect(unlanded == duplicates, "no copy was taken for one already seen before X landed")
        #expect(bobNode.stores.messages.message(frameX)?.body == "lost 2", "the re-seal landed, by the second pass at the latest")
        #expect(aliceNode.clock.monotonicMilliseconds() <= left.secondPassDue + minute, "within its re-offer tick")
        lab.pump()
        #expect(aliceNode.stores.messages.message(frameX)?.delivered == true, "and Bob acknowledged it")
        let resets = Set(bobNode.resetsSent(to: alice).map { ExactKey($0.envelope.id) })
        #expect(resets.count == 1 && Self.counted(bobNode) == counted, "one reset, and none counted since")
        let hashes = rootHashes(lab)
        #expect(hashes[0] != nil && hashes[0] == hashes[1], "both confirm the one root: \(hashes)")
        #expect(lab.radio.sessionsAgree(0, 1))
    }

    /// Ten seconds and two minutes after the adoption, inside the reopen's window, and ten and a half minutes after, past
    /// it, where a mark would once have outlived the second pass and X never landed.
    @Test(arguments: [10_000, 2 * SpoolEngineLabTests.minute, 630_000])
    func aHealPushOfTheOriginalAfterAResetMarksNothingAndTheSecondPassLands(pushedAfter delay: Int64) throws {
        let admitted = try Self.healPushAfterReset(HealPush(delay: delay))
        #expect(admitted.reopened == (delay < SeenSet.defaultWindowMilliseconds ? 1 : 0), "the cheap path while the reopen holds")
    }

    /// The reset reaches Alice fifteen minutes after Bob's failures, long past the reopen's window, and her heal pushes ten
    /// seconds after she adopts it.
    @Test func aResetThatReachesAliceLateStillLandsX() throws {
        try Self.healPushAfterReset(HealPush(timing: ResetTiming(reachesAliceAfter: 15 * SpoolEngineLabTests.minute), delay: 10_000))
    }

    /// The reset is sealed nine minutes after X's own failure, and Alice's heal pushes two minutes after she adopts it.
    @Test func aResetSealedNineMinutesAfterXsFailureStillLandsX() throws {
        let timing = ResetTiming(xFailsEarlier: 9 * SpoolEngineLabTests.minute)
        try Self.healPushAfterReset(HealPush(timing: timing, delay: 2 * SpoolEngineLabTests.minute))
    }

    /// Custody let X go first, so the pushed copy is carried and opened once, marked in neither set and never bridged, and
    /// the second pass still lands it.
    @Test func anEvictedXPushedAfterAResetIsOpenedOnceUnmarkedAndTheSecondPassLands() throws {
        try Self.healPushAfterReset(HealPush(delay: 2 * SpoolEngineLabTests.minute, evicted: true))
    }

    /// Three hundred other reopens follow X's, more than the reopen memo keeps, before Alice's heal pushes ten seconds after
    /// the adoption, driven through Bob's router. The cheap path is gone, and the copy that fails still leaves no mark.
    @Test func aFlushedReopenMemoStillLandsX() throws {
        let admitted = try Self.healPushAfterReset(
            HealPush(delay: 10_000) { lab in
                let node = lab[1]
                let now = node.clock.monotonicMilliseconds()
                for index in 0..<300 {
                    let id = frameIdOf("flush \(index)")
                    node.engine.router.markOwn(id, now: now)
                    _ = node.engine.router.reopen(id, now: now)
                }
            }
        )
        #expect(admitted.admitted == 1 && admitted.reopened == 0, "X's reopen was flushed, so its copy is a first sight")
    }

    /// Alice's custody lost X before her re-seal, so the re-seal is what it carries and her heal pushes; Bob's custody holds
    /// the stale seal, and the radio carries nothing of X to Bob. The spool's re-seal is other bytes than custody's, so it is
    /// opened, delivers X, is marked as a delivered copy is, and is not bridged, since custody held the id before.
    @Test func aReSealOnlyTheFreshScopeCarriesLandsFromTheSpool() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let (aliceNode, bobNode) = (lab[0], lab[1])
        let left = try Self.staleCopyAfterAReset(lab, ResetTiming { ids in aliceNode.stores.custody.remove(ids[2]) })
        let frameX = left.ids[2]
        lab.radio.hold(from: 0, to: 1)
        let wall = aliceNode.clock.wallMilliseconds()
        #expect(aliceNode.stores.custody.frame(frameX, now: wall)?.signed == left.firstReseal.wire.signed, "Alice carries the re-seal")
        #expect(bobNode.stores.messages.message(frameX) == nil)

        let before = bobNode.engine.routerCounters
        let bridged = bobNode.engine.spoolInbound.counts.bridged
        lab.connect(0)
        lab.run(1)
        #expect(bobNode.stores.messages.message(frameX)?.body == "lost 2", "the spool's re-seal landed X")
        #expect(bobNode.engine.routerCounters.spoolReopened == before.spoolReopened + 1, "through the reopen, other bytes")
        #expect(Self.spoolMarks(bobNode, left.stale[2]), "and the copy that delivered is marked")
        #expect(bobNode.engine.routerCounters.spoolBridged == before.spoolBridged && bobNode.engine.spoolInbound.counts.bridged == bridged)
        #expect(bobNode.stores.custody.frame(frameX, now: bobNode.clock.wallMilliseconds())?.signed == left.stale[2].wire.signed)
        lab.radio.release(from: 0, to: 1)
        lab.pump()
        #expect(aliceNode.stores.messages.message(frameX)?.delivered == true, "and Bob acknowledged it")
        #expect(bobNode.resetsSent(to: Self.alice).count == 1)
        let hashes = Self.rootHashes(lab)
        #expect(hashes[0] != nil && hashes[0] == hashes[1], "both confirm the one root: \(hashes)")
        #expect(lab.radio.sessionsAgree(0, 1))
    }

    /// The accepted limit (spool.md, "Accepted limit, a spool's first sight"): X never reaches Bob by radio, so his custody
    /// does not hold it and no reopen of it is live. Bob's reset makes Alice re-seal X, pass 1 held; the retiring scope
    /// serves X's old seal two minutes before pass 2, a first sight that keeps its mark, and pass 2 is deduplicated.
    @Test func aFirstSightOfXsOldSealBeforeTheSecondPassKeepsItsMark() throws {
        let lab = try SpoolEngineLabTests.greeted()
        SpoolEngineLabTests.online(lab, [1])
        let (aliceNode, bobNode) = (lab[0], lab[1])
        let left = try Self.staleCopyAfterAReset(lab, ResetTiming(xByRadio: false))
        let frameX = left.ids[2]
        #expect(bobNode.stores.custody.frame(frameX, now: bobNode.clock.wallMilliseconds()) == nil, "custody never held X")
        // Alice's custody would hand Bob her original X at the next digest: the radio's own limit, kept out of this one.
        lab.radio.hold(from: 0, to: 1)
        let original = aliceNode.stores.custody.frame(frameX, now: aliceNode.clock.wallMilliseconds())?.signed
        lab.advance(max(0, left.secondPassDue - 2 * Self.minute - aliceNode.clock.monotonicMilliseconds()))
        let kept = lab.scopes(1).first(where: \.retiring)
        let retiring = try #require(kept, "the replaced root's scope, kept retiring")
        try ForeignSession.serve(left.stale[2], in: retiring, on: lab)
        #expect(Self.spoolMarks(bobNode, left.stale[2]), "a first sight keeps its mark")
        lab.advance(max(0, left.secondPassDue + Self.minute - aliceNode.clock.monotonicMilliseconds()))
        let duplicates = bobNode.engine.routerCounters.deduplicated
        lab.radio.release(from: 0, to: 1) { items in
            items.filter { item in
                guard case .frame(let written) = item else {
                    return true
                }
                return ExactKey(written.envelope.id) != ExactKey(frameX) || written.wire.signed != original
            }
        }
        lab.pump()
        #expect(bobNode.engine.routerCounters.deduplicated > duplicates, "pass 2 is taken for the spool's copy")
        withKnownIssue("accepted limit: a first sight's mark deduplicates pass 2 until the paired fix with knit-next") {
            #expect(bobNode.stores.messages.message(frameX)?.body == "lost 2", "pass 2 lands X")
        }
    }

    /// A spool copy whose ratchet unit failed is kept for the replay, and the sweep's replay fails it again outside any door
    /// turn; a later spool copy of the same id delivers, counted undelivered once, and keeps its mark.
    @Test func aReplayOutsideTheDoorLeavesNoNoteForTheNextCopy() throws {
        let directory = scratchDirectory("spool-replay-note")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.memory.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let node = try EngineFixture.ratcheting(Self.bob, stores: stores)
        let android = try AndroidPeer(Self.alice)
        try node.pin(android)
        let now = node.clock.wallMilliseconds()
        let prekey = try node.ourPrekey()
        let frame = try android.dm(MessageContent(body: "kept"), to: Self.bob, prekey: prekey, id: frameIdOf("kept"), sentAt: now)
        let candidate = try SpoolCandidates.candidate(frame, for: Self.bob, with: Self.alice, now: now)
        let relay = SpoolRelayHandle(number: 1)

        refusing.refusesWrites = true
        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(node.engine.dropped[.storeRefused] == 1 && node.engine.spoolInbound.counts.undelivered == 1, "left for the replay")
        node.advance(MeshConfiguration().sweepMilliseconds)
        #expect(node.engine.dropped[.storeRefused] == 2, "the sweep's replay failed it again")
        refusing.refusesWrites = false

        #expect(node.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        #expect(node.stores.messages.message(frame.envelope.id)?.body == "kept", "the later copy delivered")
        #expect(node.engine.spoolInbound.counts.undelivered == 1, "and was not read as undelivered")
        #expect(Self.spoolMarks(node, frame), "so it keeps its mark")
    }
}
