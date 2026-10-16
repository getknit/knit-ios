import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The DM ratchet's send rules above the engine (`sealEnvelopeFor`, `MeshManager.kt:1287-1308`, and `unackedDmsTo`,
/// `MessageDao.kt:179-187`, at knit-next `cbf2a487`): the switch first, then the pinned profile's bits and bundle, and the
/// content's compact form; and which of our DMs a peer's reset seals again (ADR 2026-10.5sk9, phase P5b).
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
}
