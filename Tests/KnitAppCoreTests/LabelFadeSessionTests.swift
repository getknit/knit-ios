import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire
import Testing

@testable import KnitAppCore

/// A stranger's name clash fades in the session's directory a week after they were last heard, ported from the fade cases
/// of knit-next's `PeerRepositoryTest` and `NameClashFadeLabTest` (ADR 2026-10.k8ge there).
@MainActor
@Suite struct LabelFadeSessionTests {
    private static let start: Int64 = 1_800_000_000_000
    private static let pastTheWeek = LabelFade.windowMilliseconds + LabelFade.tickMilliseconds

    private let clock = Lock<Int64>(start)
    private let refusing: RefusingAcceptedReads
    private let rig: AppRig

    init() {
        (rig, refusing) = AppRig.fading(clock: clock)
    }

    private var sam: NodeId { AppRig.sam.nodeId }
    private var stranger: NodeId { AppRig.stranger.nodeId }

    private func label(_ peer: NodeId) -> PeerLabel {
        rig.session.directory.label(for: peer)
    }

    /// Pins `person` under `name`, last heard at `heard`.
    private func pin(_ person: Person, _ name: String, heard: Int64 = start, verified: Bool = false) async {
        var record = person.record(name: name, verified: verified)
        record.lastSeenAt = heard
        rig.stores.peers.upsert(record)
        await rig.session.handle(.peerUpdated(person.nodeId))
    }

    private func pass(_ milliseconds: Int64) {
        clock.withLock { $0 += milliseconds }
    }

    @Test func aStrangersClashFadesOnTheCalendarAloneAndTheNotificationAgrees() async throws {
        rig.stores.conversations.accept(sam.string)
        await pin(AppRig.sam, "Alice")
        await pin(AppRig.stranger, "Alice")
        #expect(label(sam).text == "Alice (\(Alias.alias(for: sam.string)))")

        pass(Self.pastTheWeek)
        let revision = rig.session.revision
        rig.session.judgeLabelFade()
        #expect(rig.session.revision == revision + 1, "a stranger crossed the week with nothing written")
        #expect(rig.session.directory.stale == [stranger])
        #expect(label(sam).text == "Alice", "the contact reads plain again")
        #expect(label(stranger).discriminator == Alias.alias(for: stranger.string), "the stranger keeps a label of its own")

        rig.session.judgeLabelFade()
        #expect(rig.session.revision == revision + 1, "a judge that moves nobody moves no revision")

        await rig.receive("See you at 6", from: sam, to: rig.me, sentAt: Self.start, arrivedAt: Self.start)
        #expect(try #require(rig.notifier.posted.last).title == "Alice")
    }

    @Test func anAnchoredOrVerifiedPeerNeverGoesStaleWhicheverSignalAnchorsIt() async {
        let authored = Person(seed: 40)
        let member = Person(seed: 41)
        let verified = Person(seed: 42)
        rig.stores.conversations.accept(sam.string)
        await pin(AppRig.sam, "Alice")
        for person in [authored, member, AppRig.stranger] {
            await pin(person, "Alice")
        }
        await pin(verified, "Alice", verified: true)
        await rig.receive("Hi", from: rig.me, to: authored.nodeId)
        _ = await rig.group([member], createdBy: AppRig.me)

        pass(Self.pastTheWeek)
        rig.session.judgeLabelFade()
        #expect(rig.session.directory.stale == [stranger], "only the quiet stranger yields")
        #expect(label(sam).discriminator != nil, "four Alices still clash")
    }

    @Test func acceptingAQuietStrangerBringsTheClashBack() async {
        rig.stores.conversations.accept(sam.string)
        await pin(AppRig.sam, "Alice")
        await pin(AppRig.stranger, "Alice")
        pass(Self.pastTheWeek)
        rig.session.judgeLabelFade()
        #expect(label(sam).text == "Alice")

        await rig.session.accept(stranger.string)
        #expect(rig.session.directory.stale.isEmpty)
        #expect(label(sam).discriminator == Alias.alias(for: sam.string))
    }

    @Test func aFadedStrangerHeardAgainBringsTheClashBackAndALivePeerHeardMovesNothing() async {
        rig.stores.conversations.accept(sam.string)
        await pin(AppRig.sam, "Alice")
        await pin(AppRig.stranger, "Alice")
        pass(Self.pastTheWeek)
        rig.session.judgeLabelFade()

        let revision = rig.session.revision
        await rig.session.handle(.peersHeard([sam]))
        #expect(rig.session.revision == revision, "a peer that was never let go reads the same")

        _ = rig.stores.peers.markSeen([stranger: Self.start + Self.pastTheWeek], gate: 0)
        await rig.session.handle(.peersHeard([stranger]))
        #expect(rig.session.revision == revision + 1)
        #expect(rig.session.directory.stale.isEmpty)
        #expect(label(sam).discriminator == Alias.alias(for: sam.string), "the clash is back")
    }

