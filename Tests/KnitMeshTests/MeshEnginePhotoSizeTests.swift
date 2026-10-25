import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A large photo of ours declares its plaintext length, so an Android receiver's "Ask before large Bluetooth downloads" can
/// hold it for a tap (knit-ios #7, knit-next ADRs 2026-10.js2p and 2026-10.hmfe): in the clear in a room post, sealed in a
/// DM or a group message, never on a sealed frame's shell, and kept on the row so a later seal declares it too. Below
/// ``BluetoothFetchGate/declareSizeFloor`` nothing is declared, and the frame is what it was (`MeshManager.kt:1452-1491` and
/// `:1531-1552` at `eac3debc`).
@Suite struct MeshEnginePhotoSizeTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private static let floor = Int(BluetoothFetchGate.declareSizeFloor)
    private let large = OutgoingPhoto(bytes: [UInt8](repeating: 7, count: floor), mime: "image/jpeg")
    private let small = OutgoingPhoto(bytes: [UInt8](repeating: 7, count: floor - 1), mime: "image/jpeg")

    /// The keys of `bytes`' top-level map, in wire order: text for a named layout, numbers for the compact one.
    private func keys(_ bytes: [UInt8]) throws -> [CBOR] {
        guard case .map(let entries) = try CBOR.decode(bytes) else {
            Issue.record("not a map")
            return []
        }
        return entries.map(\.key)
    }

    /// The sealed content of a DM `written` carried, as `reader` opens it.
    private func openedDirect(_ written: Written, as reader: TestPeer) throws -> MessageContent? {
        let envelope = written.envelope
        let enc = try #require(try ChatContent(decoding: envelope.payload).enc)
        let header = MessageCrypto.header(
            id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: try #require(envelope.recipientId))
        return MessageCrypto.open(enc, header: header, as: reader.keys)
    }

    private func shell(_ written: Written) throws -> ChatContent {
        try ChatContent(decoding: written.envelope.payload)
    }

    // MARK: The room

    @Test func aLargeRoomPhotoDeclaresItsSizeOnTheFrameAndTheRow() throws {
        let fixture = EngineFixture(alice)
        let record = try #require(fixture.engine.postToRoom("big", photo: large))
        #expect(record.attachment?.size == 1_000_000)
        #expect(fixture.stores.messages.message(record.id)?.attachment?.size == 1_000_000, "the row agrees with the frame")
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(try shell(sent).attachmentSize == 1_000_000)
    }

    @Test func aRoomPhotoUnderTheFloorIsTheFrameItWas() throws {
        let fixture = EngineFixture(alice)
        let record = try #require(fixture.engine.postToRoom("small", photo: small))
        #expect(record.attachment?.size == nil)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(try !keys(sent.envelope.payload).contains(.text("attachmentSize")))
        let before = ChatContent(body: "small", attachmentHash: BlobHash(of: small.bytes).string, attachmentMime: "image/jpeg")
        #expect(sent.envelope.payload == before.encoded, "byte for byte the post without the field")
    }

    // MARK: A DM

    @Test func aLargeDMPhotoDeclaresItsSizeSealedAndNeverOnTheShell() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let record = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: large))
        #expect(record.attachment?.size == 1_000_000)
        let sent = try #require(fixture.transport.written(.chat).first)
        #expect(try openedDirect(sent, as: bob)?.attachmentSize == 1_000_000)
        #expect(try shell(sent).attachmentSize == nil, "the shell never carries it (knit-next ADR 2026-10.hmfe, section 4)")

        let under = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: small))
        let underSent = try #require(fixture.transport.written(.chat).first { $0.envelope.id == under.id })
        #expect(under.attachment?.size == nil)
        #expect(try openedDirect(underSent, as: bob)?.attachmentSize == nil)
    }

    /// With the switch on, a v3 DM's compact content carries the size at label 15, and under the floor has no label 15.
    @Test func aRatchetDMCarriesTheSizeAtLabelFifteen() throws {
        let pair = [TestPeer(seed: 1), TestPeer(seed: 2)].sorted { $0.nodeId < $1.nodeId }
        let me = pair[0]
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(pair[1])
        try fixture.pin(android)
        let big = try #require(fixture.engine.sendDirectMessage("", to: pair[1].nodeId, photo: large))
        let little = try #require(fixture.engine.sendDirectMessage("", to: pair[1].nodeId, photo: small))
        let now = fixture.clock.wallMilliseconds()
        func compact(_ id: String) throws -> [UInt8] {
            let written = try #require(fixture.transport.written(.chat).first { $0.envelope.id == id })
            #expect(try EngineFixture.sealed(written).version == EncEnvelope.Version.compactRatchet, "v3")
            return try #require(plaintext(try android.open(written, from: me, now: now)))
        }
        let bigBytes = try compact(big.id)
        #expect(try keys(bigBytes).contains(.unsigned(15)))
        #expect(MessageContentV2.decode(bigBytes)?.attachmentSize == 1_000_000)
        let littleBytes = try compact(little.id)
        #expect(try !keys(littleBytes).contains(.unsigned(15)))
        #expect(MessageContentV2.decode(littleBytes)?.attachmentHash == little.attachment?.hash.string)
    }

    // MARK: A group

    @Test func aLargeGroupPhotoDeclaresItsSizeToEveryMember() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let group = try #require(fixture.engine.createGroup(with: [bob.nodeId, carol.nodeId]))
        fixture.transport.clear()
        let record = try #require(fixture.engine.sendGroupMessage("", to: group.id, photo: large))
        let sent = try #require(fixture.transport.written(.chat).first { $0.envelope.id == record.id })
        for member in [bob, carol] {
            #expect(try opened(sent, as: member)?.attachmentSize == 1_000_000)
        }
        #expect(try shell(sent).attachmentSize == nil)
    }

    /// The group form with the switch on is its own ``MeshEngine/content(of:)`` call (`sendGroupRatchet`): the opened
    /// plaintext declares a large photo's size, and a small one's has no key.
    @Test func theRatchetGroupFormDeclaresTheSizeToo() throws {
        let fixture = try EngineFixture.ratcheting(alice)
        let reader = GroupFormReader(try AndroidPeer(bob))
        try fixture.pin(reader.android)
        let group = fixture.holdGroup(with: [bob])
        let big = try #require(fixture.engine.sendGroupMessage("", to: group.id, photo: large))
        try reader.receive(try #require(fixture.chats(to: bob).first), from: alice)
        let little = try #require(fixture.engine.sendGroupMessage("", to: group.id, photo: small))
        let frames = fixture.groupFrames(in: group.id)
        #expect(frames.map(\.envelope.id) == [big.id, little.id])
        let opened = try frames.map { try groupPlaintext($0, by: reader) }
        #expect(try MessageContent(decoding: opened[0]).attachmentSize == 1_000_000)
        #expect(try !keys(opened[1]).contains(.text("attachmentSize")))
        #expect(try MessageContent(decoding: opened[1]).attachmentHash == little.attachment?.hash.string)
    }

    /// A group-form frame's plaintext, opened and committed by `reader`.
    private func groupPlaintext(_ frame: Written, by reader: GroupFormReader) throws -> [UInt8] {
        let envelope = frame.envelope
        let group = try #require(envelope.group?.id)
        #expect(try EngineFixture.sealed(frame).groupRatchet != nil, "the group form")
        let aad = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: group)
        let opening = try #require(GroupRatchetSessions.Frame(envelope: try EngineFixture.sealed(frame), aad: aad))
        let opened = reader.sessions.open(opening, in: group, from: alice.nodeId, now: envelope.sentAt) { _ in () }
        guard case .settled(.opened(let bytes, _)) = opened else {
            Issue.record("\(envelope.id) did not open: \(opened)")
            throw AndroidPeer.Refused()
        }
        return bytes
    }

    // MARK: Sealed later, from the row

    /// A DM and a group message that waited for a key are sealed from their rows, and declare the size those rows kept,
    /// on either store (`resealAndFlood` through `row.sealedContent()`).
    @Test(arguments: StoreKind.allCases)
    func aMessageSealedOnceAKeyPinsKeepsTheSizeFromItsRow(kind: StoreKind) throws {
        let directory = scratchDirectory("photo-size-pending")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(alice, stores: stores)
        let direct = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: large))
        let group = try #require(fixture.engine.createGroup(with: [carol.nodeId]))
        let grouped = try #require(fixture.engine.sendGroupMessage("", to: group.id, photo: large))
        #expect(direct.pendingKey && grouped.pendingKey)
        #expect(fixture.stores.messages.message(direct.id)?.attachment?.size == 1_000_000, "kept on the row")
        #expect(fixture.stores.messages.message(grouped.id)?.attachment?.size == 1_000_000, "kept on the row")

        try fixture.pin(bob)
        try fixture.pin(carol)
        let sentDirect = try #require(fixture.transport.written(.chat).first { $0.envelope.id == direct.id })
        let sentGroup = try #require(fixture.transport.written(.chat).first { $0.envelope.id == grouped.id })
        #expect(try openedDirect(sentDirect, as: bob)?.attachmentSize == 1_000_000)
        #expect(try opened(sentGroup, as: carol)?.attachmentSize == 1_000_000)
        #expect(try shell(sentDirect).attachmentSize == nil)
        #expect(try shell(sentGroup).attachmentSize == nil)
    }

    // MARK: A held picture

    /// A picture this phone already holds goes under that identity, sealing nothing (ADR 2026-10.f3mv), and declares its
    /// size from the plaintext ``MeshEngine/heldPhoto(picked:)`` hands back.
    @Test func aHeldPictureDeclaresItsSize() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let first = try #require(fixture.engine.sendDirectMessage("", to: bob.nodeId, photo: large)?.attachment)
        let found = try #require(fixture.engine.heldPhoto(picked: large.bytes))
        #expect(found.identity == PhotoIdentity(hash: first.hash, key: first.key) && found.declaredSize == 1_000_000)
        let forward = try #require(fixture.engine.sendDirectMessage("", to: carol.nodeId, photo: found))
        #expect(forward.attachment?.hash == first.hash && forward.attachment?.size == 1_000_000, "nothing sealed again")
        let sent = try #require(fixture.transport.written(.chat).first { $0.envelope.id == forward.id })
        #expect(try openedDirect(sent, as: carol)?.attachmentSize == 1_000_000)

        let posted = try #require(fixture.engine.postToRoom("", photo: found))
        #expect(posted.attachment?.hash == BlobHash(of: large.bytes) && posted.attachment?.size == 1_000_000, "the room's too")
    }

    // MARK: A size past Long

    /// A size past `Int64.max` wraps as kotlinx-cbor wraps it, so a frame Android's `canCarry` keeps is carried here too, a
    /// room post and a DM's shell alike (`InboundPipeline.kt:2311-2320` at `eac3debc`). Refused here alone, it would sit in
    /// every Android custody and never in ours, and our digests would never agree.
    @Test func aFrameDeclaringASizePastLongIsCarriedAsOnAndroid() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        try fixture.pin(carol)
        let past = CBOR.Entry(key: .text("attachmentSize"), value: .unsigned(UInt64(Int64.max) + 1))
        let post = RelayEnvelope(
            type: .chat,
            id: frameIdOf("post"),
            senderId: bob.nodeId.string,
            sentAt: EngineFixture.start,
            payload: CBOR.map([CBOR.Entry(key: .text("body"), value: .text("big")), past]).encoded
        )
        fixture.deliver(try bob.signed(post), from: bob)
        var direct = try bob.directMessage("hi", to: carol, id: frameIdOf("dm"), sentAt: EngineFixture.start).envelope
        guard case .map(let shell) = try CBOR.decode(direct.payload) else {
            Issue.record("a shell is a map")
            return
        }
        direct.payload = CBOR.map(shell + [past]).encoded
        fixture.deliver(try bob.signed(direct), from: bob)
        let carried = fixture.stores.custody.liveFrames(now: EngineFixture.start).map(\.envelope.id)
        #expect(carried.contains(frameIdOf("post")) && carried.contains(frameIdOf("dm")))
    }
}
