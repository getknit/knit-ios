import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// Two link managers whose proven link the radio closed on both ends, so each holds a relink window for the other, dial
/// each other at once: the lower one's head start against the higher one's order dial. The higher end refuses the head
/// start while its own dial is open ("we dial it"), so exactly one link stands on both ends. Admitted, the head start
/// would prove beside the order dial, each end's keep-older would retire the other end's link, and both would be gone
/// (ADR 2026-11.sv5t).
@Suite struct LinkRelinkCrossingTests {
    /// One direction of a channel between two rigs: what `from` writes on `fromChannel` arrives on `to`'s `toChannel`, and
    /// `from` closing it closes `toChannel` too.
    private final class Leg {
        let from: LinkRig
        let fromChannel: ChannelID
        let to: LinkRig
        let toChannel: ChannelID
        var delivered = 0
        var closed = false

        init(_ from: LinkRig, _ fromChannel: ChannelID, _ to: LinkRig, _ toChannel: ChannelID) {
            self.from = from
            self.fromChannel = fromChannel
            self.to = to
            self.toChannel = toChannel
        }

        /// Hands over what came since the last step, then the close if there was one; whether anything moved.
        func step() -> Bool {
            var moved = false
            let writes = from.radio.writes(on: fromChannel)
            if writes.count > delivered {
                let bytes = writes[delivered...].flatMap(\.self)
                delivered = writes.count
                _ = to.handle(.received(toChannel, bytes))
                moved = true
            }
            if !closed, from.radio.closed.contains(fromChannel) {
                closed = true
                _ = to.handle(.closed(toChannel))
                moved = true
            }
            return moved
        }
    }

    /// Steps every leg in turn, one record batch each, until none moves: the HELLOs of both dials cross before either reply.
    private func interleave(_ legs: [Leg]) {
        for _ in 0..<50 {
            var moved = false
            for leg in legs {
                moved = leg.step() || moved
            }
            if !moved {
                return
            }
        }
    }

    private func liveChannels(_ rig: LinkRig) -> [ChannelID] {
        rig.links.liveLinks.map(\.channel)
    }

    @Test func aHeadStartCrossingTheOrderDialEndsWithOneLinkOnBothEnds() throws {
        let slow = LinkManager.Configuration(connectTimeoutMilliseconds: 60_000)
        let one = LinkRig(local: LinkRig.high, configuration: slow)
        let two = LinkRig(local: LinkRig.low, servesDoorbell: true, configuration: slow)
        // Both seal, so every dial here opens sealed, from adverts carrying the flag (a plain one is refused, §7).
        one.sightToPromotion(LinkRig.low, flags: LinkRig.sealingFlags)
        let first = try #require(one.radio.dials.last)
        _ = RigPipe.dial(one, first.channel, to: two, on: ChannelID(50))
        #expect(one.links.linksProven == 1 && two.links.linksProven == 1)
        _ = one.handle(.closed(first.channel))
        _ = two.handle(.closed(ChannelID(50)))
        #expect(one.relinkOpen(for: LinkRig.low) && two.relinkOpen(for: LinkRig.high))

        // The higher end redials the lower once its backoff ends, the lower still heard within the silence limit, and that
        // dial is slow to open. The lower end hears the higher and dials it once its head start ends, at 24 s.
        for second in 1...30 where two.radio.dials.isEmpty {
            _ = one.advance(1000)
            _ = two.advance(1000)
            if second.isMultiple(of: 2) {
                _ = two.handle(.sighted(LinkRig.sighting(LinkRig.high, flags: LinkRig.sealingFlags)))
            }
        }
        let order = try #require(one.radio.dials.last)
        let headStart = try #require(two.radio.dials.last)
        #expect(order.channel != first.channel)
        #expect(!one.radio.closed.contains(order.channel) && !two.radio.closed.contains(headStart.channel), "both dials open")
        #expect(one.relinkOpen(for: LinkRig.low), "inside the window")
        #expect(two.log.all.contains { $0.contains("link head start over for \(LinkRig.high)") })

        _ = one.handle(.accepted(ChannelID(70)))
        _ = two.handle(.accepted(ChannelID(71)))
        _ = one.handle(.connected(order.channel))
        _ = two.handle(.connected(headStart.channel))
        interleave([
            Leg(one, order.channel, two, ChannelID(71)),
            Leg(two, headStart.channel, one, ChannelID(70)),
            Leg(two, ChannelID(71), one, order.channel),
            Leg(one, ChannelID(70), two, headStart.channel),
        ])
        #expect(one.said("link refused \(LinkRig.low): we dial it"))
        #expect(liveChannels(one) == [order.channel], "the higher end keeps its order dial")
        #expect(liveChannels(two) == [ChannelID(71)], "the lower end the same link, as its responder")
        #expect(one.links.neighbors.map(\.nodeId) == [LinkRig.low])
        #expect(two.links.neighbors.map(\.nodeId) == [LinkRig.high])
    }
}
