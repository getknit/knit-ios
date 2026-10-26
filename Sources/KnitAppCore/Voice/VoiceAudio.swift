/// What a voice note's bytes say about themselves, without a decoder: how long it plays, and the headers the recorder
/// writes around each AAC frame. Knit for Android's `VoiceAudio` (knit-next ADR 034), whose rules this ports exactly,
/// so a note's length on an iPhone and on a Pixel is the same number from the same bytes.
///
/// A voice note is AAC-LC in an ADTS stream. Android chose ADTS because its bytes must never reach the disk as
/// plaintext, and the MPEG-4 muxer needs a seekable file to write its `moov` atom. The iPhone keeps its recording in
/// memory for the same reason. ADTS frame headers state their own length and the stream's rate, so the length is exact
/// arithmetic over the headers, and neither phone carries it on the wire.
public enum VoiceAudio {
    /// The type every voice note is stored and sent under (`VoiceAudio.MIME`).
    public static let mime = "audio/aac"

    /// Samples one AAC-LC frame decodes to. The format fixes it, and it makes the length arithmetic.
    public static let samplesPerFrame = 1024

    /// An ADTS header without its optional CRC. A frame's length field counts the header, CRC or not.
    static let headerBytes = 7

    /// The channel counts an ADTS header can state: configurations 1 to 7.
    static let channelConfigurations = 1...7

    /// The longest frame an ADTS header can state: its length field has 13 bits.
    static let maxFrameBytes = 8191

