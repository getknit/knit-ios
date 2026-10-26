#if os(iOS) && DEBUG
    import AVFoundation
    import KnitAppCore
    import KnitMesh
    import KnitSync

    /// The microphone, recording a voice note as Android's `VoiceRecorder` does (knit-next ADR 034): AAC-LC, mono,
    /// 32 kbps, at the first of Android's rates the encoder takes (16 kHz first), in ADTS frames, into memory. The note
    /// never reaches the disk as plaintext: `AVAudioRecorder` writes a file, so the engine's input tap feeds an
    /// `AVAudioConverter` instead, and each packet it makes is framed with the header `VoiceAudio` writes.
    ///
    /// The session takes the built-in microphone and plays to the speaker or to a headset's A2DP side, never switching a
    /// headset to its call profile. Android records from the phone's own microphone too, and a headset in that profile
    /// would take the radio the mesh shares.
    @MainActor
    internal final class EngineVoiceCapture: VoiceCapture {
        /// Frames the tap hands over at a time: about 85 ms at 48 kHz.
        private static let tapFrames: AVAudioFrameCount = 4096

        private let log: any KnitLog
        private var engine: AVAudioEngine?
        private var encoder: Encoder?

        /// A microphone logging to `log`.
        init(log: any KnitLog) {
            self.log = log
        }

        var level: Double {
            encoder?.level ?? 0
        }

        func start() -> Bool {
            stopEngine()
            let audio = AVAudioSession.sharedInstance()
            do {
                try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try audio.setActive(true)
            } catch {
                log.log(.warning, "voice: the session would not record: \(error)")
                return false
            }
            let started = AVAudioEngine()
            let input = started.inputNode
            let heard = input.outputFormat(forBus: 0)
            guard heard.sampleRate > 0, heard.channelCount > 0, let made = Encoder(from: heard, log: log) else {
                log.log(.warning, "voice: no encoder for the input's \(heard)")
                deactivate()
                return false
            }
            input.installTap(onBus: 0, bufferSize: Self.tapFrames, format: heard, block: Self.tap(into: made))
            started.prepare()
            do {
                try started.start()
            } catch {
                log.log(.warning, "voice: the engine would not start: \(error)")
                input.removeTap(onBus: 0)
                deactivate()
                return false
            }
            log.log(.debug, "voice: recording \(heard.sampleRate) Hz in, \(made.rate) Hz out")
            engine = started
            encoder = made
            return true
        }

        func stop() -> [UInt8] {
            let made = encoder
            stopEngine()
            let bytes = made?.finish() ?? []
            log.log(.debug, "voice: recorded \(bytes.count) bytes")
            return bytes
        }

        func cancel() {
            stopEngine()
        }

        private func stopEngine() {
            guard let engine else {
                return
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            encoder = nil
            deactivate()
        }

        private func deactivate() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        /// The tap's block, made outside the main actor: the engine calls it on its audio thread, and a block made in a
        /// main-actor method would carry that isolation there and trap.
        nonisolated private static func tap(into made: Encoder) -> AVAudioNodeTapBlock {
            { buffer, _ in made.encode(buffer) }
        }
    }

    /// The converter and what it has made, fed from the engine's audio thread and drained on the main actor's stop, so
    /// both sides go through one lock.
    private final class Encoder: Sendable {
        // Android's rates, best for speech first (`VoiceRecorder.SAMPLE_RATES`, `VoiceRecorder.kt:269`): its list, which no
        // name would explain.
        // swiftlint:disable:next no_magic_numbers
        private static let rates = [16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        /// Android's bit rate (`BIT_RATE`, `VoiceRecorder.kt:272`).
        private static let bitRate = 32_000
        /// Where the drain stops keeping bytes, 4 MiB, as Android's does (`MAX_BYTES`, `VoiceRecorder.kt:261`).
        private static let mostBytes = 4_194_304
        /// Room for the largest packet: an AAC-LC frame holds at most 6144 bits a channel.
        private static let roomyPacket = 2048
        /// Packets made per pass of the converter.
        private static let packetsPerPass: AVAudioPacketCount = 16

        private struct State {
            /// Not Sendable: every use of it is under ``state``'s lock.
            var converter: AVAudioConverter
            var bytes: [UInt8] = []
            var level = 0.0
            var full = false
        }

        private let state: Lock<State>
        private let format: AVAudioFormat
        private let maxPacket: Int
        /// The rate the note is encoded at.
        let rate: Int

        /// An AAC-LC encoder from `input`, at the first of Android's rates the system's encoder takes, or `nil`.
        init?(from input: AVAudioFormat, log: any KnitLog) {
            for tried in Self.rates {
                var description = AudioStreamBasicDescription(
                    mSampleRate: Double(tried),
                    mFormatID: kAudioFormatMPEG4AAC,
                    mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                    mBytesPerPacket: 0,
                    mFramesPerPacket: UInt32(VoiceAudio.samplesPerFrame),
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: 1,
                    mBitsPerChannel: 0,
                    mReserved: 0
                )
                guard let output = AVAudioFormat(streamDescription: &description),
                    let converter = AVAudioConverter(from: input, to: output)
                else {
                    continue
                }
                // An encoder handed a rate it doesn't take can configure and then make nothing (ADR 034): ask it first.
                if let takes = converter.applicableEncodeSampleRates, !takes.contains(where: { $0.intValue == tried }) {
                    continue
                }
                converter.downmix = input.channelCount > 1
                converter.bitRateStrategy = AVAudioBitRateStrategy_Constant
                // The bit rate nearest Android's that the encoder takes at this rate: an unlisted one is refused.
                let bitRates = converter.applicableEncodeBitRates?.map(\.intValue) ?? []
                converter.bitRate = bitRates.min { abs($0 - Self.bitRate) < abs($1 - Self.bitRate) } ?? Self.bitRate
                rate = tried
                format = output
                maxPacket = max(converter.maximumOutputPacketSize, Self.roomyPacket)
                state = Lock(State(converter: converter))
                return
            }
            log.log(.warning, "voice: no AAC rate of \(Self.rates) encodes from \(input)")
            return nil
        }

        /// How loud the last buffer was, 0 to 1.
        var level: Double {
            state.withLock { $0.level }
        }

        /// Encodes one buffer from the tap, keeping the level of its loudest sample.
        func encode(_ buffer: AVAudioPCMBuffer) {
            let loudest = Self.loudest(buffer)
            state.withLock { state in
                state.level = loudest
                drain(&state, handing: buffer, ending: false)
            }
        }

        /// The note: what is left in the converter flushed, then every frame made.
        func finish() -> [UInt8] {
            state.withLock { state in
                drain(&state, handing: nil, ending: true)
                return state.bytes
            }
        }

        /// Runs the converter until it wants more, framing each packet it makes. Past the byte limit it keeps nothing
        /// more, as Android's drain stops, so what reached memory is the note.
        private func drain(_ state: inout State, handing buffer: AVAudioPCMBuffer?, ending: Bool) {
            var handed = false
            while !state.full {
                let packets = AVAudioCompressedBuffer(format: format, packetCapacity: Self.packetsPerPass, maximumPacketSize: maxPacket)
                var error: NSError?
                let status = state.converter.convert(to: packets, error: &error) { _, inputStatus in
                    if let buffer, !handed {
                        handed = true
                        inputStatus.pointee = .haveData
                        return buffer
                    }
                    inputStatus.pointee = ending ? .endOfStream : .noDataNow
                    return nil
                }
                frame(packets, into: &state)
                guard error == nil, status == .haveData, packets.packetCount > 0 else {
                    return
                }
            }
        }

        /// Appends each packet in `packets` behind its ADTS header.
        private func frame(_ packets: AVAudioCompressedBuffer, into state: inout State) {
            guard let descriptions = packets.packetDescriptions else {
                return
            }
            let data = packets.data.assumingMemoryBound(to: UInt8.self)
            for index in 0..<Int(packets.packetCount) {
                let description = descriptions[index]
                let length = Int(description.mDataByteSize)
                guard let header = VoiceAudio.header(payloadBytes: length, sampleRate: rate, channels: 1),
                    state.bytes.count + header.count + length <= Self.mostBytes
                else {
                    state.full = true
                    return
                }
                state.bytes += header
                state.bytes += UnsafeBufferPointer(start: data + Int(description.mStartOffset), count: length)
            }
        }

        /// The loudest sample in `buffer`, from 0 to 1, of any channel (`getMaxAmplitude`).
        private static func loudest(_ buffer: AVAudioPCMBuffer) -> Double {
            guard let channels = buffer.floatChannelData else {
                return 0
            }
            var loudest: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    loudest = max(loudest, abs(channels[channel][frame]))
                }
            }
            return Double(min(loudest, 1))
        }
    }
#endif
