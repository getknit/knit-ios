import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The start's replay out of our own custody only delivers (ADR 2026-10.5sk9, phase P5a; the crypto review's first
/// finding): a frame it hands back that fails counts under its reason alone, never toward a reset, and an init the held
/// session has not resolved moves no era. Kotlin replays nothing from its own custody, so it never meets either. Each
/// restart is a new engine over the same stores and keychain.
@Suite struct MeshEngineRatchetStartReplayTests {
    /// The iPhone, whose node id sorts first, so a race it is in is its own to win and a replay meets the replacement.
    private let me: TestPeer
    private let alice: TestPeer
    /// A carrier that serves a frame again.
    private let carol = TestPeer(seed: 3)
    private static let minute: Int64 = 60_000
    private static let hour: Int64 = 3_600_000
    private var now: Int64 { EngineFixture.start }

    init() {
        let pair = [TestPeer(seed: 1), TestPeer(seed: 2)].sorted { $0.nodeId < $1.nodeId }
        me = pair[0]
        alice = pair[1]
    }

    /// The failures our custody keeps after our own reset: three from a session we do not share buy it, and three
    /// more, sealed under the root it leaves, fail inside its 6 h floor. All six stay in custody with no row.
    private func resetWithItsTail(_ stores: MeshStores, keychain: KeptSecretStore) throws {
        let first = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        try first.deliverUnreadable(from: android, tag: "before", sentAt: now)
        #expect(first.resetsSent(to: alice).count == 1)
        first.clock.advance(Self.minute)
        try first.deliverUnreadable(from: android, tag: "after", sentAt: now + Self.minute, now: now + Self.minute)
        #expect(first.resetsSent(to: alice).count == 1, "inside the floor")
        #expect(stores.custody.liveIds(now: now + Self.minute).filter { $0.hasPrefix("before-") || $0.hasPrefix("after-") }.count == 6)
    }

    /// The six failures a restart's replay counted, under their reasons.
    private func replayedFailures(_ fixture: EngineFixture) -> Int {
        [DropReason.ratchetNoSession, .ratchetEpochGone, .ratchetAeadFail].reduce(0) { $0 + fixture.engine.dropped[$1, default: 0] }
    }