    // The MPEG-4 rates, indexed by an ADTS header's 4-bit `sampling_frequency_index` (`VoiceAudio.kt:46-47`): the
    // standard's own table, which no name would explain.
    // swiftlint:disable:next no_magic_numbers
    static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8000, 7350]

    /// Where the fields the walk reads sit in a header's seven bytes (ISO/IEC 14496-3, 1.A.2.2).
    private enum Place {
        /// The syncword's low four bits, then the MPEG version, the layer and whether a CRC follows.
        static let version = 1
        /// The profile, `sampling_frequency_index` and the channel configuration's top bit.
        static let rate = 2
        /// The rest of the channel configuration, then the top two bits of `aac_frame_length`.
        static let lengthTop = 3
        /// The length's middle eight bits.
        static let lengthMiddle = 4
        /// The length's low three bits, then the top of `adts_buffer_fullness`.
        static let lengthLow = 5
    }

    /// The syncword's first eight bits.
    private static let syncHigh: UInt8 = 0xFF
    /// The syncword's last four bits, at the top of the second byte.
    private static let syncLow: UInt8 = 0xF0
    /// The second byte the recorder writes: the syncword's end, MPEG-4, layer 0, and no CRC.
    private static let mpeg4WithoutCRC: UInt8 = 0xF1
    /// The LC profile: audio object type 2, written as the type minus one.
    private static let lowComplexity: UInt8 = 1
    /// Where the profile sits in its byte.
    private static let profileShift: UInt8 = 6
    /// Where `sampling_frequency_index` sits in its byte.
    private static let rateMask: UInt8 = 0x3C
    /// How far `sampling_frequency_index` is shifted up in its byte.
    private static let rateShift: UInt8 = 2
    /// How far the channel configuration's top bit is shifted down to end the third byte.
    private static let channelTopShift: UInt8 = 2
    /// The channel configuration's low two bits.
    private static let channelLowMask: UInt8 = 0x03
    /// Where the channel configuration's low two bits sit at the top of the fourth byte.
    private static let channelLowShift: UInt8 = 6
    /// The length's top two bits, at the foot of the fourth byte.
    private static let lengthTopMask = 0x03
    /// How far the length's top two bits are from its foot.
    private static let lengthTopShift = 11
    /// How far the length's middle eight bits are from its foot.
    private static let lengthMiddleShift = 3
    /// The length's low three bits.
    private static let lengthLowMask = 0x07
    /// Where the length's low three bits sit at the top of the sixth byte.
    private static let lengthLowShift = 5
    /// The top five bits of `adts_buffer_fullness`, all set: a variable bit rate.
    private static let fullnessTop: UInt8 = 0x1F
    /// The rest of `adts_buffer_fullness`, set, and `number_of_raw_data_blocks_in_frame` 0: one block.
    private static let fullnessLowAndOneBlock: UInt8 = 0xFC

    /// Milliseconds in a second.
    private static let millisecondsPerSecond: Int64 = 1000

    /// Whether `mime` names audio the app treats as a voice note. Android's one rule for every surface
    /// (`VoiceAudio.isVoice`): any `audio/` type, so a picked file's type counts as well as `audio/aac`. It compares bytes,
    /// as Kotlin's `startsWith` and both stores' `undescribedVoiceNotes` do, not graphemes, which `hasPrefix` would.
    public static func isVoice(_ mime: String?) -> Bool {
        mime?.utf8.starts(with: "audio/".utf8) == true
    }

    /// How long the ADTS stream in `bytes` plays, in whole milliseconds, or `nil` when `bytes` doesn't open with a
    /// well-formed ADTS frame (`VoiceAudio.durationMs`, `VoiceAudio.kt:138-141`).
    ///
    /// The walk reads each frame's length and steps over it. A frame whose length is shorter than a header, or runs past
    /// the end, stops the walk without failing it, so a cut transfer reports the length of what is whole. The rate
    /// comes from the first frame alone, as Android's does, and the division truncates as Kotlin's `Long` division does.
    public static func durationMs(adts bytes: [UInt8]) -> Int? {
        guard let count = frames(in: bytes) else {
            return nil
        }
        let milliseconds = count.frames * Int64(samplesPerFrame) * millisecondsPerSecond / Int64(count.sampleRate)
        return Int(exactly: milliseconds)
    }

    /// The seven-byte ADTS header for an AAC-LC frame of `payloadBytes` bytes, or `nil` when the frame would be too long
    /// to state, the rate has no index, or the channel count has no configuration.
    ///
    /// The header says MPEG-4, no CRC, the LC profile, a variable bit rate (`adts_buffer_fullness` all ones) and one raw
    /// block, as Android's encoder writes it and its test fixture (`AdtsFixture.kt`) spells it.
    public static func header(payloadBytes: Int, sampleRate: Int, channels: Int) -> [UInt8]? {
        let length = payloadBytes + headerBytes
        guard payloadBytes >= 0, length <= maxFrameBytes, let index = sampleRates.firstIndex(of: sampleRate),
            channelConfigurations.contains(channels)
        else {
            return nil
        }
        let rate = UInt8(index)
        let channel = UInt8(channels)
        return [
            syncHigh,
            mpeg4WithoutCRC,
            lowComplexity << profileShift | rate << rateShift | channel >> channelTopShift,
            (channel & channelLowMask) << channelLowShift | UInt8(length >> lengthTopShift),
            UInt8(truncatingIfNeeded: length >> lengthMiddleShift),
            UInt8(length & lengthLowMask) << lengthLowShift | fullnessTop,
            fullnessLowAndOneBlock,
        ]
    }

    /// How many frames the stream holds, and at what rate (`countFrames`, `VoiceAudio.kt:282-306`).
    private static func frames(in bytes: [UInt8]) -> (frames: Int64, sampleRate: Int)? {
        var offset = 0
        var frames: Int64 = 0
        var sampleRate = 0
        while offset + headerBytes <= bytes.count {
            // The syncword is twelve set bits. Anything else is no frame's start.
            guard bytes[offset] == syncHigh, bytes[offset + Place.version] & syncLow == syncLow else {
                break
            }
            if sampleRate == 0 {
                let index = Int((bytes[offset + Place.rate] & rateMask) >> rateShift)
                guard index < sampleRates.count else {
                    return nil
                }
                sampleRate = sampleRates[index]
            }
            // aac_frame_length: thirteen bits across three bytes, counting the header itself.
            let top = Int(bytes[offset + Place.lengthTop] & UInt8(lengthTopMask)) << lengthTopShift
            let middle = Int(bytes[offset + Place.lengthMiddle]) << lengthMiddleShift
            let length = top | middle | Int(bytes[offset + Place.lengthLow]) >> lengthLowShift
            guard length >= headerBytes, offset + length <= bytes.count else {
                break
            }
            frames += 1
            offset += length
        }
        guard frames > 0, sampleRate > 0 else {
            return nil
        }
        return (frames, sampleRate)
    }
}
