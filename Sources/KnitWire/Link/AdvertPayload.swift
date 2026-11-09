/// The 24 bytes Android advertises as Service Data under `0xFE30` (`BleAdvertPayload.kt` in knit-next), and
/// the same bytes an iPhone serves from its GATT characteristic.
///
/// | Offset | Size | Field |
/// | --- | --- | --- |
/// | 0 | 1 | capabilities, low byte |
/// | 1 | 16 | advertised form, raw: the node id, or a rotating tag when ``blinded`` |
/// | 17 | 4 | digest cue, big-endian |
/// | 21 | 2 | L2CAP PSM, big-endian |
/// | 23 | 1 | BLE-local flags (optional on the wire) |
///
/// Byte 23 holds bit 0 ``sideChannelFlag``, bit 1 ``dialsGattPeersFlag``, bit 2 ``awareFlag``, bit 3 ``blindedFlag`` and
/// bit 4 ``linkSealFlag``; bits 5-7 are reserved (0), and a parser tests only the bits it knows, so a new bit is additive.
/// Bits 0-3 are facts about the radio; bit 4 is a fact about the build, the one the HELLO's ``Capabilities/linkSeal``
/// carries, which the advert's low capability byte has no room for (the `link-seal` contract, §1).
public struct AdvertPayload: Sendable, Equatable {
    /// The shortest payload a scanner accepts: everything but the flags byte.
    public static let minimumSize = 23
    /// The full payload.
    public static let size = 24

    /// Bit 0: this node advertises and scans the BLE side channel. Android sets it while its side channel runs, in
    /// release since knit-next `713b29d6` (`FLAG_SIDE_CHANNEL`, `BleAdvertPayload.kt:54` at `808472a3`). This port runs
    /// no side channel, so it never sets the bit.
    public static let sideChannelFlag: UInt8 = 0x01
    /// Bit 1: this node reads the GATT payload of peers that advertise no service data, and dials them
    /// itself. An iPhone uses it to tell whether an Android peer can see it (ADR router:
    /// `.agents/memory/decisions.md`).
    public static let dialsGattPeersFlag: UInt8 = 0x02
    /// Bit 2: Android's `FLAG_AWARE`, said positively: set, a peer may count on this phone's Wi-Fi Aware now (knit-next
    /// `808472a3`, `BleAdvertPayload.kt:64-72`; knit-next ADR 2026-10.2t49's 2026-10-27 amendment, GitHub #44). Android
    /// makes a peer an Aware candidate only from a service-data sighting with the bit set, and a GATT-payload sighting
    /// never makes one (`AwareCandidateTracker.kt:63-70` and `:79`, called at `BluetoothMeshTransport.kt:2295`).
    /// No radio here runs Wi-Fi Aware, so the bit is reserved: no advert this port writes sets it
    /// (``writtenFlags(dialsGattPeers:blinded:seals:)``, for knit-peer's service data and the iPhone's GATT payload alike), and
    /// nothing here reads it. The codec keeps it, so a parsed Android advert round-trips.
    public static let awareFlag: UInt8 = 0x04
    /// Bit 3: Android's `FLAG_BLINDED` (knit-next ADR 2026-11.xp6d, `BleAdvertPayload.kt:88` at `cad69c77b`). Set, bytes
    /// 1–16 are a rotating tag (``AdvertForm/hasTagPrefix(_:)``), not the advertiser's node id, and nothing may key them
    /// as one. This port reads it (ADR 2026-11.sv5t), and sets it on the iPhone's GATT payload while the iPhone blinds
    /// (``writtenFlags(dialsGattPeers:blinded:seals:)``; ADR 2026-11.prsp): mandatory whenever bytes 1–16 are a tag, since a
    /// build at the pin reads a tag without it as a node id and dials it into `WrongPeer`.
    public static let blindedFlag: UInt8 = 0x08
    /// Bit 4: Android's `FLAG_LINK_SEAL` (the `link-seal` contract, §1; knit-next #286). Set exactly when the advertiser's
    /// HELLO carries ``Capabilities/linkSeal``, so a dialer opens a link to it with a `KEY_SHARE` (§2): the advert dialed
    /// from decides the form, and nothing else does. Unauthenticated, which is why a plain link whose two HELLOs carry the
    /// bit is refused (§7). A 23-byte payload has no flags byte, so it reads the flag clear.
    public static let linkSealFlag: UInt8 = 0x10

