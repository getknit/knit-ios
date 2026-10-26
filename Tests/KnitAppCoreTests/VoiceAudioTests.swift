import Testing

@testable import KnitAppCore

/// A voice note's length, read from its ADTS headers with no decoder, and the headers the recorder writes (knit-next ADR
/// 034). Android's `VoiceAudioTest`, ported with its fixture, at the exact numbers its Kotlin gives, so a note's length
/// is the same on both phones.
@Suite struct VoiceAudioTests {
    /// Android's `adts` fixture (`AdtsFixture.kt`): `frames` frames of `frameLength` bytes each, header included, at the
    /// rate `index` names, with zeros for the payload and channel configuration 0. Only the header walk reads it.
    static func adts(_ frames: Int, frameLength: Int = 64, index: Int = 7) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: frames * frameLength)
        for frame in 0..<frames {
            let at = frame * frameLength
            out[at] = 0xFF
            out[at + 1] = 0xF1
            out[at + 2] = UInt8((index & 0x0F) << 2 | 0x40)
            out[at + 3] = UInt8((frameLength >> 11) & 0x03)
            out[at + 4] = UInt8((frameLength >> 3) & 0xFF)
            out[at + 5] = UInt8((frameLength & 0x07) << 5 | 0x1F)
            out[at + 6] = 0xFC
        }
        return out
    }

    /// 216 frames of 1024 samples at 22.05 kHz: 10031 ms, which Kotlin's `Long` division truncates to, not the 10032
    /// Android's comment says.
    @Test func aNoteLastsItsFramesSamplesOverItsRate() {
        #expect(VoiceAudio.durationMs(adts: Self.adts(216)) == 10_031)
    }

    /// The same frames at twice the rate play in half the time: a guess from the byte count would get this wrong.
    @Test func theLengthFollowsTheRateNotTheBytes() {
        #expect(VoiceAudio.durationMs(adts: Self.adts(100, index: 7)) == 4643)
        #expect(VoiceAudio.durationMs(adts: Self.adts(100, index: 4)) == 2321)
        #expect(VoiceAudio.durationMs(adts: Self.adts(10, index: 8)) == 640, "the recorder's 16 kHz")
    }

    /// 1200 bytes needs the length field's two high bits, in byte 3.
    @Test func aFramesLengthIsReadFromAllThirteenBits() {
        #expect(VoiceAudio.durationMs(adts: Self.adts(8, frameLength: 1200)) == 371)
    }

    /// A transfer cut inside a frame reports the frames that are whole.
    @Test func aCutStreamReportsTheFramesThatAreWhole() {
        let whole = Self.adts(10)
        #expect(VoiceAudio.durationMs(adts: Array(whole.dropLast(20))) == 417)
    }

    @Test func bytesThatAreNoADTSHaveNoLength() {
        #expect(VoiceAudio.durationMs(adts: []) == nil)
        #expect(VoiceAudio.durationMs(adts: [0xFF, 0xFF, 0xFF]) == nil, "shorter than a header")
        #expect(VoiceAudio.durationMs(adts: [UInt8](repeating: 0, count: 64)) == nil, "no syncword")
        #expect(VoiceAudio.durationMs(adts: Array("not audio at all, just text".utf8)) == nil)
        var tagged = [UInt8]("ID3".utf8)
        tagged += Self.adts(4)
        #expect(VoiceAudio.durationMs(adts: tagged) == nil, "a tag in front is no frame's start")
    }

    /// Indexes 13 to 15 are reserved, and a guessed rate would time every such stream wrongly.
    @Test func aReservedRateHasNoLength() {
        #expect(VoiceAudio.durationMs(adts: Self.adts(4, index: 13)) == nil)
        #expect(VoiceAudio.durationMs(adts: Self.adts(4, index: 15)) == nil)
    }

    /// A frame claiming 3 bytes would never move the walk on, and one claiming 8000 would read past the end.
    @Test func aFrameThatLiesAboutItsLengthEndsTheWalk() {
        var short = Self.adts(4)
        short[3] = 0
        short[4] = 0
        short[5] = 0x03 << 5
        #expect(VoiceAudio.durationMs(adts: short) == nil)
        var long = Self.adts(4)
        long[3] = UInt8((8000 >> 11) & 0x03)
        long[4] = UInt8((8000 >> 3) & 0xFF)
        long[5] = UInt8((8000 & 0x07) << 5 | 0x1F)
        #expect(VoiceAudio.durationMs(adts: long) == nil)
        var later = Self.adts(4)
        later[64 + 5] = 0x03 << 5
        later[64 + 4] = 0
        #expect(VoiceAudio.durationMs(adts: later) == 46, "a bad second frame keeps the first")
    }

    /// The recorder's header reads back as the walk reads Android's, with the mono channel set and the length whole.
    @Test func theRecordersHeaderReadsBackAsAFrame() throws {
        let header = try #require(VoiceAudio.header(payloadBytes: 57, sampleRate: 22_050, channels: 1))
        #expect(header.count == VoiceAudio.headerBytes)
        let fixture = Self.adts(1)
        #expect(header[0] == fixture[0] && header[1] == fixture[1])
        #expect(header[2] == fixture[2], "LC, index 7, the channel's high bit clear")
        #expect(header[3] == fixture[3] | 0x40, "channel configuration 1 in the top two bits")
        #expect(Array(header[4...]) == Array(fixture[4..<7]))

        var stream: [UInt8] = []
        for size in [100, 1300, 0, 8184] {
            stream += try #require(VoiceAudio.header(payloadBytes: size, sampleRate: 16_000, channels: 1))
            stream += [UInt8](repeating: 0x5A, count: size)
        }
        #expect(VoiceAudio.durationMs(adts: stream) == 256, "four frames at 16 kHz")
    }

    @Test func aHeaderThatCannotBeWrittenIsNil() {
        #expect(VoiceAudio.header(payloadBytes: 8185, sampleRate: 16_000, channels: 1) == nil, "past 13 bits")
        #expect(VoiceAudio.header(payloadBytes: -1, sampleRate: 16_000, channels: 1) == nil)
        #expect(VoiceAudio.header(payloadBytes: 10, sampleRate: 16_001, channels: 1) == nil, "no index")
        #expect(VoiceAudio.header(payloadBytes: 10, sampleRate: 16_000, channels: 0) == nil)
        #expect(VoiceAudio.header(payloadBytes: 10, sampleRate: 16_000, channels: 8) == nil)
    }

    @Test func anyAudioTypeIsAVoiceNote() {
        #expect(VoiceAudio.isVoice(VoiceAudio.mime))
        #expect(VoiceAudio.isVoice("audio/mp4"))
        #expect(!VoiceAudio.isVoice("image/jpeg"))
        #expect(!VoiceAudio.isVoice("image/webp"))
        #expect(!VoiceAudio.isVoice("AUDIO/aac"), "Android's prefix test is case-sensitive")
        #expect(!VoiceAudio.isVoice(nil))
        #expect(VoiceAudio.isVoice("audio/\u{301}x"), "a mark after the slash leaves the bytes' prefix whole")
    }
}
