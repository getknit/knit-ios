/// The 24 bytes Android advertises as Service Data under `0xFE30` (`BleAdvertPayload.kt` in knit-next), and
/// the same bytes an iPhone serves from its GATT characteristic.
///
/// | Offset | Size | Field |
/// | --- | --- | --- |
/// | 0 | 1 | capabilities, low byte |
/// | 1 | 16 | node id, raw |
/// | 17 | 4 | digest cue, big-endian |
/// | 21 | 2 | L2CAP PSM, big-endian |
/// | 23 | 1 | BLE-local flags (optional on the wire) |
public struct AdvertPayload: Sendable, Equatable {
    /// The shortest payload a scanner accepts: everything but the flags byte.
    public static let minimumSize = 23
    /// The full payload.
    public static let size = 24

    /// Bit 0: this node sends side-channel pages. Always clear in release builds, and never set by this build.
    public static let sideChannelFlag: UInt8 = 0x01
    /// Bit 1: this node reads the GATT payload of peers that advertise no service data, and dials them
    /// itself. An iPhone uses it to tell whether an Android peer can see it (ADR router:
    /// `.agents/memory/decisions.md`).
    public static let dialsGattPeersFlag: UInt8 = 0x02

    /// The 16-bit service UUID under which Android puts the payload in its advert's service data, and under which
    /// a node that cannot advertise service data (an iPhone) lists a GATT service instead.
    public static let serviceUUID = "0000fe30-0000-1000-8000-00805f9b34fb"
    /// The read-only characteristic in that GATT service whose value is ``gattValue``. Minted by this port on
    /// 2026-09-25; Android reads it once companion change A3 lands, so it is cross-platform law from then on.
    public static let characteristicUUID = "848eedcd-a2e3-4fb2-86f9-e2c80821a497"

    private static let capabilitiesMask: Int64 = 0xFF

    /// The capability bits' low byte.
    public var capabilities: UInt8
    /// The advertiser's node id.
    public var nodeId: NodeId
    /// The low 32 bits of the advertiser's custody fold. Nothing on Bluetooth reads it.
    public var digestCue: UInt32
    /// The L2CAP PSM to dial.
    public var psm: UInt16
    /// The BLE-local flags byte.
    public var flags: UInt8

    /// Makes a payload from full capabilities, keeping their low byte.
    public init(capabilities: Capabilities, nodeId: NodeId, digestCue: UInt32, psm: UInt16, flags: UInt8 = 0) {
        self.capabilities = UInt8(capabilities.rawValue & Self.capabilitiesMask)
        self.nodeId = nodeId
        self.digestCue = digestCue
        self.psm = psm
        self.flags = flags
    }

    /// Parses Service Data the way Android does: shorter than 23 bytes is not a Knit advert, exactly 23 reads
    /// the flags as 0, and bytes past 24 are ignored.
    public init?(serviceData bytes: [UInt8]) {
        guard bytes.count >= Self.minimumSize, let parsedId = NodeId(bytes: Array(bytes[1...NodeId.byteCount])) else {
            return nil
        }
        let cueStart = 1 + NodeId.byteCount
        let psmStart = cueStart + MemoryLayout<UInt32>.size
        capabilities = bytes[0]
        nodeId = parsedId
        digestCue = bytes[cueStart..<psmStart].reduce(0) { $0 << UInt8.bitWidth | UInt32($1) }
        psm = bytes[psmStart..<Self.minimumSize].reduce(0) { $0 << UInt8.bitWidth | UInt16($1) }
        flags = bytes.count > Self.minimumSize ? bytes[Self.minimumSize] : 0
    }

    /// What the GATT characteristic serves: the same 24 bytes with the digest cue at 0. Nothing on Bluetooth reads
    /// the cue, so the value changes only when the PSM does, and a reader never sees it churn.
    public var gattValue: [UInt8] {
        var value = self
        value.digestCue = 0
        return value.bytes
    }

    /// The 24 bytes.
    public var bytes: [UInt8] {
        var output: [UInt8] = [capabilities]
        output.reserveCapacity(Self.size)
        output += nodeId.bytes
        for shift in stride(from: UInt32.bitWidth - UInt8.bitWidth, through: 0, by: -UInt8.bitWidth) {
            output.append(UInt8(truncatingIfNeeded: digestCue >> UInt32(shift)))
        }
        output.append(UInt8(truncatingIfNeeded: psm >> UInt8.bitWidth))
        output.append(UInt8(truncatingIfNeeded: psm))
        output.append(flags)
        return output
    }
}