    @Test func aQuietStrangerThatClashesWithNobodyNeverCostsTheAnchors() async {
        await pin(AppRig.stranger, "Eve")
        await pin(AppRig.sam, "Sam")
        pass(Self.pastTheWeek)
        let reads = refusing.reads
        rig.session.judgeLabelFade()
        #expect(rig.session.directory.stale.isEmpty, "giving way would move no label, so nobody is judged")
        #expect(refusing.reads == reads)
    }

    @Test func anAnchorsReadThatFailsKeepsEveryClash() async {
        rig.stores.conversations.accept(sam.string)
        await pin(AppRig.sam, "Alice", heard: 0)
        await pin(AppRig.stranger, "Alice")
        pass(Self.pastTheWeek)
        refusing.failsReads = true
        let reads = refusing.reads
        rig.session.judgeLabelFade()
        #expect(refusing.reads > reads, "the anchors were read, and the read failed")
        #expect(rig.session.directory.stale.isEmpty, "with no anchors, the quiet contact would have read as a stranger")
        #expect(label(sam).discriminator == Alias.alias(for: sam.string))

        refusing.failsReads = false
        rig.session.judgeLabelFade()
        #expect(rig.session.directory.stale == [stranger], "the next judge reads them")
    }

    @Test func aSessionWithoutAClockNeverFades() {
        let timeless = AppRig()
        var record = AppRig.stranger.record(name: "Alice")
        record.lastSeenAt = 0
        timeless.stores.peers.upsert(record)
        timeless.stores.peers.upsert(AppRig.sam.record(name: "Alice"))
        timeless.session.judgeLabelFade()
        #expect(timeless.session.directory.stale.isEmpty)
        #expect(timeless.session.directory.label(for: AppRig.sam.nodeId).discriminator != nil)
    }
}

extension AppRig {
    /// A rig over `stores` whose session `make` builds over them, its fake mesh and its notifier.
    init(stores: MeshStores, _ make: (MeshStores, FakeMesh, RecordingNotifier) -> AppSession) {
        self.stores = stores
        mesh = FakeMesh(nodeId: Self.me.nodeId, stores: stores, radio: nil, keys: Self.me.keys)
        notifier = RecordingNotifier()
        session = make(stores, mesh, notifier)
    }

    /// A rig whose session fades clashes by `clock`, over stores whose read of the accepted threads can be made to fail as
    /// a database that cannot read its file fails it.
    static func fading(clock: Lock<Int64>) -> (Self, RefusingAcceptedReads) {
        let memory = MeshStores.inMemory()
        let transactor = memory.transactor as? MemoryTransactor
        let refusing = RefusingAcceptedReads(memory.conversations) { transactor?.failCurrentUnit() }
        let stores = MeshStores(
            custody: memory.custody,
            peers: memory.peers,
            messages: memory.messages,
            conversations: refusing,
            blocks: memory.blocks,
            groups: memory.groups,
            ownProfile: memory.ownProfile,
            blobs: memory.blobs,
            ratchet: memory.ratchet,
            groupRatchet: memory.groupRatchet,
            presenceKeys: memory.presenceKeys,
            transactor: memory.transactor
        )
        let now: @Sendable () -> Int64 = { clock.withLock { $0 } }
        let rig = Self(stores: stores) { stores, mesh, notifier in
            AppSession(identity: OwnIdentity(bundle: Self.me.bundle), stores: stores, mesh: mesh, notifier: notifier, now: now)
        }
        return (rig, refusing)
    }
}

/// A conversation store whose read of the accepted threads fails when told to: it fails the store unit it runs in and
/// answers none, the store's fallback, as `KnitMeshTests`' `RefusingConversationReads` does.
final class RefusingAcceptedReads: ConversationStore {
    private let held: any ConversationStore
    private let refuse: @Sendable () -> Void
    private let state = Lock((fails: false, reads: 0))

    init(_ held: any ConversationStore, refuse: @escaping @Sendable () -> Void) {
        self.held = held
        self.refuse = refuse
    }

    /// Whether a read of the accepted threads fails now.
    var failsReads: Bool {
        get { state.withLock { $0.fails } }
        set { state.withLock { $0.fails = newValue } }
    }

    /// How many reads of the accepted threads were made.
    var reads: Int { state.withLock { $0.reads } }

    func acceptedConversations() -> Set<String> {
        let fails = state.withLock { state in
            state.reads += 1
            return state.fails
        }
        guard !fails else {
            refuse()
            return []
        }
        return held.acceptedConversations()
    }

    func accept(_ conversationId: String) { held.accept(conversationId) }
}