    /// The 16-bit service UUID under which Android puts the payload in its advert's service data, and under which
    /// a node that cannot advertise service data (an iPhone) lists a GATT service instead.
    public static let serviceUUID = "0000fe30-0000-1000-8000-00805f9b34fb"
    /// The read-only characteristic in that GATT service whose value is ``gattValue``. Minted by this port on
    /// 2026-09-25; Android reads it once companion change A3 lands, so it is cross-platform law from then on.
    public static let characteristicUUID = "848eedcd-a2e3-4fb2-86f9-e2c80821a497"
    /// The writable characteristic beside it, which a peer writes to wake a node whose app iOS has suspended: data on
    /// an open link does not wake it, and a write does. The value means nothing. Minted by this port on 2026-09-27.
    public static let doorbellUUID = "f34c056b-5830-4243-a888-01f92f49e446"

    /// The flags byte this port advertises, mirroring Kotlin's `flags(sideLive:gattPeers:aware:blinded:)`
    /// (`BleAdvertPayload.kt:95-104` at knit-next `cad69c77b`) with two of its inputs always false: no side channel runs
    /// here, so ``sideChannelFlag`` stays clear, and no Wi-Fi Aware does, so ``awareFlag`` stays clear.
    /// ``dialsGattPeersFlag`` is set only while the radio reads GATT payloads (`Radio.dialsGattPeers`), so it never claims a
    /// read it cannot make, and ``blindedFlag`` exactly when bytes 1–16 are a tag (`blinded`, ADR 2026-11.prsp).
    /// ``linkSealFlag`` is set exactly when the HELLO this node would write carries ``Capabilities/linkSeal`` (`seals`; the
    /// `link-seal` contract, §1), in the clear form and the blinded form alike, so knit-peer's switches that take the bit
    /// out, or strip the flag alone, clear it here too.
    public static func writtenFlags(dialsGattPeers: Bool, blinded: Bool, seals: Bool) -> UInt8 {
        (dialsGattPeers ? dialsGattPeersFlag : 0) | (blinded ? blindedFlag : 0) | (seals ? linkSealFlag : 0)
    }

    private static let capabilitiesMask: Int64 = 0xFF

    /// The capability bits' low byte.
    public var capabilities: UInt8
    /// Bytes 1–16 as aired: the advertiser's node id when the advert is clear, a rotating tag when it is ``blinded``
    /// (knit-next ADR 2026-11.xp6d). `NodeId`-shaped either way, so read ``blinded`` before treating it as an id.
    public var advertised: NodeId
    /// The low 32 bits of the advertiser's custody fold. Nothing on Bluetooth reads it.
    public var digestCue: UInt32
    /// The L2CAP PSM to dial.
    public var psm: UInt16
    /// The BLE-local flags byte.
    public var flags: UInt8

    /// Whether bytes 1–16 are a tag, not a node id (``blindedFlag``; Kotlin's `Parsed.blinded`).
    public var blinded: Bool { flags & Self.blindedFlag != 0 }

    /// Whether the advertiser seals links, so a dial to it opens with a `KEY_SHARE` (``linkSealFlag``; the `link-seal`
    /// contract, §2).
    public var seals: Bool { flags & Self.linkSealFlag != 0 }

    /// Makes a payload from full capabilities, keeping their low byte, airing `nodeId` in the clear; ``advertised`` holds it.
    public init(capabilities: Capabilities, nodeId: NodeId, digestCue: UInt32, psm: UInt16, flags: UInt8 = 0) {
        self.init(capabilities: capabilities, advertised: nodeId, digestCue: digestCue, psm: psm, flags: flags)
    }

