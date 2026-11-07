import KnitMesh
import KnitWire
import Testing

/// Tag 9, `TAG_NEXT` (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): read on a live link, never written, and with it no HELLO
/// that tells a form of our own. Beside `LinkAdmissionTests`' keepalive rule.
@Suite struct LinkTagNextTests {
    private let low = LinkRig.low
    private let middle = LinkRig.middle
    private let high = LinkRig.high

    /// A TAG_NEXT of 16 bytes on a live link is read past for now, and the link stays; one of any other length is a framing
    /// error that drops it, as on Android (`LinkFraming.kt:149-150`; `keyed-v1.json`'s `blind.tagNext`).
    @Test func aTagNextIsReadPastAndOneOfAnotherLengthDropsTheLink() throws {
        let rig = LinkRig(local: high)
        _ = rig.accept(low, on: ChannelID(100))
        let before = rig.radio.records(on: ChannelID(100))
        let tagNext = try #require(LinkRecord(.tagNext, payload: [0xCE, 0x73, 0x94] + [UInt8](repeating: 0x2C, count: 13)).encoded)
        #expect(rig.handle(.received(ChannelID(100), tagNext)).isEmpty)
        #expect(rig.radio.closed.isEmpty && rig.links.neighbors.count == 1, "the link stays")
        #expect(rig.radio.records(on: ChannelID(100)) == before, "and nothing answers it")
        let short = Array(tagNext.prefix(LinkRecord.headerBytes - 1)) + [15]
        #expect(rig.handle(.received(ChannelID(100), short)) == [.down(low)], "from the header alone")
        #expect(rig.radio.closed == [ChannelID(100)])
    }

    /// This port never airs a tag, so it never writes a TAG_NEXT (`interop.md`), and no HELLO it writes tells a form (`t`)
    /// of its own (ADR 2026-11.sv5t): on a link accepted, one dialed, and through a run past every timer.
    @Test(arguments: [false, true])
    func aTagNextIsNeverWrittenNorAHelloThatTellsAForm(servesDoorbell: Bool) throws {
        let rig = LinkRig(local: high, servesDoorbell: servesDoorbell)
        _ = rig.accept(low, on: ChannelID(100))
        let dialed = try rig.link(middle)
        let channels = [ChannelID(100), dialed]
        #expect(rig.links.neighbors.count == 2)
        rig.run(until: rig.clock.monotonicMilliseconds() + 240_000)
        #expect(rig.links.neighbors.count == 2, "both links lived through the run, so a timer had its chance")
        let written = (channels + rig.radio.dials.map(\.channel)).flatMap { rig.radio.records(on: $0) }
        #expect(!written.contains { $0.tag == .tagNext })
        let hellos = written.filter { $0.tag == .hello }
        #expect(hellos.count >= 2)
        // `payload` never writes `t`, so a HELLO that carried one would not re-encode to its own bytes.
        #expect(hellos.allSatisfy { Hello(payload: $0.payload).told == nil && Hello(payload: $0.payload).payload == $0.payload })
    }
}
