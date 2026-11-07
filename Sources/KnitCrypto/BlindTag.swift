import Crypto
public import KnitWire

/// The rotating tag a blinding phone writes in bytes 1–16 of its Bluetooth advert in place of its node id, ported byte for
/// byte from `BlindTag.kt` at knit-next `cad69c77b` (knit-next ADR 2026-11.xp6d, "The tag" and its 2026-11-06 amendment
/// "the owner-bound tag"; ADR 2026-11.sv5t). A direct contact holding the owner's ``PresenceKey`` resolves it; anyone
/// else sees 16 bytes that change at every rotation.
///
/// ```text
/// m = HMAC-SHA256(presenceKey, "knit/advert/v1/slot" (19 ASCII) ‖ owner (16 raw) ‖ u64be(slot) ‖ u8(restart))
///                                                                                    (a 44-byte message)
/// byte 0      0xCE                     ┐ the 20 fixed bits, `zzzz` in base32 (`AdvertForm.hasTagPrefix`)
/// byte 1      0x73                     │
/// byte 2      0x90 | (m[0] >> 4)       ┘ the high nibble fixed, the low one m[0]'s high nibble
/// bytes 3…15  m[1…13]                    108 MAC bits in all
/// ```
///
/// - **The owner** is the node id the key is filed under, as its 16 raw bytes (``NodeId/bytes``): the signed sender of the
///   ctl 11 that delivered it. A key re-sent by a contact as its own gives tags under that contact's id, never the
///   owner's, so no key needs a uniqueness rule.
/// - **The slot** is the sender's wall clock in 15-minute steps, floored, and the reader's ``window(wallMilliseconds:)``
///   is its own clock's last 8 hours and next half hour. No skew is corrected: a contact whose clock is off by more is
///   not recognised before a link.
/// - **Total.** Every input here is what a peer delivered or a stranger aired, and this port mints no tag of its own, so
///   nothing throws or traps: a bad owner or restart answers `nil`, and a bad key cannot be a ``PresenceKey``. Kotlin's
///   `tag` throws on those, because there they are the advertiser's own (`BlindTag.kt:118-128`).
/// - **Never logged.** A key, a MAC and a tag are not printed anywhere; ``Expected`` and ``Slotted`` print none.
///
/// Pure, over swift-crypto's `HMAC<SHA256>`, which is CryptoKit's on Apple platforms and agrees with JCA's
/// `HmacSHA256` byte for byte (RFC 2104).
public enum BlindTag {
    /// A tag's length: the node id's slot in the advert (`BlindTag.BYTES`, `BlindTag.kt:73`).
    public static let byteCount = AdvertForm.tagByteCount
    /// A presence key's length (`BlindTag.KEY_BYTES`, `:76`).
    public static let keyByteCount = PresenceKey.byteCount
    /// The MAC's label, 19 ASCII bytes (`BlindTag.LABEL`, `:78`). Shares no prefix with `knit/link/v1/…`,
    /// `knit/dm/v2/…`, `knit/group/v1/…` or `knit/card/v1`.
    public static let label = "knit/advert/v1/slot"
    /// A slot: 15 minutes of wall clock, the rotation period (`BlindTag.SLOT_MS`, `:81`).
    public static let slotMilliseconds: Int64 = 900_000
    /// Restart indices per slot, `0..<4`, so a bring-up inside one slot airs a tag never aired before (`BlindTag.RESTARTS`,
    /// `:84`). A reader lists them all.
    public static let restarts = 4
    /// The slots before the current one a reader resolves: the last 8 hours (`BlindTag.WINDOW_PAST_SLOTS`, `:87`).
    public static let windowPastSlots: Int64 = 32
    /// The slots after the current one a reader resolves: the next half hour (`BlindTag.WINDOW_AHEAD_SLOTS`, `:88`).
    public static let windowAheadSlots: Int64 = 2

    /// The MAC's message length: label, owner, slot and restart.
    static let messageByteCount = label.utf8.count + NodeId.byteCount + MemoryLayout<UInt64>.size + 1
    /// The prefix's first byte (`PREFIX_0`, `:91`).
    private static let prefix0: UInt8 = 0xCE
    /// The prefix's second byte (`PREFIX_1`, `:92`).
    private static let prefix1: UInt8 = 0x73
    /// The prefix's last four bits, `1001`, in the split byte's high nibble (`PREFIX_2_HIGH`, `:93`).
    private static let prefix2High: UInt8 = 0x90
    /// A nibble's width (`NIBBLE_BITS`, `:95`).
    private static let nibbleBits: UInt8 = 4
    /// The split byte: the prefix's last nibble above the MAC's first (`SPLIT_BYTE`, `:98`).
    private static let splitByte = 2
    private static let labelBytes = Array(label.utf8)

    /// The slot holding `wallMilliseconds`, floored, so −1 ms is slot −1 and not slot 0 (`slotOf`, `:105`, Kotlin's
    /// `Math.floorDiv`).
    public static func slotOf(wallMilliseconds: Int64) -> Int64 {
        let (quotient, remainder) = wallMilliseconds.quotientAndRemainder(dividingBy: slotMilliseconds)
        return remainder < 0 ? quotient - 1 : quotient
    }

    /// The slots a reader whose wall clock reads `wallMilliseconds` resolves: `slotOf − 32 ... slotOf + 2`, 35 slots
    /// (`window`, `:108`). The slot is at most `Int64.max / 900000` in size, so neither bound overflows.
    public static func window(wallMilliseconds: Int64) -> ClosedRange<Int64> {
        let slot = slotOf(wallMilliseconds: wallMilliseconds)
        return (slot - windowPastSlots)...(slot + windowAheadSlots)
    }

