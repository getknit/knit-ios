import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The headroom under custody's byte cap (knit-next #227): the largest frame of each kind this port authors, at its own
/// clamps, measured as custody counts it (`signed`, never `sig`), stays under ``CustodyLimits/maxSignedBytes``. The cap
/// binds our own frames too, so a kind that crossed it would stop being carried for us, though its send still went.
///
/// The clamps: a body of ``TextLimits/message`` UTF-16 units, each a three-byte character, the worst UTF-8 costs a unit; a
/// quote of ``MessageReply/snippetLimit`` units under a name of ``TextLimits/displayName``; a photo; a group of
/// ``GroupInfo/maxMembers``, every other member mentioned under the longest name; a sealed tick batch of
/// ``AckSync/maxBatchAcks`` ids; a profile at the name and status limits. A room post's mentions are bounded by the chips its
/// body holds (``MessageMention/carried(_:in:)``), so the room's worst is the shortest chip, `@a `, repeated to the clamp,
/// each naming someone else.
@Suite struct CustodyHeadroomTests {
    private let alice = TestPeer(seed: 1)
    private let cap = CustodyLimits().maxSignedBytes

    /// The worst UTF-8 cost of a UTF-16 unit: three bytes, one unit.
    private static let wide = "\u{20AC}"
    private static let longestName = String(repeating: wide, count: TextLimits.displayName)

    /// Alice's own frames that `act` put into her custody, the largest `signed` first.
    private func ownFramesAdded(by fixture: EngineFixture, _ act: () throws -> Void) rethrows -> [Int] {
        let now = { fixture.clock.wallMilliseconds() }
        let before = Set(fixture.stores.custody.liveIds(now: now()).map(ExactKey.init))
        try act()
        return fixture.stores.custody.liveFrames(now: now())
            .filter { !before.contains(ExactKey($0.envelope.id)) && $0.envelope.senderId == alice.nodeId.string }
            .map(\.signed.count)
            .sorted(by: >)
    }

    private func quote(of author: TestPeer) -> MessageReply {
        MessageReply(
            messageId: frameIdOf("parent"),
            authorId: author.nodeId.string,
            author: Self.longestName,
            snippet: String(repeating: Self.wide, count: MessageReply.snippetLimit),
            hasAttachment: true
        )
    }

    private var photo: OutgoingPhoto {
        OutgoingPhoto(bytes: [UInt8](repeating: 0xD8, count: 4096), mime: "image/jpeg")
    }

    /// `mentioned` as chips in a body filled to the clamp with three-byte characters, and the mentions themselves.
    private func body(mentioning mentioned: [NodeId]) -> (String, [MessageMention]) {
        let mentions = mentioned.map { MessageMention(nodeId: $0.string, name: Self.longestName) }
        let chips = mentions.map { "\($0.token) " }.joined()
        let filler = String(repeating: Self.wide, count: TextLimits.message - chips.utf16.count)
        return (chips + filler, mentions)
    }

    /// Alice with the ratchet's switch on and a profile at its limits, and seven Android members pinned with their prekeys.
    private func rig() throws -> (EngineFixture, [AndroidPeer]) {
        let own = OwnProfile(
            name: Self.longestName,
            status: String(repeating: Self.wide, count: TextLimits.status),
            openToChat: true,
            version: 9,
            publishedAt: EngineFixture.start - 1000,
            avatarHash: BlobHash(of: [1, 2, 3])
        )
        let fixture = try EngineFixture.ratcheting(alice, stores: .inMemory(ownProfile: own))
        let members = try (2...GroupInfo.maxMembers).map { try AndroidPeer(TestPeer(seed: $0)) }
        for member in members {
            try fixture.pin(member)
        }
        return (fixture, members)
    }

    @Test func everyKindWeAuthorStaysUnderTheByteCap() throws {
        let (fixture, members) = try rig()
        var sizes = try directAndGroup(fixture, members)
        sizes.merge(try ticksAndProfiles(fixture, members)) { first, _ in first }
        sizes.merge(try room(fixture, quoting: members[4].peer)) { first, _ in first }
        for (kind, size) in sizes.sorted(by: { $0.key < $1.key }) {
            #expect(size < cap, "\(kind): \(size) signed bytes")
        }
        #expect(sizes.count == 8, "every kind measured: \(sizes)")
    }

