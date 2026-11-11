import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Two link managers joined by one link: each one's writes on its channel arrive on the other's, as they would through two
/// radios. Records cross whole, in order, until neither side has more to say.
final class RigPipe {
    let one: LinkRig
    let oneChannel: ChannelID
    let two: LinkRig
    let twoChannel: ChannelID
    private var oneDelivered = 0
    private var twoDelivered = 0
    /// Every event either side answered while the pipe pumped: `one`'s, then `two`'s.
    private(set) var events: [[LinkManager.Event]] = [[], []]

    init(_ one: LinkRig, _ oneChannel: ChannelID, _ two: LinkRig, _ twoChannel: ChannelID) {
        self.one = one
        self.oneChannel = oneChannel
        self.two = two
        self.twoChannel = twoChannel
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
                events[1] += two.handle(.received(twoChannel, bytes))
            }
            if fromTwo.count > twoDelivered {
                let bytes = fromTwo[twoDelivered...].flatMap(\.self)
                twoDelivered = fromTwo.count
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