    /// The tag under `key` and `owner` for `slot` and `restart`, or `nil` for an owner that is not 16 bytes or a restart
    /// outside `0..<4`. Deterministic. One ``Expected`` serves a table better; this is its one-off.
    public static func tag(key: PresenceKey, owner: [UInt8], slot: Int64, restart: Int) -> [UInt8]? {
        Expected(key: key, owner: owner).tag(slot: slot, restart: restart)
    }

    /// One expected tag: its bytes, and the slot and restart that produced it (`BlindTag.Slotted`, `:137-141`). Its
    /// printing shows the slot and restart, never the tag.
    public struct Slotted: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
        /// The tag, ``BlindTag/byteCount`` bytes.
        public let tag: [UInt8]
        /// The slot it is aired in.
        public let slot: Int64
        /// Its restart index within the slot.
        public let restart: Int

        /// The slot and restart only.
        public var description: String { "Slotted(slot: \(slot), restart: \(restart))" }

        /// The slot and restart only.
        public var customMirror: Mirror { Mirror(self, children: ["slot": slot, "restart": restart], displayStyle: .struct) }
    }

    /// One key's expected tags under one owner, for the expected-tag table a reader builds over its window
    /// (`BlindTag.Expected`, `:155-185`; knit-next's `ExpectedTagTable`). Total: an owner that is not 16 bytes lists
    /// nothing and answers `nil`, so a table rebuild never traps on what a peer delivered.
    ///
    /// It keeps the key as a `SymmetricKey` and computes each tag whole with `HMAC<SHA256>.authenticationCode(for:using:)`,
    /// where Kotlin keeps one `Mac` it resets per tag; no MAC state crosses two tags, so interleaved listings agree. Its
    /// printing shows neither the key nor the owner.
    public struct Expected: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        private let key: SymmetricKey
        private let owner: [UInt8]?

        /// `key`'s tags under `owner`, the raw id the key is filed under; none for an owner that is not exactly 16 bytes,
        /// which a truncating read would otherwise let through.
        public init(key: PresenceKey, owner: [UInt8]) {
            self.key = SymmetricKey(data: key.bytes)
            self.owner = owner.count == NodeId.byteCount ? owner : nil
        }

        /// `key`'s tags under `owner`.
        public init(key: PresenceKey, owner: NodeId) {
            self.init(key: key, owner: owner.bytes)
        }

        /// The tag for `slot` and `restart`, or `nil` for a bad owner or a restart outside `0..<4` (`Expected.tag`,
        /// `:163-171`).
        public func tag(slot: Int64, restart: Int) -> [UInt8]? {
            guard let owner, (0..<BlindTag.restarts).contains(restart) else {
                return nil
            }
            return BlindTag.compute(key: key, owner: owner, slot: slot, restart: restart)
        }

        /// Every restart of every slot in `slots`, slot-major (`slot, 0..<4`): `slots.count × 4` MACs, 140 over a
        /// ``BlindTag/window(wallMilliseconds:)`` (`Expected.tags`, `:177-184`). Empty for a bad owner or no slots.
        public func tags(slots: some Sequence<Int64>) -> [Slotted] {
            guard owner != nil else {
                return []
            }
            var listed: [Slotted] = []
            for slot in slots {
                for restart in 0..<BlindTag.restarts {
                    if let tag = tag(slot: slot, restart: restart) {
                        listed.append(Slotted(tag: tag, slot: slot, restart: restart))
                    }
                }
            }
            return listed
        }

        /// No key, owner or tag.
        public var description: String { "BlindTag.Expected(owner: \(owner == nil ? "invalid" : "set"))" }

        /// As ``description``.
        public var debugDescription: String { description }

        /// No children, so reflection shows neither the key nor the owner.
        public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
    }

    /// The MAC's message: the label, the owner's 16 raw bytes, the slot as a big-endian u64 in two's complement, and the
    /// restart's byte (`compute`, `:196-200`). `owner` is 16 bytes and `restart` in `0..<4`, checked by every caller.
    static func message(owner: [UInt8], slot: Int64, restart: Int) -> [UInt8] {
        var message = labelBytes
        message.reserveCapacity(messageByteCount)
        message.append(contentsOf: owner)
        let pattern = UInt64(bitPattern: slot)
        for shift in stride(from: UInt64.bitWidth - UInt8.bitWidth, through: 0, by: -UInt8.bitWidth) {
            message.append(UInt8(truncatingIfNeeded: pattern >> UInt64(shift)))
        }
        message.append(UInt8(truncatingIfNeeded: restart))
        return message
    }

    /// The HMAC-SHA256 of ``message(owner:slot:restart:)`` under `key`.
    static func mac(key: SymmetricKey, owner: [UInt8], slot: Int64, restart: Int) -> [UInt8] {
        copiedBytes(HMAC<SHA256>.authenticationCode(for: message(owner: owner, slot: slot, restart: restart), using: key))
    }

    /// The tag's layout over the MAC (`compute`, `:201-206`): `CE 73 (90 | m[0] >> 4)`, then `m[1...13]`.
    private static func compute(key: SymmetricKey, owner: [UInt8], slot: Int64, restart: Int) -> [UInt8] {
        let mac = mac(key: key, owner: owner, slot: slot, restart: restart)
        var tag = [prefix0, prefix1, prefix2High | (mac[0] >> nibbleBits)]
        tag.append(contentsOf: mac[1..<(byteCount - splitByte)])
        return tag
    }
}
