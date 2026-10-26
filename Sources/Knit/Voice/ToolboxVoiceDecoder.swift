#if os(iOS) && DEBUG
    import AudioToolbox
    import Foundation
    import KnitAppCore

    /// A voice note's sound decoded in memory with AudioToolbox, for its waveform: Android's `VoiceAudio.decodeChunks`,
    /// whose `MediaExtractor` and `MediaCodec` read the bytes where they lie. A sealed note is opened in memory and never
    /// written out, so the decoder reads through AudioFile's callbacks rather than a file (knit-next ADR 034).
    ///
    /// Each run is 1024 frames of 16-bit sound, one AAC frame, the unit Android's decoder hands its buckets. The bytes are
    /// a peer's, so a run that fails ends the read, and the runs read so far stand, as Android keeps a partial decode.
    internal struct ToolboxVoiceDecoder: VoiceDecoder {
        /// Frames per run: one AAC-LC frame.
        private static let runFrames = 1024
        /// The most frames read: six minutes at 48 kHz, a little past the recorder's five, so hostile bytes claiming hours
        /// stop there (`SPEECH_FALLBACK_CAP_MS`).
        private static let mostFrames = 17_280_000
        /// Microseconds in a second.
        private static let microsecondsPerSecond = 1_000_000.0
        /// Milliseconds in a second.
        private static let millisecondsPerSecond = 1000.0

        func runs(of bytes: [UInt8]) -> [VoicePeaks.Chunk]? {
            AudioBytes.open(bytes) { file in
                Self.read(file)
            }
        }

        func containerMilliseconds(of bytes: [UInt8]) -> Int? {
            AudioBytes.open(bytes) { file -> Int? in
                var seconds: Float64 = 0
                var size = UInt32(MemoryLayout<Float64>.size)
                guard AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &seconds) == noErr,
                    seconds.isFinite, seconds > 0
                else {
                    return nil
                }
                return Int(exactly: (seconds * Self.millisecondsPerSecond).rounded(.down))
            }
        }

        /// The runs of `file`, or `nil` when it yields no sound.
        private static func read(_ file: AudioFileID) -> [VoicePeaks.Chunk]? {
            var ext: ExtAudioFileRef?
            guard ExtAudioFileWrapAudioFileID(file, false, &ext) == noErr, let ext else {
                return nil
            }
            defer { ExtAudioFileDispose(ext) }
            var stored = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &stored) == noErr,
                stored.mSampleRate > 0
            else {
                return nil
            }
            let channels = max(stored.mChannelsPerFrame, 1)
            let bytesPerFrame = UInt32(MemoryLayout<Int16>.size) * channels
            var pcm = AudioStreamBasicDescription(
                mSampleRate: stored.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: bytesPerFrame,
                mFramesPerPacket: 1,
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channels,
                mBitsPerChannel: UInt32(Int16.bitWidth),
                mReserved: 0
            )
            guard ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, size, &pcm) == noErr else {
                return nil
            }
            var runs: [VoicePeaks.Chunk] = []
            var framesRead = 0
            var samples = [Int16](repeating: 0, count: runFrames * Int(channels))
            while framesRead < mostFrames {
                var frames = UInt32(runFrames)
                let status = samples.withUnsafeMutableBytes { raw in
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                    return ExtAudioFileRead(ext, &frames, &list)
                }
                guard status == noErr, frames > 0 else {
                    break
                }
                // Int16.min has no positive twin, so magnitudes are read wide.
                let loudest = samples[0..<Int(frames) * Int(channels)].reduce(Int64(0)) { max($0, abs(Int64($1))) }
                let start = Int64((Double(framesRead) / stored.mSampleRate * microsecondsPerSecond).rounded(.down))
                runs.append(VoicePeaks.Chunk(startMicroseconds: start, loudest: loudest))
                framesRead += Int(frames)
            }
            return runs.isEmpty ? nil : runs
        }
    }

    /// Audio bytes opened in memory through AudioFile's callbacks, the type sniffed from the bytes themselves.
    private final class AudioBytes {
        let bytes: [UInt8]

        private init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        /// `body`'s answer over `bytes` opened as an audio file, or `nil` when they don't open as one or it has none.
        static func open<Answer>(_ bytes: [UInt8], _ body: (AudioFileID) -> Answer?) -> Answer? {
            let source = Unmanaged.passRetained(AudioBytes(bytes))
            defer { source.release() }
            var file: AudioFileID?
            // 0: no type hint, so AudioFile reads the type from the bytes, ADTS or a picked file's container alike.
            guard AudioFileOpenWithCallbacks(source.toOpaque(), read, nil, size, nil, 0, &file) == noErr, let file else {
                return nil
            }
            defer { AudioFileClose(file) }
            return body(file)
        }

        /// AudioFile's read: up to `count` bytes from `position`, fewer at the end.
        private static let read: AudioFile_ReadProc = { client, position, count, buffer, actual in
            let source = Unmanaged<AudioBytes>.fromOpaque(client).takeUnretainedValue()
            guard position >= 0, position <= Int64(source.bytes.count) else {
                actual.pointee = 0
                return kAudioFileInvalidPacketOffsetError
            }
            let start = Int(position)
            let length = min(Int(count), source.bytes.count - start)
            source.bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress, length > 0 {
                    buffer.copyMemory(from: base + start, byteCount: length)
                }
            }
            actual.pointee = UInt32(length)
            return noErr
        }

        /// AudioFile's size: the whole of the bytes.
        private static let size: AudioFile_GetSizeProc = { client in
            Int64(Unmanaged<AudioBytes>.fromOpaque(client).takeUnretainedValue().bytes.count)
        }
    }
#endif
