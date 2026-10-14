import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// "@" mentions both ways (ADR 2026-10.nbhj): a room post's in the clear, a DM's and a group message's sealed inside,
/// as `MeshManager.sendChat` writes them (`MeshManager.kt:1084-1106`) and `InboundPipeline.deliverChat` keeps them
/// (`InboundPipeline.kt:2660`). Here, on either side, only the mentions whose token the kept body holds are stored.
@Suite struct MeshEngineMentionTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start

    private var sam: MessageMention { MessageMention(nodeId: carol.nodeId.string, name: "Sam") }
    private var me: MessageMention { MessageMention(nodeId: alice.nodeId.string, name: "Ann (blue fox)") }
    private var samOnAir: Mention { Mention(nodeId: carol.nodeId.string, name: "Sam") }
    private var meOnAir: Mention { Mention(nodeId: alice.nodeId.string, name: "Ann (blue fox)") }

    /// A body that names both, and a mention list Android's composer could send with it.
    private let body = "@Sam and @Ann (blue fox), lunch?"

    /// Mentions that fail ``MessageMention/carried(_:in:)``: one whose token isn't in ``body``, one with no name, and an
    /// exact repeat of ``sam``.
    private var stray: [MessageMention] {
        [MessageMention(nodeId: bob.nodeId.string, name: "Bo"), MessageMention(nodeId: bob.nodeId.string, name: ""), sam]
    }

    private var strayOnAir: [Mention] { stray.map { Mention(nodeId: $0.nodeId, name: $0.name) } }

    /// A body cut short by the 2000-unit limit, with "@Sam" past the cut.
    private let cutShort = String(repeating: "a", count: 1997) + " @Sam"

    private func fixture() throws -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// The mentions `written` carries in its sealed content, as `reader` opens it.
    private func sealedMentions(_ written: Written, as reader: TestPeer) throws -> [Mention] {
        let envelope = written.envelope
        let enc = try #require(try ChatContent(decoding: envelope.payload).enc)
        let thread = envelope.group?.id ?? envelope.recipientId ?? ""
        let header = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: thread)
        return try #require(MessageCrypto.open(enc, header: header, as: reader.keys)).mentions
    }

    /// The shell beside a seal: no words and no mentions in the clear (`Wire.kt:171-193`).
    private func expectBareShell(_ written: Written) throws {
        let shell = try ChatContent(decoding: written.envelope.payload)
        #expect(shell.enc != nil && shell.body.isEmpty && shell.mentions.isEmpty)
    }

    // MARK: Taking them

    @Test func androidsRoomMentionsAreStored() throws {
        let fixture = try fixture()
        let post = try bob.roomPost("", id: "r1", sentAt: start, content: ChatContent(body: body, mentions: [samOnAir, meOnAir]))
        fixture.deliver(post, from: bob)
        #expect(fixture.stores.messages.message("r1")?.mentions == [sam, me])
        let heard = announced(fixture.engine.drainEvents()).map(\.record)
        #expect(heard.map(\.mentions) == [[sam, me]])
        #expect(heard.first?.mentions.mentions(alice.nodeId) == true)
    }

    @Test func androidsDMMentionsAreStoredFromInsideTheSeal() throws {
        let fixture = try fixture()
        let content = MessageContent(body: body, mentions: [meOnAir])
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-1", sentAt: start, content: content), from: bob)
        #expect(fixture.stores.messages.message("dm-1")?.mentions == [me])
    }

    @Test func androidsGroupMentionsAreStoredFromInsideTheSeal() throws {
        let fixture = try fixture()
        let info = roster([bob, carol, alice], createdBy: bob)
        let content = MessageContent(body: body, mentions: [samOnAir, meOnAir])
        fixture.deliver(try bob.groupMessage("", in: info, to: [alice, carol], id: "gm-1", sentAt: start, content: content), from: bob)
        #expect(fixture.stores.messages.message("gm-1")?.mentions == [sam, me])
    }

    /// `plaintextContent` takes the opened content's mentions, or none: a list in the clear beside `enc` is no part of a
    /// sealed message (`InboundPipeline.kt:948-960`), so it can neither add a mention nor alert us.
    @Test func mentionsInTheClearBesideASealAreIgnored() throws {
        let fixture = try fixture()
        let header = MessageCrypto.header(id: "dm-2", senderId: bob.nodeId.string, sentAt: start, thread: alice.nodeId.string)
        let sealed = try #require(
            try MessageCrypto.seal(MessageContent(body: body).encoded, header: header, to: [alice.nodeId: alice.keys.bundle]))
        let envelope = RelayEnvelope(
            type: .chat,
            id: "dm-2",
            senderId: bob.nodeId.string,
            sentAt: start,
            recipientId: alice.nodeId.string,
            payload: ChatContent(body: body, mentions: [meOnAir], enc: sealed).encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        let stored = try #require(fixture.stores.messages.message("dm-2"))
        #expect(stored.body == body && stored.mentions.isEmpty)
    }

    @Test func aPeersStrayMentionsAreDropped() throws {
        let fixture = try fixture()
        let room = ChatContent(body: body, mentions: [samOnAir] + strayOnAir)
        fixture.deliver(try bob.roomPost("", id: "r2", sentAt: start, content: room), from: bob)
        #expect(fixture.stores.messages.message("r2")?.mentions == [sam])
        let dm = MessageContent(body: body, mentions: [samOnAir] + strayOnAir)
        fixture.deliver(try bob.directMessage("", to: alice, id: "dm-3", sentAt: start, content: dm), from: bob)
        #expect(fixture.stores.messages.message("dm-3")?.mentions == [sam])
    }

    /// Android keeps a stale pick while the text holds its token (`ChatScreen.kt:530`): "@Ann" lives on inside
    /// "@Annabel" after its own chip went. Both are kept, in either order, in every thread.
    @Test func androidsStalePickInsideALongerNameIsKeptInEveryThread() throws {
        let fixture = try fixture()
        let info = roster([bob, carol, alice], createdBy: bob)
        let ann = MessageMention(nodeId: alice.nodeId.string, name: "Ann")
        let annabel = MessageMention(nodeId: carol.nodeId.string, name: "Annabel")
        for (order, mentions) in [("a", [ann, annabel]), ("b", [annabel, ann])] {
            let onAir = mentions.map { Mention(nodeId: $0.nodeId, name: $0.name) }
            let text = "@Annabel hi"
            let room = ChatContent(body: text, mentions: onAir)
            fixture.deliver(try bob.roomPost("", id: "r-\(order)", sentAt: start, content: room), from: bob)
            let sealed = MessageContent(body: text, mentions: onAir)
            fixture.deliver(try bob.directMessage("", to: alice, id: "dm-\(order)", sentAt: start, content: sealed), from: bob)
            let group = try bob.groupMessage("", in: info, to: [alice, carol], id: "gm-\(order)", sentAt: start, content: sealed)
            fixture.deliver(group, from: bob)
            for id in ["r-\(order)", "dm-\(order)", "gm-\(order)"] {
                let stored = try #require(fixture.stores.messages.message(id))
                #expect(stored.mentions == mentions && stored.mentions.mentions(alice.nodeId), "\(id)")
            }
        }
    }

    /// The body is kept to 2000 units, and a mention whose token falls past the cut goes with it.
    @Test func aMentionTheTruncationCutsIsDropped() throws {
        let fixture = try fixture()
        let room = ChatContent(body: cutShort, mentions: [samOnAir])
        fixture.deliver(try bob.roomPost("", id: "r3", sentAt: start, content: room), from: bob)
        let stored = try #require(fixture.stores.messages.message("r3"))
        #expect(stored.body.utf16.count == TextLimits.message && stored.mentions.isEmpty)
    }

    /// The first copy's mentions stand: a later frame under the same id, past the `SeenSet`'s ten minutes, with another
    /// list, leaves the row as it was (`saveIfAbsent`).
    @Test func aReservedFrameLeavesTheStoredMentions() throws {
        let fixture = try fixture()
        let first = try bob.roomPost("", id: "r4", sentAt: start, content: ChatContent(body: body, mentions: [samOnAir]))
        fixture.deliver(first, from: bob)
        fixture.advance(11 * 60_000)
        fixture.deliver(first, from: bob)
        let other = try bob.roomPost("", id: "r4", sentAt: start, content: ChatContent(body: body, mentions: [meOnAir]))
        fixture.deliver(other, from: bob)
        #expect(fixture.stores.messages.message("r4")?.mentions == [sam])
        #expect(announced(fixture.engine.drainEvents()).count == 1)
    }

    // MARK: Sending them

    @Test func ourRoomMentionsGoInTheClear() throws {
        let fixture = try fixture()
        let record = try #require(fixture.engine.postToRoom(body, mentions: [sam, me]))
        #expect(record.mentions == [sam, me])
        #expect(fixture.stores.messages.message(record.id)?.mentions == [sam, me])
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(try ChatContent(decoding: sent.envelope.payload).mentions == [samOnAir, meOnAir])
    }

    @Test func ourDMMentionsGoSealedAndNeverInTheShell() throws {
        let fixture = try fixture()
        let mentionBob = MessageMention(nodeId: bob.nodeId.string, name: "Bo")
        let record = try #require(fixture.engine.sendDirectMessage("@Bo and @Sam", to: bob.nodeId, mentions: [mentionBob, sam]))
        #expect(record.mentions == [mentionBob, sam])
        let sent = try #require(fixture.transport.written(.chat).first)
        try expectBareShell(sent)
        #expect(try sealedMentions(sent, as: bob) == [Mention(nodeId: bob.nodeId.string, name: "Bo"), samOnAir])
    }

    @Test func ourGroupMentionsGoSealedAndNeverInTheShell() throws {
        let fixture = try fixture()
        try fixture.pin(carol)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendGroupMessage(body, to: group.id, mentions: [sam]))
        #expect(record.mentions == [sam])
        let sent = try #require(fixture.transport.written(.chat).first)
        try expectBareShell(sent)
        #expect(try sealedMentions(sent, as: bob) == [samOnAir])
        #expect(try sealedMentions(sent, as: carol) == [samOnAir])
    }

    /// The row keeps the mentions, so a DM that waited for its recipient's key is sealed with them
    /// (`MeshManager.resealAndFlood`).
    @Test func aDMWaitingForAKeyKeepsItsMentions() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let record = try #require(fixture.engine.sendDirectMessage(body, to: bob.nodeId, mentions: [sam]))
        #expect(record.pendingKey && record.mentions == [sam])
        fixture.transport.clear()
        try fixture.pin(bob)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.envelope.id == record.id)
        try expectBareShell(sent)
        #expect(try sealedMentions(sent, as: bob) == [samOnAir])
    }

    @Test func aGroupMessageWaitingForAKeyKeepsItsMentions() throws {
        let fixture = EngineFixture(alice)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        let record = try #require(fixture.engine.sendGroupMessage(body, to: group.id, mentions: [sam, me]))
        #expect(record.pendingKey && record.mentions == [sam, me])
        try fixture.pin(bob)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(sent.envelope.id == record.id)
        try expectBareShell(sent)
        #expect(try sealedMentions(sent, as: bob) == [samOnAir, meOnAir])
    }

    @Test func ourStrayMentionsAreDroppedInEveryThread() throws {
        let fixture = try fixture()
        try fixture.pin(carol)
        let room = try #require(fixture.engine.postToRoom(body, mentions: [sam] + stray))
        #expect(room.mentions == [sam])
        #expect(try ChatContent(decoding: try #require(fixture.transport.written(.chat).last).envelope.payload).mentions == [samOnAir])
        let dm = try #require(fixture.engine.sendDirectMessage(body, to: bob.nodeId, mentions: [sam] + stray))
        #expect(dm.mentions == [sam])
        #expect(try sealedMentions(try #require(fixture.transport.written(.chat).last), as: bob) == [samOnAir])
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        let posted = try #require(fixture.engine.sendGroupMessage(body, to: group.id, mentions: [sam] + stray))
        #expect(posted.mentions == [sam])
        #expect(try sealedMentions(try #require(fixture.transport.written(.chat).last), as: carol) == [samOnAir])
    }

    /// The body we send is cut to 2000 units before the mentions are matched against it.
    @Test func ourMentionTheTruncationCutsIsDropped() throws {
        let fixture = try fixture()
        let room = try #require(fixture.engine.postToRoom(cutShort, mentions: [sam]))
        #expect(room.body.utf16.count == TextLimits.message && room.mentions.isEmpty)
        #expect(try ChatContent(decoding: try #require(fixture.transport.written(.chat).last).envelope.payload).mentions.isEmpty)
        let dm = try #require(fixture.engine.sendDirectMessage(cutShort, to: bob.nodeId, mentions: [sam]))
        #expect(dm.mentions.isEmpty)
        #expect(try sealedMentions(try #require(fixture.transport.written(.chat).last), as: bob).isEmpty)
    }

    // MARK: Two engines

    /// Our DM and group message as another engine of ours takes them: the mentions survive the seal and the open, and
    /// the recipient finds itself among them by its node id.
    @Test func anotherEngineTakesOurSealedMentions() throws {
        let sender = try fixture()
        try sender.pin(carol)
        let receiver = EngineFixture(bob)
        receiver.link(alice)
        try receiver.pin(alice)
        try receiver.pin(carol)
        _ = receiver.engine.drainEvents()
        let mentionBob = MessageMention(nodeId: bob.nodeId.string, name: "Bo")
        let dm = try #require(sender.engine.sendDirectMessage("@Bo hi", to: bob.nodeId, mentions: [mentionBob]))
        let group = try #require(sender.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        let gm = try #require(sender.engine.sendGroupMessage("@Bo and @Sam", to: group.id, mentions: [mentionBob, sam]))
        for written in sender.transport.written(.chat) {
            receiver.engine.receive(InboundFrame(wire: written.wire, envelope: written.envelope, from: alice.nodeId))
        }
        let takenDM = try #require(receiver.stores.messages.message(dm.id))
        #expect(takenDM.mentions == [mentionBob] && takenDM.mentions.mentions(bob.nodeId))
        let takenGM = try #require(receiver.stores.messages.message(gm.id))
        #expect(takenGM.mentions == [mentionBob, sam] && takenGM.mentions.mentions(bob.nodeId))
    }

    /// A DM sent before its recipient's key pinned is sealed at the flush, and the recipient's engine opens it with its
    /// mentions whole and finds itself among them.
    @Test func anotherEngineTakesOurFlushedMentions() throws {
        let sender = EngineFixture(alice)
        sender.link(bob)
        let receiver = EngineFixture(bob)
        receiver.link(alice)
        try receiver.pin(alice)
        _ = receiver.engine.drainEvents()
        let mentionBob = MessageMention(nodeId: bob.nodeId.string, name: "Bo")
        let dm = try #require(sender.engine.sendDirectMessage("@Bo later", to: bob.nodeId, mentions: [mentionBob]))
        #expect(dm.pendingKey && sender.transport.written(.chat).isEmpty)
        try sender.pin(bob)
        for written in sender.transport.written(.chat) {
            receiver.engine.receive(InboundFrame(wire: written.wire, envelope: written.envelope, from: alice.nodeId))
        }
        let taken = try #require(receiver.stores.messages.message(dm.id))
        #expect(taken.mentions == [mentionBob] && taken.mentions.mentions(bob.nodeId))
    }
}
