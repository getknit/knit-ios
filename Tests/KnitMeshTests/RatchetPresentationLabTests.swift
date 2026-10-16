import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The presentation plane sealed, between engines of this port with the ratchet's switch on (ADR 2026-10.5sk9, phase P5e),
/// on links a test makes and breaks (``EngineLab``): an init's answer confirming its initiator, our reactions applied by
/// the other phone, and knit-next's `ProfileUpdateLabTest` (`mesh/lab/ProfileUpdateLabTest.kt`, at `cbf2a487`) by name. A
/// profile edit lands on a contact's row from either writer, the cleartext profile or the sealed `CTL_PROFILE`, ordered on
/// the owner's version alone. This port writes no rename line into a DM thread, so `aRenameReachesAContactAndAStrangerAlike`
/// checks the rows and not the line; and a lab here carries frames and digests, never a FILE, so
/// `anAvatarCrossesWithTheProfile` checks the photo's hash, not its bytes. The blobs review's custody cases follow: three
/// custodies with a carrier without the switch among them, and the rows a relaunch and a new session add.
@Suite struct RatchetPresentationLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    /// Alice and Bob, each with the switch on, linked, so each has pinned the other.
    private func pair() throws -> EngineLab {
        let lab = EngineLab([try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12)])
        lab.link(0, 1)
        return lab
    }

    /// Bob's DM to Alice and the answer it earns: both sides then hold the session confirmed, Bob as its initiator.
    private func acquainted(_ lab: EngineLab) throws {
        _ = try #require(lab[1].engine.sendDirectMessage("hi alice", to: alice.nodeId))
        lab.carry()
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == true && lab[1].ratchetRecords(of: alice).session?.confirmed == true)
    }

    /// Alice (0) and Bob (2) apart, with Carol (1), a carrier without the switch, between them: all three linked first, so
    /// each has pinned the others, then Alice and Bob unlinked, so what they send each other crosses Carol.
    private func line() throws -> EngineLab {
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, seed: 11), EngineFixture(carol, seed: 13), try EngineFixture.ratcheting(bob, seed: 12),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        lab.unlink(0, 2)
        return lab
    }

    /// Carries what was just written, then moves the lab on past a relay's jitter twice: what one end of the line floods
    /// reaches the other through Carol, and what it answers comes back.
    private func cross(_ lab: EngineLab) {
        lab.carry()
        let jitter = lab[1].engine.configuration.router.jitterWindowMilliseconds
        lab.advance(jitter)
        lab.advance(jitter)
    }

    /// The distinct ids of the DM-form chats node `from` sealed to node `to`, in the order first written.
    private func sealedIds(_ lab: EngineLab, from: Int, to: Int) -> [String] {
        let sender = ExactKey(lab[from].me.nodeId.string)
        let peer = ExactKey(lab[to].me.nodeId.string)
        return EngineFixture.once(lab[from].transport.written(.chat)).filter { written in
            ExactKey(written.envelope.senderId) == sender && written.envelope.recipientId.map(ExactKey.init) == peer
        }.map(\.envelope.id)
    }

    /// The ids of node `sender`'s frames that node `index`'s custody holds live: the rows of `sender`'s in that custody.
    private func rows(of sender: Int, in index: Int, _ lab: EngineLab) -> Set<String> {
        let id = ExactKey(lab[sender].me.nodeId.string)
        let frames = lab[index].stores.custody.liveFrames(now: lab[index].clock.wallMilliseconds())
        return Set(frames.filter { ExactKey($0.envelope.senderId) == id }.map(\.envelope.id))
    }

    /// The rows of node `sender`'s in node 0's custody and in node 1's.
    private func rows(of sender: Int, _ lab: EngineLab) -> [Set<String>] {
        [rows(of: sender, in: 0, lab), rows(of: sender, in: 1, lab)]
    }

    /// What `from` held for `to`, released with every frame `drop` names left out, digests kept.
    private func release(_ lab: EngineLab, from: Int, to: Int, dropping drop: @escaping (EngineLab.Carried) -> Bool) {
        lab.release(from: from, to: to) { held in held.filter { !drop($0) } }
    }

    /// An answer alone confirms its initiator: Bob's frames to Alice are held, and only his answer to her init goes, his
    /// receipt dropped. Her session confirms on it, and her next DM carries no init.
    @Test func anAnswerAloneConfirmsTheInitiator() throws {
        let lab = try pair()
        lab.hold(from: 1, to: 0)
        let first = try #require(lab[0].engine.sendDirectMessage("hello", to: bob.nodeId))
        lab.carry()
        #expect(lab[1].stores.messages.message(first.id)?.body == "hello")
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == false, "Alice waits for an answer")
        let answers = lab[1].answerIds
        #expect(answers.count == 1 && lab[1].engine.answers.introsAnswered == 1)
        release(lab, from: 1, to: 0) { item in item.id.map { !answers.contains(ExactKey($0)) } ?? false }
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == true, "his answer alone confirmed her")
        #expect(lab[0].stores.messages.message(first.id)?.delivered == false, "his receipt never came")

        let next = try #require(lab[0].engine.sendDirectMessage("again", to: bob.nodeId))
        lab.carry()
        let written = try #require(lab.chats(from: 0, to: 1, id: next.id).first)
        #expect(try ChatContent(decoding: written.envelope.payload).enc?.ratchet?.initial == nil, "and her init rides no more")
        #expect(lab[1].engine.answers.introsAnswered == 1, "which nothing answers")
    }

    /// Our reaction to a DM, sealed, is applied by the other phone's ratchet arm (phase P5a) with the reactor its signature
    /// proves, and so is its retraction.
    @Test func aSealedReactionAndItsRetractionAreAppliedByTheOtherPhone() throws {
        let lab = try pair()
        try acquainted(lab)
        let dm = try #require(lab[1].stores.messages.messages(in: alice.nodeId.string).first)
        _ = try #require(lab[0].engine.react(to: dm.id, with: "👍"))
        lab.carry()
        #expect(lab[1].stores.messages.reaction(on: dm.id, by: alice.nodeId)?.emoji == "👍")
        #expect(lab[0].transport.written(.reaction).isEmpty && lab[0].engine.seals.reactionsSealed == 1, "never in the clear")
        _ = try #require(lab[0].engine.react(to: dm.id, with: "👍"))
        lab.carry()
        let held = try #require(lab[1].stores.messages.reaction(on: dm.id, by: alice.nodeId))
        #expect(held.emoji == nil, "taken back")
        #expect(lab[0].engine.seals.reactionsSealed == 2)
    }

    /// `aRenameReachesAContactAndAStrangerAlike` (`ProfileUpdateLabTest.kt:59-90`): Alice and Bob hold a session, Carol only
    /// shares the room with Alice. Alice renames, and both rows move: Bob's from either writer, Carol's from the cleartext
    /// profile alone, since nothing of the session's goes to her.
    @Test func aRenameReachesAContactAndAStrangerAlike() throws {
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12),
            try EngineFixture.ratcheting(carol, seed: 13),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        try acquainted(lab)
        lab[0].engine.updateProfile(name: "Alice the Second", status: "", openToChat: false)
        lab.carry()
        #expect(lab[1].stores.peers.peer(alice.nodeId)?.name == "Alice the Second")
        #expect(lab[2].stores.peers.peer(alice.nodeId)?.name == "Alice the Second")
        let toCarol = lab[0].transport.written(.chat).filter { $0.envelope.recipientId == carol.nodeId.string }
        #expect(toCarol.isEmpty, "no session with Carol, so nothing sealed to her")
    }

    /// The sealed copy reaches a contact on its own: Alice's frames to Bob are held, and released with her cleartext profile
    /// left out, as a contact out of range meets only what a DM's custody carries. Bob's row takes the new name from the
    /// `CTL_PROFILE` alone.
    @Test func aContactTakesTheRenameFromTheSealedCopyAlone() throws {
        let lab = try pair()
        try acquainted(lab)
        lab.hold(from: 0, to: 1)
        lab[0].engine.updateProfile(name: "Alice the Second", status: "", openToChat: false)
        release(lab, from: 0, to: 1) { item in
            guard case .frame(let written) = item else {
                return false
            }
            return written.envelope.type == .profile
        }
        #expect(lab[1].stores.peers.peer(alice.nodeId)?.name == "Alice the Second", "from the sealed copy alone")
    }

    /// `aReServedOlderProfileNeverRevertsANewerName` (`ProfileUpdateLabTest.kt:111-128`): two renames held, released newest
    /// first, both writers' copies of each, and the stale ones land after the newer and revert nothing.
    @Test func aReServedOlderProfileNeverRevertsANewerName() throws {
        let lab = try pair()
        try acquainted(lab)
        lab.hold(from: 0, to: 1)
        lab[0].engine.updateProfile(name: "Alice Two", status: "", openToChat: false)
        lab.advance(1)
        lab[0].engine.updateProfile(name: "Alice Three", status: "", openToChat: false)
        lab.release(from: 0, to: 1) { $0.reversed() }
        #expect(lab[1].stores.peers.peer(alice.nodeId)?.name == "Alice Three")
    }

    /// `statusAndOpenToChatSurviveTheNextSealedUpdate` (`ProfileUpdateLabTest.kt:131-163`): every sealed update carries the
    /// whole presentation, so one that changes the name keeps the status and the open-to-chat flag the earlier ones set.
    /// Bob meets only the sealed copies here, the cleartext profiles left out.
    @Test func statusAndOpenToChatSurviveTheNextSealedUpdate() throws {
        let lab = try pair()
        try acquainted(lab)
        lab.hold(from: 0, to: 1)
        lab[0].engine.updateProfile(name: "Alice", status: "out walking", openToChat: false)
        lab.advance(1)
        lab[0].engine.updateProfile(name: "Alice", status: "out walking", openToChat: true)
        lab.advance(1)
        lab[0].engine.updateProfile(name: "Alice Outdoors", status: "out walking", openToChat: true)
        release(lab, from: 0, to: 1) { item in
            guard case .frame(let written) = item else {
                return false
            }
            return written.envelope.type == .profile
        }
        let row = try #require(lab[1].stores.peers.peer(alice.nodeId))
        #expect(row.name == "Alice Outdoors" && row.status == "out walking" && row.openToChat)
    }

    /// `anAvatarCrossesWithTheProfile` (`ProfileUpdateLabTest.kt:166-184`), the hash's half: a new photo's hash rides the
    /// cleartext profile and, beside the seal and inside it, the sealed copy, and Bob's row advertises it.
    @Test func anAvatarCrossesWithTheProfile() throws {
        let lab = try pair()
        try acquainted(lab)
        let jpeg = Array("a small face".utf8)
        lab[0].engine.setAvatar(jpeg)
        lab.carry()
        let hash = BlobHash(of: jpeg)
        #expect(lab[1].stores.peers.peer(alice.nodeId)?.advertisedAvatarHash == hash)
        let chats = EngineFixture.once(lab[0].transport.written(.chat))
        let beside = chats.compactMap { (try? ChatContent(decoding: $0.envelope.payload))?.attachmentHash }
        #expect(beside == [hash.string], "the sealed copy names it beside the seal, its one frame that does")
    }

    // MARK: What custody holds

    /// The blobs review's custody across three nodes: Alice (0) and Bob (2) apart, with Carol (1), a carrier without the
    /// switch, between them. Bob's first DM and Alice's answer acquaint them through Carol; then Alice's sealed reaction,
    /// its retraction and her edit's sealed copy cross Carol too. After a re-offer the three custodies hold the same ids,
    /// and each sealed frame of either side is held in each of them as its one seal: Carol, who reads none of them, carries
    /// every one, and no custody keeps a second seal of any.
    @Test func everyCustodyHoldsEachSealedFrameOnceACarrierWithoutTheSwitchAmongThem() throws {
        let lab = try line()
        _ = try #require(lab[2].engine.sendDirectMessage("hi alice", to: alice.nodeId))
        cross(lab)
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == true && lab[2].ratchetRecords(of: alice).session?.confirmed == true)
        let dm = try #require(lab[0].stores.messages.messages(in: bob.nodeId.string).first)
        _ = try #require(lab[0].engine.react(to: dm.id, with: "👍"))
        cross(lab)
        #expect(lab[2].stores.messages.reaction(on: dm.id, by: alice.nodeId)?.emoji == "👍", "through Carol")
        _ = try #require(lab[0].engine.react(to: dm.id, with: "👍"))
        cross(lab)
        #expect(lab[2].stores.messages.reaction(on: dm.id, by: alice.nodeId)?.emoji == nil, "and its retraction")
        lab[0].engine.updateProfile(name: "Alice the Second", status: "", openToChat: false)
        cross(lab)
        let names = [lab[2], lab[1]].map { $0.stores.peers.peer(alice.nodeId)?.name }
        #expect(names == ["Alice the Second", "Alice the Second"], "Bob's row, and Carol's from the cleartext profile")
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)

        let fromAlice = sealedIds(lab, from: 0, to: 2)
        #expect(fromAlice.count == 5, "her answer, her receipt, the reaction, its retraction and her edit's copy")
        lab.expectCustodyAgrees([0, 1, 2], sealedOnce: fromAlice, from: 0, to: 2)
        lab.expectCustodyAgrees([0, 1, 2], sealedOnce: sealedIds(lab, from: 2, to: 0), from: 2, to: 0)
    }

    /// A relaunch adds no row of ours to either custody, since the start seeds the fan-out's dedupe (phase P5e), a
    /// deliberate difference from Kotlin, whose first heal after a restart sends the version to every session once more.
    /// Alice and Bob hold a confirmed session and Alice's edit went sealed to Bob; Alice relaunches over the same stores
    /// and keychain, links again and lives to her first heal, and the rows of hers in her custody and in Bob's stand as
    /// they were.
    @Test func aRelaunchAddsNoRowOfOursToEitherCustody() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, stores: stores, keychain: keychain, seed: 11), try EngineFixture.ratcheting(bob, seed: 12),
        ])
        lab.link(0, 1)
        try acquainted(lab)
        lab[0].engine.updateProfile(name: "Alice the Second", status: "", openToChat: false)
        lab.advance(MeshConfiguration().healMilliseconds)
        let before = rows(of: 0, lab)
        #expect(before[0] == before[1] && !before[0].isEmpty)

        let wall = lab[0].clock.wallMilliseconds()
        lab.replace(0, with: try EngineFixture.ratcheting(alice, stores: stores, keychain: keychain, wall: wall, seed: 21))
        lab.link(0, 1)
        lab.advance(MeshConfiguration().healMilliseconds)
        #expect(rows(of: 0, lab) == before, "no row more of Alice's, in her custody or in Bob's")
    }

    /// A new session adds our answer to every custody and nothing at our next heal, since a sealed answer marks the
    /// fan-out's dedupe (phase P5e), a deliberate difference from Kotlin, whose heal sends the version the answer carried
    /// once more. Alice and Bob, both edited, meet: Bob's first DM carries his init, and Alice's custody and Bob's gain,
    /// of hers, her answer and her receipt for that DM, and nothing at her next heal. Bob's heal sends her his own version
    /// once, the copy she lacks.
    @Test func aNewSessionAddsOurAnswerAndNothingAtOurNextHeal() throws {
        let lab = try pair()
        lab[0].engine.updateProfile(name: "Alice", status: "here", openToChat: false)
        lab[1].engine.updateProfile(name: "Bob", status: "there", openToChat: false)
        lab.carry()
        let before = rows(of: 0, lab)
        _ = try #require(lab[1].engine.sendDirectMessage("hi alice", to: alice.nodeId))
        lab.carry()
        #expect(lab[0].ratchetRecords(of: bob).session?.confirmed == true && lab[1].ratchetRecords(of: alice).session?.confirmed == true)
        let answers = lab[0].answerIds
        let added = zip(rows(of: 0, lab), before).map { $0.subtracting($1) }
        let answered = added[0].filter { answers.contains(ExactKey($0)) }
        #expect(answers.count == 1 && answered.count == 1, "her answer, in her custody")
        #expect(added[0] == added[1] && added[0].count == 2, "and her receipt beside it, in both custodies")

        let settled = rows(of: 0, lab)
        let his = rows(of: 1, lab)
        lab.advance(MeshConfiguration().healMilliseconds)
        #expect(rows(of: 0, lab) == settled, "her next heal adds none")
        let sent = zip(rows(of: 1, lab), his).map { $0.subtracting($1) }
        #expect(sent[0].count == 1 && sent[0] == sent[1], "his heal sends her his version, once")
        let healed = [rows(of: 0, lab), rows(of: 1, lab)]
        lab.advance(MeshConfiguration().healMilliseconds)
        #expect([rows(of: 0, lab), rows(of: 1, lab)] == healed, "and the next heal sends nothing")
    }
}
