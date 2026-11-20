import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The link's duplicate skip under paced answers (the `custody-carry-policy` contract, §9, revision 8): a frame addressed to
/// the peer is owed again once a digest can speak to its release (§2), and the link still lets it cross once in 10 minutes
/// while its crossings memo remembers it. Two engines in an ``EngineLab`` that models each link's ``LinkCrossings``.
@Suite struct EngineLabCustodyCrossingsTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let dave = TestPeer(seed: 4)

    @Test func aLostDMForThePeerCrossesOnceInTenMinutesThoughEveryDigestLacksIt() throws {
        let lab = EngineLab([EngineFixture(alice, seed: 11), EngineFixture(bob, seed: 12)], crossings: true)
        let wall = lab[0].clock.wallMilliseconds()
        let mail = try dave.directMessage("for bob", to: bob, id: frameIdOf("lost-mail"), sentAt: wall)
        lab[0].stores.custody.store(
            CarriedFrame(envelope: mail.envelope, sig: mail.wire.sig, signed: mail.wire.signed), origin: .relayed, now: wall)
        lab.link(0, 1)
        var crossed: [Int] = []
        var count = 0
        for second in 0..<1150 {
            // Lost on Bob's side, and every 60 s a digest of his that lacks it.
            lab[1].stores.custody.remove(mail.envelope.id)
            if second.isMultiple(of: 60) {
                let held = lab.liveIds(1).filter { ExactKey($0) != ExactKey(mail.envelope.id) }
                lab[0].engine.receiveDigest(held, from: bob.nodeId)
                lab.carry()
            }
            let now = lab.delivered(of: mail.envelope.id, from: 0, to: 1, since: 0)
            if now > count {
                crossed.append(second)
                count = now
            }
            lab.advance(1000)
        }
        let first = try #require(crossed.first, "the link-up answer served it")
        #expect(first == 0)
        #expect(crossed.count == 2, "once, then once more past the window: \(crossed)")
        #expect(crossed.last.map { $0 - first >= 600 && $0 - first < 700 } == true, "\(crossed)")
        // Owed again at each digest, it is held back by the link's memo, which each round reads before it picks: no write.
        let written = lab[0].transport.written.count { $0.to == bob.nodeId && ExactKey($0.envelope.id) == ExactKey(mail.envelope.id) }
        #expect(written == crossed.count)
    }
}
