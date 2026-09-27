import KnitWire

/// What a channel carried just before a record failed to parse, so that the warning that drops the link says why. A
/// record that overran its length shows as an odd size among the records before it and a payload that runs into the
/// next header. A read that went missing shows as bytes that were never a header. On 2026-09-27 an iPhone twice read
/// a tag outside 1..7 from the Pixel 3 at link-up, and the log gave only the tag (`.agents/context/linux-peer.md`,
/// "What A4 showed").
internal struct LinkTrace {
    /// How many of the latest reads the trace keeps.
    static let keptReads = 6
    /// How many of the latest records it keeps.
    static let keptRecords = 4
    /// How much of the latest record's payload it keeps, from the end.
    static let tailBytes = 16
    /// How many bytes of the bad record the warning shows.
    static let shownBytes = 32

    private static let printable: ClosedRange<UInt8> = 0x20...0x7E

    /// Every byte the radio has handed over on the channel.
    private(set) var bytesRead = 0
    /// The sizes of the latest reads, oldest first.
    private var reads: [Int] = []
    /// The latest records, oldest first: each one's tag and payload size.
    private var records: [(tag: LinkRecord.Tag, bytes: Int)] = []
    /// The end of the latest record's payload.
    private var tail: [UInt8] = []

    /// The radio handed over `count` more bytes.
    mutating func read(_ count: Int) {
        bytesRead += count
        reads = Array((reads + [count]).suffix(Self.keptReads))
    }

    /// A whole record came off the channel.
    mutating func parsed(_ record: LinkRecord) {
        records = Array((records + [(record.tag, record.payload.count)]).suffix(Self.keptRecords))
        tail = Array(record.payload.suffix(Self.tailBytes))
    }

    /// Where the bad record starts, its first bytes as hex and as text, what came before it, and the latest reads.
    func explain(_ reader: LinkRecordReader) -> String {
        let next = reader.upcoming(Self.shownBytes)
        let text = String(next.map { Self.printable.contains($0) ? Character(Unicode.Scalar($0)) : "." })
        let before =
            records.isEmpty
            ? "no record before it"
            : "after " + records.map { "\($0.tag) \($0.bytes)" }.joined(separator: ", ") + " ending \(Hex.encode(tail))"
        let latest = reads.map(String.init).joined(separator: ", ")
        return "at byte \(reader.consumed) of \(bytesRead); next \(Hex.encode(next)) \"\(text)\"; \(before); reads \(latest)"
    }
}