    @Test func aRestartPastTheFloorBuysNoResetWithTheTailOurOwnResetLeftInCustody() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        try resetWithItsTail(stores, keychain: keychain)

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 6 * Self.hour + Self.minute)
        #expect(replayedFailures(restarted) == 6, "each one opened again, and failed again")
        #expect(restarted.resetsSent(to: alice).isEmpty, "a tail our own custody kept is no evidence")
        #expect(restarted.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)
    }

    /// A start's replay whose unit fails is kept as one: the sweep that opens it again gives it no first verdict.
    @Test func aStartReplayWhoseUnitFailsIsStillOneAtTheSweep() throws {
        let refusing = RefusingRatchetStore()
        let stores = MeshStores.inMemory().replacing(ratchet: refusing, transactor: refusing.transactor)
        let keychain = KeptSecretStore(me.keys.storedForm)
        try resetWithItsTail(stores, keychain: keychain)

        refusing.refuse(.reads)
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 6 * Self.hour + Self.minute)
        #expect(restarted.engine.dropped[.storeRefused] == 6)
        refusing.refuse([])
        restarted.advance(MeshConfiguration().sweepMilliseconds)
        #expect(replayedFailures(restarted) == 6, "opened again at the sweep, and failed")
        #expect(restarted.resetsSent(to: alice).isEmpty)
        #expect(restarted.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)
    }

    /// The crypto review's skewed variant: Android resets with its clock ahead of ours, the iPhone adopts it and re-roots
    /// two minutes later, Android adopts that, and a restart within the day finds Android's reset in custody. Its init is
    /// newer, by Android's clock, than the session the iPhone holds, and the floor that kept it out died with the process:
    /// as a first verdict it would take the iPhone back to a root Android has left. Android runs four minutes ahead, not
    /// ten: our custody refuses a frame dated more than five minutes ahead (`CustodyRules.expiry`), so a reset from a
    /// phone ten minutes fast reaches it only in a later re-serve, and four minutes still outruns the two-minute gap.
    @Test func aRestartWithinADayKeepsTheRootTheIPhoneReRootedTo() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let first = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        let prekey = try first.ourPrekey()
        let ahead = 4 * Self.minute

        first.deliver(try android.resetDm(to: me, prekey: prekey, id: "android-reset", at: now + ahead), from: android)
        #expect(first.ratchetRecords(of: alice).session?.establishedAt == now + ahead, "adopted, at Android's stamp")
        #expect(stores.custody.contains("android-reset"), "carried, so a restart finds it")

        first.clock.advance(2 * Self.minute)
        guard case .sent(_, reRooted: true) = first.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our re-root goes")
            return
        }
        let ours = try #require(first.resetsSent(to: alice).last)
        _ = try android.open(ours, from: me, now: now + ahead + 2 * Self.minute)
        let answer = now + ahead + 2 * Self.minute + 1000
        first.deliver(try android.dm("under yours", to: me, prekey: prekey, id: "under-yours", sentAt: answer), from: android)
        #expect(first.stores.messages.message("under-yours")?.body == "under yours")
        let held = try #require(first.ratchetRecords(of: alice).session)
        #expect(held.confirmed && held.weAreInitiator && held.establishedAt == now + 2 * Self.minute)
        #expect(held.root == android.session(with: me)?.root, "Android lost the race to our re-root and took it")

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + Self.hour)
        let kept = try #require(restarted.ratchetRecords(of: alice).session)
        #expect(kept.root == held.root && kept.establishedAt == held.establishedAt, "the replay moved no era")
        // What the re-root left of Android's era is its root, draining: the reset opens again under it, read and never
        // adopted, and its marker applies nothing.
        #expect(restarted.engine.dropped.isEmpty)
        #expect(restarted.resetsSent(to: alice).isEmpty)
        let later = now + ahead + Self.hour
        restarted.deliver(try android.dm("still yours", to: me, prekey: prekey, id: "still-yours", sentAt: later), from: android)
        #expect(restarted.stores.messages.message("still-yours")?.body == "still yours", "the pair still reads")
    }

    /// The crypto re-review's second finding. Android, its clock 30 minutes fast, sends `older` and, ten minutes later by
    /// our clock, `newer`: each is ordered at the stamp `clampFuture` gave it at its first open, five minutes past our clock
    /// then, and `held` reads `newer`'s value. `older` comes back once our custody may keep it and opens as a duplicate,
    /// we reset, leaving its era draining, and a restart comes before `newer` is served again. Re-opened there, `older`
    /// would be clamped again, later, and outrank `newer`.
    private func restartAfterAFastPeersOlderAndNewer(
        _ older: MessageContent, _ newer: MessageContent, in stores: MeshStores, held: () -> String?
    ) throws {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let first = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        let prekey = try first.ourPrekey()
        let fast = 30 * Self.minute
        let olderFrame = try android.dm(older, to: me, prekey: prekey, id: "older", sentAt: now + fast)
        first.deliver(olderFrame, from: android)
        #expect(!stores.custody.contains("older"), "refused by custody as dated ahead")
        first.clock.advance(10 * Self.minute)
        first.deliver(try android.dm(newer, to: me, prekey: prekey, id: "newer", sentAt: now + fast + 10 * Self.minute), from: android)
        let shown = held()

        first.clock.advance(15 * Self.minute)
        first.deliver(olderFrame, from: carol)
        #expect(stores.custody.contains("older") && first.engine.dropped[.ratchetDuplicate] == 1)
        #expect(held() == shown)
        guard case .sent = first.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our reset goes")
            return
        }
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 26 * Self.minute)
        #expect(restarted.engine.dropped.isEmpty, "the older frame opened again under the draining root")
        #expect(held() == shown, "and applied nothing")
    }

    @Test func aRestartKeepsTheNewerReactionOfAPeerWhoseClockRunsFast() throws {
        let stores = MeshStores.inMemory()
        func reaction(_ emoji: String) -> MessageContent {
            MessageContent(body: "", ctl: MessageContent.Control.reaction, rp: ReactionContent(messageId: "m1", emoji: emoji))
        }
        let held = { stores.messages.reaction(on: "m1", by: alice.nodeId)?.emoji }
        try restartAfterAFastPeersOlderAndNewer(reaction("👍"), reaction("❤️"), in: stores, held: held)
        #expect(held() == "❤️")
    }

    @Test func aRestartKeepsTheNewerProfileOfAPeerWhoseClockRunsFast() throws {
        let stores = MeshStores.inMemory()
        func profile(_ name: String, at version: Int64) -> MessageContent {
            MessageContent(body: "", ctl: MessageContent.Control.profile, pr: ProfilePayload(name: name, status: "", version: version))
        }
        let older = profile("Ann", at: now + 30 * Self.minute)
        let newer = profile("Annie", at: now + 40 * Self.minute)
        let held = { stores.peers.peer(alice.nodeId)?.name }
        try restartAfterAFastPeersOlderAndNewer(older, newer, in: stores, held: held)
        #expect(held() == "Annie")
    }
}
