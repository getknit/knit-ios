import KnitStore
import KnitWire
import Testing

@testable import KnitCrypto
@testable import KnitMesh

/// Two link managers joined by one link: each one's writes on its channel arrive on the other's, as they would through two
/// radios. Records cross whole, in order, until neither side has more to say.
///
/// A link that opens sealed (an advert with `FLAG_LINK_SEAL` dialed) carries frames, so the pipe reads inside them: both
/// rigs make their ephemeral keys from scalars it knows (``LinkManager/makeEphemeral``), it derives the same sessions, and
/// ``records(from:)`` holds what each side wrote, opened, as it holds a plain link's records.
final class RigPipe {
    let one: LinkRig
    let oneChannel: ChannelID
    let two: LinkRig
    let twoChannel: ChannelID
    private var oneDelivered = 0
    private var twoDelivered = 0
    /// Each side's outer reader, the opener for what it writes, the reader of its frames' plaintext, and its records.
    private var outer = [LinkRecordReader(), LinkRecordReader()]
    private var openers: [LinkOpener?] = [nil, nil]
    private var inner = [LinkRecordReader(), LinkRecordReader()]
    private var opened: [[LinkRecord]] = [[], []]
    /// Every event either side answered while the pipe pumped: `one`'s, then `two`'s.
    private(set) var events: [[LinkManager.Event]] = [[], []]

    init(_ one: LinkRig, _ oneChannel: ChannelID, _ two: LinkRig, _ twoChannel: ChannelID) {
        self.one = one
        self.oneChannel = oneChannel
        self.two = two
        self.twoChannel = twoChannel
        let dialer = (0..<32).map { 0x40 &+ UInt8($0) }
        let responder = (0..<32).map { 0xA0 &+ UInt8($0) }
        one.links.makeEphemeral = { required(LinkSeal.Ephemeral(scalar: dialer)) }
        two.links.makeEphemeral = { required(LinkSeal.Ephemeral(scalar: responder)) }
        let dialerShare = required(LinkSeal.Ephemeral(scalar: dialer)).keyShare
        let responderShare = required(LinkSeal.Ephemeral(scalar: responder)).keyShare
        // The responder's session opens what `one` writes, and the dialer's what `two` writes.
        openers[0] = try? LinkSeal.derive(required(LinkSeal.Ephemeral(scalar: responder)), peerShare: dialerShare, role: .responder).opener
        openers[1] = try? LinkSeal.derive(required(LinkSeal.Ephemeral(scalar: dialer)), peerShare: responderShare, role: .dialer).opener
    }

    /// What `rig`, one of the two, wrote on the pipe so far, as records: inside the frames on a sealed link.
    func records(from rig: LinkRig) -> [LinkRecord] {
        opened[rig.links === one.links ? 0 : 1]
    }

    /// Reads `bytes` that side `index` wrote: its outer records, each frame opened, into ``records(from:)``.
    private func read(_ bytes: [UInt8], from index: Int) {
        outer[index].append(bytes)
        while let record = try? outer[index].next() {
            switch record.tag {
            case .keyShare:
                continue
            case .sealed:
                guard let plaintext = openers[index]?.open(sealedPayload: record.payload) else {
                    continue
                }
                inner[index].append(plaintext)
                while let plain = try? inner[index].next() {
                    opened[index].append(plain)
                }
            default:
                opened[index].append(record)
            }
        }
    }

    /// `one` dialed on its channel: it opens, `two` accepts, and the records cross until quiet.
    static func dial(_ one: LinkRig, _ oneChannel: ChannelID, to two: LinkRig, on twoChannel: ChannelID) -> RigPipe {
        let pipe = RigPipe(one, oneChannel, two, twoChannel)
        pipe.events[1] += two.handle(.accepted(twoChannel))
        pipe.events[0] += one.handle(.connected(oneChannel))
        pipe.pump()
        return pipe
    }

    /// Carries what each side wrote to the other until neither wrote more.
    func pump() {
        for _ in 0..<100 {
            let fromOne = one.radio.writes(on: oneChannel)
            let fromTwo = two.radio.writes(on: twoChannel)
            guard fromOne.count > oneDelivered || fromTwo.count > twoDelivered else {
                return
            }
            if fromOne.count > oneDelivered {
                let bytes = fromOne[oneDelivered...].flatMap(\.self)
                oneDelivered = fromOne.count
                read(bytes, from: 0)
                events[1] += two.handle(.received(twoChannel, bytes))
            }
            if fromTwo.count > twoDelivered {
                let bytes = fromTwo[twoDelivered...].flatMap(\.self)
                twoDelivered = fromTwo.count
                read(bytes, from: 1)
                events[0] += one.handle(.received(oneChannel, bytes))
            }
        }
    }

    /// Both rigs' clocks on by `milliseconds`, in steps of at most a second, each firing what falls due, the pipe pumped.
    func advance(_ milliseconds: Int64) {
        var left = milliseconds
        while left > 0 {
            let step = min(left, 1000)
            events[0] += one.advance(step)
            events[1] += two.advance(step)
            pump()
            left -= step
        }
    }
}

/// Whether any line `log` kept names one of `tags`, as its 26 characters or its 32 hex digits.
func namesATag(_ log: RecordingLog, _ tags: some Sequence<NodeId>) -> Bool {
    tags.contains { tag in log.all.contains { $0.contains(tag.string) || $0.contains(Hex.encode(tag.bytes)) } }
}