    /// The first DM of a session, which carries its init, and a group message to the most members, with its seed DMs.
    private func directAndGroup(_ fixture: EngineFixture, _ members: [AndroidPeer]) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        let first = members[0].peer
        let (dmBody, dmMentions) = body(mentioning: [first.nodeId])
        sizes["v2 DM, the session's init"] = try ownFramesAdded(by: fixture) {
            _ = try #require(
                fixture.engine.sendDirectMessage(dmBody, to: first.nodeId, photo: photo, replyTo: quote(of: first), mentions: dmMentions))
        }.first

        let group = try #require(fixture.engine.createGroup(with: members.map(\.peer.nodeId)))
        let (groupBody, groupMentions) = body(mentioning: members.map(\.peer.nodeId))
        let added = try ownFramesAdded(by: fixture) {
            _ = try #require(
                fixture.engine.sendGroupMessage(
                    groupBody, to: group.id, photo: photo, replyTo: quote(of: members[1].peer), mentions: groupMentions))
        }
        let groupFrames = fixture.stores.custody.liveFrames(now: fixture.clock.wallMilliseconds())
            .filter { $0.envelope.group != nil && $0.envelope.senderId == alice.nodeId.string }
            .map(\.signed.count)
        sizes["v2 group frame, 8 members"] = groupFrames.max()
        sizes["group seed DM"] = added.filter { !groupFrames.contains($0) }.max()
        return sizes
    }

    /// A sealed tick batch at its most ids, our sealed profile as an init's answer, and our cleartext profile.
    private func ticksAndProfiles(_ fixture: EngineFixture, _ members: [AndroidPeer]) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        let acks = (0..<AckSync.maxBatchAcks).map { index in
            var generator = SeededGenerator(seed: UInt64(1000 + index))
            return FrameId.generate(using: &generator)
        }
        sizes["sealed tick batch"] =
            ownFramesAdded(by: fixture) {
                #expect(RatchetTickSeals(engine: fixture.engine).originateTick(to: members[2].peer.nodeId, acks: acks))
            }.first

        let initiator = members[3]
        sizes["sealed profile, an init's answer"] = try ownFramesAdded(by: fixture) {
            let opening = try initiator.dm(
                "hello", to: alice, prekey: try fixture.ourPrekey(), id: frameIdOf("init-1"), sentAt: fixture.clock.wallMilliseconds())
            fixture.deliver(opening, from: initiator)
        }.first

        sizes["cleartext profile"] = fixture.stores.custody.liveFrames(now: fixture.clock.wallMilliseconds())
            .filter { $0.envelope.type == .profile && $0.envelope.senderId == alice.nodeId.string }
            .map(\.signed.count).max()
        return sizes
    }

    /// A room post at the widest body, and one with as many chips as the clamp holds, each `@a ` naming someone else: the
    /// room's pins are unbounded.
    private func room(_ fixture: EngineFixture, quoting author: TestPeer) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        let (roomBody, _) = body(mentioning: [])
        sizes["room post, widest body"] = try ownFramesAdded(by: fixture) {
            _ = try #require(fixture.engine.postToRoom(roomBody, photo: photo, replyTo: quote(of: author)))
        }.first

        let chips = TextLimits.message / 3
        let crowd = try (0..<chips).map { index in
            // Two bytes of the index, since `fixtureNodeId`'s seed wraps at 256.
            let id = try #require(
                NodeId(bytes: [UInt8(index >> 8), UInt8(index & 0xFF)] + [UInt8](repeating: 0x5A, count: NodeId.byteCount - 2)))
            return MessageMention(nodeId: id.string, name: "a")
        }
        sizes["room post, most mentions"] = try ownFramesAdded(by: fixture) {
            let posted = try #require(
                fixture.engine.postToRoom(String(repeating: "@a ", count: chips), photo: photo, replyTo: quote(of: author), mentions: crowd)
            )
            #expect(posted.mentions.count == chips)
        }.first
        return sizes
    }

    @Test func aV1SealedDMStaysUnderTheByteCap() throws {
        // With the switch off a DM is sealed v1, as every build before the ratchet sends one.
        let fixture = EngineFixture(alice)
        let bob = TestPeer(seed: 2)
        try fixture.pin(bob)
        let (dmBody, dmMentions) = body(mentioning: [bob.nodeId])
        let added = try ownFramesAdded(by: fixture) {
            _ = try #require(
                fixture.engine.sendDirectMessage(dmBody, to: bob.nodeId, photo: photo, replyTo: quote(of: bob), mentions: dmMentions))
        }
        let size = try #require(added.first)
        #expect(size < cap, "v1 DM: \(size) signed bytes")
    }
}
