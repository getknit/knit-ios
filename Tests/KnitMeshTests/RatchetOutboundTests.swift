import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The DM ratchet's send rules above the engine (`sealEnvelopeFor`, `MeshManager.kt:1287-1308`, and `unackedDmsTo`,
/// `MessageDao.kt:179-187`, at knit-next `cbf2a487`): the switch first, then the pinned profile's bits and bundle, and the
/// content's compact form; and which of our DMs a peer's reset seals again (ADR 2026-10.5sk9, phase P5b). Phase P5e adds
/// where a reaction goes, the sealed profile's plaintext, and what an init's answer and a ratchetless pin read.
@Suite struct RatchetOutboundTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let content = MessageContent(body: "hi")

    /// Alice pinned with `capabilities`, and her prekey `prekey` when given.
    private func pinned(_ capabilities: Int64?, prekey: PrekeyInfo? = nil, key: String? = nil) -> PeerRecord {
        PeerRecord(
            nodeId: alice.nodeId,
            name: "Alice",
            status: "",
            publicKey: key ?? alice.keys.bundle.encoded,
            capabilities: capabilities,
            updatedAt: 1,
            prekey: prekey,
            prekeyProfileAt: prekey == nil ? 0 : 1
        )
    }

    @Test func withTheSwitchOffEveryPeerGetsV1WhateverItAdvertises() throws {
        let android = pinned(AndroidPeer.capabilities, prekey: try alice.prekey(id: 1))
        #expect(RatchetOutbound.scheme(for: content, to: android, ratchet: false) == .staticKeys(alice.keys.bundle))
    }

    @Test func aPeerWithNoBundleMakesADMWait() {
        #expect(RatchetOutbound.scheme(for: content, to: nil, ratchet: true) == .waiting)
        #expect(RatchetOutbound.scheme(for: content, to: pinned(0x15F, key: "not a bundle"), ratchet: true) == .waiting)
    }

    /// `aDmToAPeerWithoutTheCapabilityStaysV1` (`MeshManagerTest.kt:2072`): a pre-ratchet build's profile.
    @Test func aPeerWithoutTheRatchetsBitGetsV1() {
        #expect(RatchetOutbound.scheme(for: content, to: pinned(0xF), ratchet: true) == .staticKeys(alice.keys.bundle))
        #expect(RatchetOutbound.scheme(for: content, to: pinned(nil), ratchet: true) == .staticKeys(alice.keys.bundle))
    }

    /// A DM waits only for a bundle: the bit with no prekey still takes the ratchet here, and the facade's answer sends it
    /// v1 (`aCapableClaimWithoutAPrekeyFallsBackToV1AndCounts`, `MeshManagerTest.kt:2088`).
    @Test func theBitWithoutAPrekeyStillTakesTheRatchetWithNone() {
        guard case .ratchet(let plan) = RatchetOutbound.scheme(for: content, to: pinned(0x5F), ratchet: true) else {
            Issue.record("the bit takes the ratchet")
            return
        }
        #expect(plan.bundle == alice.keys.bundle && plan.prekey == nil)
    }

    @Test func aPinnedPrekeyIsVerifiedAgainstTheBundleAndOneThatFailsCountsAsNone() throws {
        let info = try alice.prekey(id: 3)
        guard case .ratchet(let plan) = RatchetOutbound.scheme(for: content, to: pinned(0x5F, prekey: info), ratchet: true) else {
            Issue.record("the bit takes the ratchet")
            return
        }
        #expect(plan.prekey == PeerPrekey(verifying: info, signedBy: alice.keys.bundle))
        let forged = PrekeyInfo(id: info.id, pub: info.pub, sig: Array(repeating: 7, count: 64))
        guard case .ratchet(let unsigned) = RatchetOutbound.scheme(for: content, to: pinned(0x5F, prekey: forged), ratchet: true) else {
            Issue.record("the bit takes the ratchet")
            return
        }
        #expect(unsigned.prekey == nil)
    }

    /// `aDmToARatchetCapablePeerSealsV2` and `aDmToACryptoV3PeerSealsV3` (`MeshManagerTest.kt:1970`, `:2001`): the named v2
    /// layout without `CAP_CRYPTO_V3`, the compact one with it.
    @Test func theCompactFormNeedsTheV3Bit() throws {
        let prekey = try alice.prekey(id: 1)
        guard case .ratchet(let v2) = RatchetOutbound.scheme(for: content, to: pinned(0x5F, prekey: prekey), ratchet: true),
            case .ratchet(let v3) = RatchetOutbound.scheme(for: content, to: pinned(0x15F, prekey: prekey), ratchet: true)
        else {
            Issue.record("both take the ratchet")
            return
        }
        #expect(!v2.v3 && v2.bytes.plaintext == content.encoded && v2.bytes.scheme == EncEnvelope.Version.ratchet)
        #expect(v3.v3 && v3.bytes.plaintext == MessageContentV2.encode(content))
    }

    /// The analog of `aTickAckingANonCanonicalIdToAV3AuthorFallsBackToV2` (`MeshManagerTest.kt:2056`) for a chat: content the
    /// compact codec cannot carry canonically, a reply naming an id that is not a frame id, goes v2 to a v3 peer.
    @Test func contentWithNoCompactFormGoesV2ToAV3Peer() throws {
        let reply = ReplyRef(
            messageId: "not-a-frame-id", authorId: alice.nodeId.string, author: "Alice", snippet: "hi", hasAttachment: false)
        let quoting = MessageContent(body: "yes", replyTo: reply)
        #expect(MessageContentV2.encode(quoting) == nil, "precondition: no compact form")
        guard
            case .ratchet(let plan) = RatchetOutbound.scheme(
                for: quoting, to: pinned(0x15F, prekey: try alice.prekey(id: 1)), ratchet: true)
        else {
            Issue.record("it takes the ratchet")
            return
        }
        #expect(!plan.v3 && plan.bytes.plaintext == quoting.encoded)
    }

    /// `unackedDmsTo` (`MessageDao.kt:179-187`): ours, to that peer, an ordinary message, never acknowledged, not waiting,
    /// and inside the day.
    @Test func theResealTakesOurUnacknowledgedDMsToThePeerFromTheLastDay() {
        let now: Int64 = 1_756_200_000_000
        let since = now - RatchetOutbound.resealMilliseconds
        func dm(
            from sender: TestPeer = me, to recipient: TestPeer? = nil, sentAt: Int64 = now, delivered: Bool = false, pending: Bool = false
        ) -> MessageRecord {
            MessageRecord(
                id: "m",
                senderId: sender.nodeId,
                recipientId: (recipient ?? alice).nodeId,
                conversationId: alice.nodeId.string,
                body: "hi",
                sentAt: sentAt,
                delivered: delivered,
                pendingKey: pending
            )
        }
        func takes(_ message: MessageRecord) -> Bool {
            RatchetOutbound.isUnacknowledged(message, to: alice.nodeId, from: me.nodeId, since: since)
        }
        #expect(takes(dm()))
        #expect(takes(dm(sentAt: since)), "the window's first millisecond is in it")
        #expect(!takes(dm(sentAt: since - 1)))
        #expect(!takes(dm(delivered: true)), "acknowledged")
        #expect(!takes(dm(pending: true)), "it goes by itself once a key pins")
        #expect(!takes(dm(from: alice, to: me)), "theirs")
        #expect(!takes(dm(to: TestPeer(seed: 3))), "to someone else")
        var notice = dm()
        notice.kind = .memberLeft
        #expect(!takes(notice), "a status line is no message")
    }

    @Test func theResealWindowIsAndroidsDay() {
        #expect(RatchetOutbound.resealMilliseconds == 24 * 60 * 60 * 1000)
    }

    // MARK: Receipts, ticks and inline acks (phase P5d)

    /// `canSealTickTo` and the gates of `sealDeliveryTickEnvelope` and `sealDmReceipt` (`MeshManager.kt:2066-2069`,
    /// `:1868-1870`; `InboundPipeline.kt:2904-2906`): the switch, `CAP_RATCHET`, and a bundle that decodes, and no prekey,
    /// which IntroSync's gate adds and this one does not.
    @Test func aReceiptOrTickSealsTowardTheRatchetsBitAndABundleAlone() throws {
        let prekey = try alice.prekey(id: 1)
        let plan = try #require(RatchetOutbound.receiptPlan(to: pinned(0x15F, prekey: prekey), ratchet: true))
        #expect(plan.bundle == alice.keys.bundle && plan.prekey == PeerPrekey(verifying: prekey, signedBy: alice.keys.bundle))
        #expect(plan.readsCryptoV3)
        #expect(RatchetOutbound.receiptPlan(to: pinned(0x5F), ratchet: true)?.prekey == nil, "no prekey still plans: a session seals")
        #expect(RatchetOutbound.receiptPlan(to: pinned(0x5F), ratchet: true)?.readsCryptoV3 == false)
        #expect(RatchetOutbound.receiptPlan(to: pinned(0x15F, prekey: prekey), ratchet: false) == nil, "the switch comes first")
        #expect(RatchetOutbound.receiptPlan(to: pinned(0xF), ratchet: true) == nil, "a pre-ratchet build")
        #expect(RatchetOutbound.receiptPlan(to: pinned(nil), ratchet: true) == nil)
        #expect(RatchetOutbound.receiptPlan(to: pinned(0x15F, key: "not a bundle"), ratchet: true) == nil)
        #expect(RatchetOutbound.receiptPlan(to: nil, ratchet: true) == nil, "nobody pinned")
    }

    /// `sealDeliveryTickEnvelope`'s plaintext (`MeshManager.kt:1880-1883`): one id in `ack`, a batch in `acks`; and
    /// `sealDmReceipt`'s (`InboundPipeline.kt:2925`): the DM's `ack`, its riders in `acks`, absent when none ride.
    @Test func aTickCarriesOneIdInAckAndABatchInAcks() {
        let one = RatchetOutbound.tick(acking: ["m1"])
        #expect(one == MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: "m1"))
        let batch = RatchetOutbound.tick(acking: ["m1", "m2"])
        #expect(batch == MessageContent(body: "", ctl: MessageContent.Control.receipt, acks: ["m1", "m2"]))
        let receipt = RatchetOutbound.dmReceipt(acking: "dm", riders: [])
        #expect(receipt == MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: "dm"))
        #expect(RatchetOutbound.dmReceipt(acking: "dm", riders: ["r1"]).acks == ["r1"])
    }

    /// `inlineAcksFor`'s room (`MeshManager.kt:2015-2017`, `LoraSizeHint.budget`): 320 bytes of body budget, less 260 for a
    /// quote and 170 for an attachment, less the body's UTF-8 bytes, at 23 bytes an ack, from none to four.
    @Test func inlineAcksFitKotlinsLoraBudgetForTheDM() {
        func room(_ body: String, replying: Bool = false, attached: Bool = false) -> Int {
            let message = MessageRecord(
                id: "m",
                senderId: me.nodeId,
                recipientId: alice.nodeId,
                conversationId: alice.nodeId.string,
                body: body,
                sentAt: 1,
                attachment: attached ? MessageAttachment(hash: BlobHash(of: [1]), mime: "image/jpeg") : nil,
                replyTo: replying ? MessageReply(messageId: "q", authorId: alice.nodeId.string, author: "Ann", snippet: "s") : nil
            )
            return RatchetOutbound.inlineAckRoom(for: message)
        }
        #expect(room("") == 4 && room("hi") == 4, "at most four")
        #expect(room(String(repeating: "a", count: 270)) == 2, "50 bytes left: two")
        #expect(room(String(repeating: "a", count: 320)) == 0 && room(String(repeating: "a", count: 400)) == 0, "none past the budget")
        #expect(room("é", replying: true) == 2, "60 bytes less a two-byte body: 58, two")
        #expect(room("", attached: true) == 4, "150 bytes with a photo")
        #expect(room("", replying: true, attached: true) == 0, "nothing left with both")
        #expect(room(String(repeating: "😀", count: 10), replying: true) == 0, "four bytes each: 40 of 60 gone")
    }

    /// The plaintext of a DM carrying acks (`content.copy(acks = ...)`, `MeshManager.kt:1295`): compact to a v3 reader, and
    /// named under v2 once an ack has no canonical compact form, rather than losing the tick.
    @Test func inlineAcksMoveTheDMToV2WhenTheCompactCodecCannotCarryThem() {
        var generator = SeededGenerator(seed: 1)
        let canonical = FrameId.generate(using: &generator)
        let compact = RatchetOutbound.sealBytes(of: content, carrying: [canonical], readsCryptoV3: true)
        #expect(compact.scheme == EncEnvelope.Version.compactRatchet && MessageContentV2.decode(compact.plaintext)?.acks == [canonical])
        let named = RatchetOutbound.sealBytes(of: content, carrying: ["not-a-frame-id"], readsCryptoV3: true)
        #expect(named.scheme == EncEnvelope.Version.ratchet && (try? MessageContent(decoding: named.plaintext))?.acks == ["not-a-frame-id"])
        #expect(RatchetOutbound.sealBytes(of: content, carrying: [], readsCryptoV3: true) == content.sealBytes(v3: true), "none: as it was")
    }

    /// `inlineAcksFor`'s gate is the pinned profile's `CAP_INLINE_ACK`, read with the rest of the scheme.
    @Test func theSchemeReadsTheInlineAckBit() throws {
        let prekey = try alice.prekey(id: 1)
        guard case .ratchet(let reads) = RatchetOutbound.scheme(for: content, to: pinned(0x15F, prekey: prekey), ratchet: true),
            case .ratchet(let deaf) = RatchetOutbound.scheme(for: content, to: pinned(0x15F & ~0x40, prekey: prekey), ratchet: true)
        else {
            Issue.record("both take the ratchet")
            return
        }
        #expect(reads.readsInlineAcks && reads.readsCryptoV3)
        #expect(!deaf.readsInlineAcks && deaf.readsCryptoV3)
    }

    // MARK: Phase P5e

    /// IntroSync's `canSeal` (`MeshManager.kt:345`): a receipt's gate and a verified prekey beside it, so a peer that claims
    /// the bits with no prekey, or a bad one, cannot be answered yet, and with the switch off nobody can.
    @Test func anInitsAnswerNeedsTheBitsABundleAndAVerifiedPrekey() throws {
        let prekey = try alice.prekey(id: 1)
        #expect(RatchetOutbound.answerPlan(to: pinned(0x15F, prekey: prekey), ratchet: true)?.prekey?.id == 1)
        #expect(RatchetOutbound.answerPlan(to: pinned(0x15F), ratchet: true) == nil, "no prekey pinned")
        #expect(RatchetOutbound.receiptPlan(to: pinned(0x15F), ratchet: true) != nil, "where a receipt still seals")
        let forged = PrekeyInfo(id: 1, pub: prekey.pub, sig: [UInt8](repeating: 1, count: 64))
        #expect(RatchetOutbound.answerPlan(to: pinned(0x15F, prekey: forged), ratchet: true) == nil, "a prekey that will not verify")
        #expect(RatchetOutbound.answerPlan(to: pinned(0xF, prekey: prekey), ratchet: true) == nil, "no bit")
        #expect(RatchetOutbound.answerPlan(to: pinned(0x15F, prekey: prekey), ratchet: false) == nil, "the switch off")
    }

    /// `ratchetless` (`MeshManager.kt:348-355`): a row a profile wrote, which names a protocol version or capabilities, and
    /// lacks the bit. A row with neither is not judged.
    @Test func aRatchetlessRowIsOneAProfileWroteWithoutTheBit() {
        #expect(RatchetOutbound.isRatchetless(pinned(0xF)))
        #expect(!RatchetOutbound.isRatchetless(pinned(0x15F)))
        #expect(!RatchetOutbound.isRatchetless(pinned(nil)), "neither a version nor the bits: not judged")
        var versioned = pinned(nil)
        versioned.protocolVersion = WireProtocol.version
        #expect(RatchetOutbound.isRatchetless(versioned), "a version and no bits")
    }

    /// `sealReaction`'s three targets (`MeshManager.kt:2219-2224`): the DM's other party, a group, and the room, read from
    /// the thread the message names.
    @Test func aReactionGoesByTheThreadOfTheMessageItNames() {
        #expect(RatchetOutbound.reactionTarget(in: alice.nodeId.string, me: me.nodeId) == .direct(alice.nodeId))
        #expect(RatchetOutbound.reactionTarget(in: "g-0fcb434512afea55af84f0a5", me: me.nodeId) == .group)
        #expect(RatchetOutbound.reactionTarget(in: Conversations.nearby, me: me.nodeId) == .room)
        #expect(RatchetOutbound.reactionTarget(in: me.nodeId.string, me: me.nodeId) == .room, "no DM of ours names us")
    }

    /// A sealed reaction's plaintext (`MessageContent(body = "", ctl = CTL_REACTION, rp = ...)`, `MeshManager.kt:2219`): a
    /// canonical message id lays it out compactly, and a retraction carries no emoji.
    @Test func aSealedReactionNamesTheMessageAndTheEmoji() throws {
        var generator = SeededGenerator(seed: 3)
        let id = FrameId.generate(using: &generator)
        let reaction = RatchetOutbound.reaction(on: id, emoji: "👍")
        #expect(reaction.ctl == MessageContent.Control.reaction && reaction.body.isEmpty)
        let compact = reaction.sealBytes(v3: true)
        #expect(compact.scheme == EncEnvelope.Version.compactRatchet)
        let decoded = try #require(MessageContentV2.decode(compact.plaintext))
        #expect(decoded.rp == ReactionContent(messageId: id, emoji: "👍"))
        #expect(RatchetOutbound.reaction(on: id, emoji: nil).rp == ReactionContent(messageId: id, emoji: nil), "a retraction")
        #expect(RatchetOutbound.reaction(on: "not-a-frame-id", emoji: "👍").sealBytes(v3: true).scheme == EncEnvelope.Version.ratchet)
    }

    /// `currentProfilePayload` (`MeshManager.kt:2856-2875`): the presentation as the cleartext profile presents it, on one
    /// line and within its limits, at our profile's version, with no key and no prekey.
    @Test func ourSealedProfilePresentsWhatTheCleartextOneDoes() throws {
        var own = OwnProfile()
        own.name = "  Dana \n  Lee  " + String(repeating: "x", count: 40)
        own.status = "out\twalking"
        own.avatarHash = BlobHash(of: [1, 2, 3])
        own.version = 42
        own.openToChat = true
        let sealed = RatchetOutbound.profile(of: own)
        #expect(sealed.ctl == MessageContent.Control.profile && sealed.body.isEmpty)
        let payload = try #require(sealed.pr)
        let name = TextLimits.truncated(TextLimits.normalizeSingleLine(own.name), toUTF16: TextLimits.displayName)
        #expect(payload.name == name && payload.name.utf16.count <= TextLimits.displayName)
        #expect(payload.status == TextLimits.normalizeSingleLine(own.status))
        #expect(payload.avatarHash == own.avatarHash?.string && payload.version == 42 && payload.openToChat)
        #expect(payload.loraNode == nil && payload.loraKey == nil, "no board is ever bound here")
    }
}
