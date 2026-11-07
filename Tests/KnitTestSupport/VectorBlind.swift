/// `keyed-v1.json`'s `blind` section: blinded adverts (knit-next ADR 2026-11.xp6d, #285; ADR 2026-11.sv5t). The file's
/// `about` string documents every field. Only what a reader needs is decoded; the rest of the section is skipped.
public struct VectorBlind: Decodable, Sendable {
    /// One `hasPrefix` case.
    public struct PrefixCase: Decodable, Sendable {
        /// The bytes, as hex.
        public let bytes: String
        /// Whether they carry a tag's 20 fixed bits.
        public let hasPrefix: Bool
    }

    /// The fields Android reads from the blinded advert.
    public struct ParsedAdvert: Decodable, Sendable {
        /// Bytes 1–16 as a 26-character form.
        public let form: String
        /// Whether `FLAG_BLINDED` is set.
        public let blinded: Bool
        /// The capabilities' low byte.
        public let capabilities: UInt8
        /// The digest cue, zeroed by a blinding writer.
        public let digestCue: UInt32
        /// The L2CAP PSM.
        public let psm: UInt16
        /// Whether `FLAG_AWARE` is set.
        public let aware: Bool
    }

    /// The blinded advert as Android airs it.
    public struct BlindedAdvert: Decodable, Sendable {
        /// The tag in bytes 1–16, as hex.
        public let tag: String
        /// The flags byte.
        public let flags: UInt8
        /// The service data, as hex.
        public let serviceData: String
        /// What it parses to.
        public let parsed: ParsedAdvert
    }

    /// Service data that is not a blinded advert, and why.
    public struct OtherAdvert: Decodable, Sendable {
        /// The service data, as hex.
        public let serviceData: String
        /// Why it reads as it does.
        public let reason: String
    }

    /// The advert cases.
    public struct Adverts: Decodable, Sendable {
        /// A tag under `FLAG_BLINDED`.
        public let blinded: BlindedAdvert
        /// `FLAG_BLINDED` over an id: no advert.
        public let malformed: OtherAdvert
        /// A tag's bytes without the flag: a clear id.
        public let clearWithTagBytes: OtherAdvert
    }

    /// A record as hex and why it must fail.
    public struct BadRecord: Decodable, Sendable {
        /// The record, as hex.
        public let record: String
        /// Why it must fail.
        public let reason: String
    }

    /// A TAG_NEXT record.
    public struct TagNext: Decodable, Sendable {
        /// The 16 bytes it carries, as hex.
        public let tag: String
        /// The whole record, as hex.
        public let record: String
        /// The same record one byte short.
        public let wrongLength: BadRecord
    }

    /// One HELLO and the fields read behind its nonce.
    public struct HelloFields: Decodable, Sendable {
        /// The payload as text.
        public let payload: String
        /// Whether a valid nonce was read.
        public let nonce: Bool
        /// The told form, as hex, or nil.
        public let told: String?
        /// The addressed form, as hex, or nil.
        public let addressed: String?
    }

    /// A HELLO record of the tagged link.
    public struct LinkHello: Decodable, Sendable {
        /// The payload as text.
        public let payload: String
        /// The whole record, as hex.
        public let record: String
    }

    /// The tagged link: Alice, blinding, dials Bob's tag. Its proofs are KnitCrypto's to replay.
    public struct Link: Decodable, Sendable {
        /// Alice's HELLO, with `t` and `a`.
        public let helloTaggedDialer: LinkHello
        /// Bob's reply, with `t`.
        public let helloTaggedReply: LinkHello
    }

    /// `hasPrefix` cases by name.
    public let hasPrefix: [String: PrefixCase]
    /// The advert cases.
    public let advert: Adverts
    /// The TAG_NEXT record.
    public let tagNext: TagNext
    /// HELLO field cases by name.
    public let helloFields: [String: HelloFields]
    /// The tagged link.
    public let link: Link

    // MARK: KnitCrypto's half (`tags`, `slotOf`, `window`, `presenceKeys`, the link's transcripts and proofs) goes here.
}