    /// Makes a payload airing `advertised`: the node id, or a tag when `flags` carries ``blindedFlag`` (ADR 2026-11.prsp).
    public init(capabilities: Capabilities, advertised: NodeId, digestCue: UInt32, psm: UInt16, flags: UInt8) {
        self.capabilities = UInt8(capabilities.rawValue & Self.capabilitiesMask)
        self.advertised = advertised
        self.digestCue = digestCue
        self.psm = psm
        self.flags = flags
    }

    /// What a log line may print of ``advertised``: the id of a clear payload, and never a tag's bytes, which a log would tie
    /// to the address and the time it was read (ADR 2026-11.prsp, "Counts, never dated causes").
    public var shownForm: String {
        blinded ? "a tag" : advertised.string
    }

    /// Parses Service Data the way Android does (`BleAdvertPayload.parse`, `BleAdvertPayload.kt:175-187` at `cad69c77b`):
    /// shorter than 23 bytes is not a Knit advert, exactly 23 reads the flags as 0, and bytes past 24 are ignored. A
    /// payload whose flags carry ``blindedFlag`` over bytes 1–16 that lack the tag prefix is not one either, and is dropped
    /// before anything is computed (`isMalformedBlinded`, `:193-197`). Without the bit, bytes 1–16 are an id whatever they
    /// hold, a tag's prefix included.
    public init?(serviceData bytes: [UInt8]) {
        guard bytes.count >= Self.minimumSize, !Self.isMalformedBlinded(bytes) else {
            return nil
        }
        guard let parsedForm = NodeId(bytes: Array(bytes[1...NodeId.byteCount])) else {
            return nil
        }
        let cueStart = 1 + NodeId.byteCount
        let psmStart = cueStart + MemoryLayout<UInt32>.size
        capabilities = bytes[0]
        advertised = parsedForm
        digestCue = bytes[cueStart..<psmStart].reduce(0) { $0 << UInt8.bitWidth | UInt32($1) }
        psm = bytes[psmStart..<Self.minimumSize].reduce(0) { $0 << UInt8.bitWidth | UInt16($1) }
        flags = bytes.count > Self.minimumSize ? bytes[Self.minimumSize] : 0
    }

    /// Parses a peer's GATT characteristic value exactly as ``init(serviceData:)`` reads service data: a ``blinded`` payload
    /// whose bytes 1–16 carry the tag prefix is a blinded form, which a blinding iPhone serves (ADR 2026-11.prsp), and one
    /// flagged without the prefix is no payload, so both radios take their "serves no Knit payload" path. Android at
    /// `cad69c77b` answers every blinded payload with a stranger (`BleGattPayloadReader.kt:86-88`); companion change A11
    /// teaches it to read one as this does.
    public init?(gattValue bytes: [UInt8]) {
        self.init(serviceData: bytes)
    }

    /// Whether `bytes` are long enough to carry the flags byte, it says ``blindedFlag``, and bytes 1–16 lack the tag prefix
    /// (`BleAdvertPayload.isMalformedBlinded`, `BleAdvertPayload.kt:193-197` at `cad69c77b`). A 23-byte payload has no flags
    /// byte, so it is never blinded.
    private static func isMalformedBlinded(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > minimumSize, bytes[minimumSize] & blindedFlag != 0 else {
            return false
        }
        return !AdvertForm.hasTagPrefix(Array(bytes[1...NodeId.byteCount]))
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
        output += advertised.bytes
        for shift in stride(from: UInt32.bitWidth - UInt8.bitWidth, through: 0, by: -UInt8.bitWidth) {
            output.append(UInt8(truncatingIfNeeded: digestCue >> UInt32(shift)))
        }
        output.append(UInt8(truncatingIfNeeded: psm >> UInt8.bitWidth))
        output.append(UInt8(truncatingIfNeeded: psm))
        output.append(flags)
        return output
    }
}
