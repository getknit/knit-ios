import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The reviewer's follow-ups on phase 2b of ADR 2026-11.sv5t, beside `BlindLinkTests`: a proving blinding dialer's hint
/// taken before its registration's promotion, a blinding peer's link score once its id's presence lapses, and a tag dial a
/// crossing link made fail.
@Suite struct BlindLinkScoreTests {
    private let low = LinkRig.low
    private let high = LinkRig.high

    /// The reviewer's follow-up on phase 2b: a proving blinding dialer's hint is taken before its registration's own
    /// promotion, so its tag, whose head start falls due at that moment, is not dialed.
    @Test func anInboundBlindingDialerWhoseHeadStartIsDueAtRegistrationIsNotDialed() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.hear(peer.sighting(tag), for: 22_000)
        rig.clock.advance(2000)
        _ = try peer.dial(rig, on: ChannelID(100), told: tag)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(rig.radio.dials.isEmpty)
        rig.hear(peer.sighting(tag), for: 30_000)
        #expect(rig.radio.dials.isEmpty)
    }

    /// The reviewer's follow-up on phase 2b: an unannounced rotation leaves a blinding peer's id with no attributed
    /// sighting once its presence lapses, and its link then scores as never sighted (−90), not lost (−127): at the budget a
    /// candidate 5 dB above the floor does not shed it.
    @Test func aBlindingPeersLinkWithNoAttributedSightingScoresAsNeverSighted() throws {
        var configuration = LinkManager.Configuration()
        configuration.promotion.maxLinks = 1
        configuration.claimsBlindAdvert = true
        let rig = LinkRig(local: high, advertisesServiceData: false, servesDoorbell: true, configuration: configuration)
        let peer = BlindingPeer(low)
        let wall = rig.clock.wallMilliseconds()
        _ = try peer.dial(rig, on: ChannelID(100), told: peer.tag(wall: wall))
        _ = rig.handle(.sighted(peer.sighting(peer.tag(wall: wall))))
        let link = try #require(rig.links.liveLinks.first)
        #expect(link.sighted && link.blinds)
        _ = rig.advance(100_000)
        #expect(rig.links.linkRssi(link) == configuration.unsightedLinkRssi, "its id's presence lapsed with the link up")
        rig.sightToPromotion(LinkRig.middle, rssi: -85)
        #expect(rig.links.neighbors.map(\.nodeId) == [low])
        #expect(!rig.said("link evicting \(low)"))
    }

    /// `DialKeys.linkedNow` (`DialKeys.kt:114-118`): a tag dial its own peer's crossing link made fail is no failure, and
    /// books no backoff.
    @Test func aTagDialACrossingLinkFromItsPeerMadeFailBooksNothing() throws {
        let rig = LinkRig.iPhone()
        let peer = BlindingPeer(low)
        let tag = peer.tag(wall: rig.clock.wallMilliseconds())
        rig.links.listPresenceKeys([low: [peer.key]])
        rig.hear(peer.sighting(tag), for: 24_000)
        let dial = try #require(rig.radio.dials.first)
        _ = try peer.dial(rig, on: ChannelID(100), told: tag)
        #expect(rig.links.liveChannel(to: low) == ChannelID(100))
        _ = rig.handle(.closed(dial.channel))
        #expect(rig.links.backoffs.isEmpty)
    }
}
