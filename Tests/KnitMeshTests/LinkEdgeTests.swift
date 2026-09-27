import KnitMesh
import KnitWire
import Testing

/// The link manager's quieter paths: debounces that settle on nothing, backoff that is forgotten, several
/// channels timing out at once, and what it logs.
@Suite struct LinkEdgeTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    @Test func aCueThatChangesBackBeforeTheDebounceAdvertisesNothingNew() {
        let rig = LinkRig(local: high)
        _ = rig.handle(.listening(psm: 0x81))
        rig.links.updateDigestCue(5)
        rig.links.updateDigestCue(0)
        _ = rig.advance(1500)
        #expect(rig.radio.advertised.count == 1)
    }

    @Test func anUnchangedCueArmsNothing() {
        let rig = LinkRig(local: high)
        rig.links.updateDigestCue(0)
        #expect(rig.links.nextDeadline == nil)
    }

    @Test func startingTwiceIsHarmless() {
        let rig = LinkRig(local: high)
        rig.links.start()
        #expect(rig.radio.started)
    }

    @Test func aBackoffIsTheNextDeadline() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        let id = try #require(rig.radio.dials.first?.channel)
        let failedAt = rig.clock.monotonicMilliseconds()
        _ = rig.handle(.dialFailed(id))
        let deadline = try #require(rig.links.nextDeadline)
        #expect(deadline >= failedAt + 8000 && deadline <= failedAt + 12_000, "10 s ± 20 %")
    }

    @Test func aPeerThatLeftComesBackToAFreshStreak() throws {
        let rig = LinkRig(local: high)
        rig.sightToPromotion(low)
        _ = rig.handle(.dialFailed(try #require(rig.radio.dials.last?.channel)))
        // Gone past the 90 s linger and its backoff, then back: the old streak is forgotten.
        _ = rig.advance(200_000)
        rig.sightToPromotion(low)
        let second = try #require(rig.radio.dials.last?.channel)
        #expect(rig.radio.dials.count == 2)
        let failedAt = rig.clock.monotonicMilliseconds()
        _ = rig.handle(.dialFailed(second))
        let deadline = try #require(rig.links.nextDeadline)
        #expect(deadline <= failedAt + 12_000, "streak 1 again, not 2")
    }

    @Test func severalHellosTimeOutTogether() {
        let rig = LinkRig(local: high)
        _ = rig.handle(.accepted(ChannelID(101)))
        _ = rig.handle(.accepted(ChannelID(100)))
        _ = rig.advance(5000)
        #expect(rig.radio.closed == [ChannelID(100), ChannelID(101)])
    }

    @Test func theRadioGoingOffTakesEveryLinkDownInOrder() {
        let rig = LinkRig(local: high)
        _ = rig.accept(middle, on: ChannelID(101))
        _ = rig.accept(low, on: ChannelID(100))
        #expect(rig.handle(.state(.unauthorized)) == [.down(low), .down(middle)])
    }

    @Test func aDigestThatDoesNotDecodeIsIgnored() {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let junk = LinkRecord(.digest, payload: Array("not json".utf8)).encoded ?? []
        #expect(rig.handle(.received(ChannelID(100), junk)).isEmpty)
        #expect(rig.links.neighbors.count == 1)
    }

    @Test func theLogSaysWhatHappened() throws {
        let configuration = LinkManager.Configuration(promotion: PromotionPolicy.Configuration(maxLinks: 1))
        let rig = LinkRig(local: high, configuration: configuration)
        _ = rig.handle(.state(.on))
        let id = try rig.link(low, rssi: -80)
        rig.clock.advance(20_000)
        rig.sightToPromotion(middle, rssi: -60)
        _ = rig.accept(low, on: ChannelID(100))
        _ = rig.handle(.accepted(ChannelID(101)))
        _ = rig.advance(5000)
        let payload = Array(repeating: UInt8(0), count: LinkRecord.maxPayloadBytes)
        let big = RelayEnvelope(type: .chat, id: "big", senderId: low.string, payload: payload)
        rig.links.send(WireEnvelope(sig: [1], signed: big.encoded), to: nil)
        let lines = rig.log.all
        #expect(lines.contains("info link radio on"))
        #expect(lines.contains("info link dialing \(low) on \(id)"))
        #expect(lines.contains("info link up \(low) on \(id)"))
        #expect(lines.contains("info link evicting \(low)"))
        #expect(lines.contains("info link down \(low) on \(id)"))
        #expect(lines.contains("info link refused \(low): we dial it"))
        #expect(lines.contains("info link ch101 timed out"))
        #expect(lines.contains("warning link dropped a frame too large for a record"))
    }

    @Test func aBadRecordIsLoggedWithWhatCameBeforeIt() throws {
        let rig = LinkRig(local: high)
        let id = try rig.link(low)
        let hello = LinkRig.helloRecord(low)
        let frame = LinkRig.frameRecord(LinkRig.signedFrame("f1"))
        let garbage: [UInt8] = [0x57, 0x36, 0x00, 0x01, 0x02]
        _ = rig.handle(.received(id, frame + garbage))
        let line = try #require(rig.log.all.first { $0.hasPrefix("warning link \(id) sent a bad record") })
        let at = hello.count + frame.count
        #expect(line.contains("unknownTag(87) at byte \(at) of \(at + garbage.count); next 5736000102 \"W6...\""))
        let tail = Hex.encode(Array(frame.suffix(16)))
        #expect(line.contains("after hello \(hello.count - 5), frame \(frame.count - 5) ending \(tail)"))
        #expect(line.hasSuffix("; reads \(hello.count), \(frame.count + garbage.count)"))
    }

    @Test func aBadFirstRecordSaysNothingCameBeforeIt() throws {
        let rig = LinkRig(local: high)
        _ = rig.handle(.accepted(ChannelID(200)))
        _ = rig.handle(.received(ChannelID(200), [9, 0, 0, 0, 0]))
        let line = try #require(rig.log.all.first { $0.hasPrefix("warning link ch200 sent a bad record") })
        #expect(line.hasSuffix("unknownTag(9) at byte 0 of 5; next 0900000000 \".....\"; no record before it; reads 5"))
    }

    @Test func refusalsAndReplacementsAreLogged() {
        let rig = LinkRig(local: low)
        _ = rig.handle(.sighted(LinkRig.sighting(high)))
        _ = rig.accept(high, on: ChannelID(100))
        _ = rig.accept(high, on: ChannelID(101))
        _ = rig.accept(middle, on: ChannelID(102))
        _ = rig.accept(middle, on: ChannelID(104))
        _ = rig.advance(30_000)
        _ = rig.accept(middle, on: ChannelID(103))
        _ = rig.handle(.received(ChannelID(103), [9, 0, 0, 0, 0]))
        let lines = rig.log.all
        #expect(lines.contains("info link refused \(high): already linked"))
        #expect(lines.contains("info link refused \(middle): its link is too young to replace"))
        #expect(lines.contains("info link \(middle) replaced its stale link ch102 with ch103"))
        #expect(lines.contains { $0.hasPrefix("warning link ch103 sent a bad record") })
    }
}
