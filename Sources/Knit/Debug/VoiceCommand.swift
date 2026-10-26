#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitControl
    import KnitCrypto
    import KnitMesh
    import KnitStore
    import KnitWire

    /// A debug build's voice notes from a script (knit-next ADR 034), since only the app records, plays and decodes
    /// them, and the bridge answers it rather than ``MeshControl``:
    ///
    /// - `{"cmd":"voice","conv":"<thread>"}`: each voice note in a thread, as this phone read it: its length and bars,
    ///   whether its bytes are here, and whether they open and decode.
    /// - `{"cmd":"voice","record":<milliseconds>}`: records that long with the composer's microphone and answers the
    ///   note, base64 ADTS, which a `dm` then sends. The first record asks for the microphone and records nothing, as a
    ///   press does, so someone taps Allow.
    /// - `{"cmd":"voice","play":"<message id>"}` plays a note through the app's one player, and
    ///   `{"cmd":"voice","stop":true}` stops it.
    internal struct VoiceCommand: Decodable {
        static let name = "voice"
        /// How often a recording's loudness is read, in milliseconds.
        private static let levelEvery = 50
        /// Bits in a byte, and milliseconds in a second, for a recording's bit rate.
        private static let bitsPerByte = 8
        private static let millisecondsPerSecond = 1000
        /// The longest a script may record, the recorder's own cap.
        private static let longest = VoiceRecorder.longest

        let cmd: String
        let conv: String?
        let record: Int?
        let play: String?
        let stop: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// Answers what was asked of `session`'s voice notes.
        @MainActor
        func answer(_ session: AppSession) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            guard let voice = session.voiceNotes else {
                reply["ok"] = false
                reply["error"] = "this build has no voice notes"
                return JSONValue.object(reply).line
            }
            let fields: [String: JSONValue]
            if let record {
                fields = await recording(for: record, with: voice)
            } else if stop == true {
                voice.playback.stop()
                fields = ["ok": true]
            } else if let play {
                fields = await playing(play, in: session, with: voice)
            } else if let conv {
                fields = ["ok": true, "conv": .string(conv), "notes": .array(notes(in: conv, of: session, with: voice))]
            } else {
                fields = ["ok": false, "error": "say conv, record, play or stop"]
            }
            reply.merge(fields) { _, field in field }
            return JSONValue.object(reply).line
        }

        @MainActor
        private func recording(for milliseconds: Int, with voice: VoiceNotes) async -> [String: JSONValue] {
            switch voice.access.authorization {
            case .notDetermined:
                let answer = await voice.access.request()
                return ["ok": true, "asked": .bool(true), "allowed": .bool(answer == .allowed)]
            case .denied:
                return ["ok": false, "error": "the microphone is refused"]
            case .allowed:
                break
            }
            guard voice.capture.start() else {
                return ["ok": false, "error": "the microphone would not start"]
            }
            var loudest = 0.0
            let until = ContinuousClock.now + .milliseconds(min(max(milliseconds, 0), Self.longest))
            while ContinuousClock.now < until {
                try? await Task.sleep(for: .milliseconds(Self.levelEvery))
                loudest = max(loudest, voice.capture.level)
            }
            let bytes = voice.capture.stop()
            let length = VoiceAudio.durationMs(adts: bytes)
            let rate = length.flatMap { $0 > 0 ? bytes.count * Self.bitsPerByte * Self.millisecondsPerSecond / $0 : nil }
            let described = voice.decoder.describe(bytes)
            return [
                "ok": .bool(!bytes.isEmpty),
                "bytes": .int(Int64(bytes.count)),
                "durationMs": length.map { .int(Int64($0)) } ?? .null,
                "bitsPerSecond": rate.map { .int(Int64($0)) } ?? .null,
                "loudest": .string(String(format: "%.3f", loudest)),
                "bars": described.peaks.map { .string(Base64.encode($0)) } ?? .null,
                "adts": .string(Base64.encode(bytes)),
            ]
        }

        @MainActor
        private func playing(_ id: String, in session: AppSession, with voice: VoiceNotes) async -> [String: JSONValue] {
            guard let note = session.stores.messages.message(id)?.attachment, VoiceAudio.isVoice(note.mime) else {
                return ["ok": false, "error": .string("no voice note in message \(id)")]
            }
            await voice.playback.toggle(note.hash) { session.attachment(note.hash, key: note.key) }
            voice.playback.tick()
            let now = voice.playback.nowPlaying
            return [
                "ok": .bool(!voice.playback.unplayable.contains(note.hash)),
                "playing": .bool(now?.hash == note.hash && now?.playing == true),
                "positionMs": .int(Int64(now?.position ?? 0)),
            ]
        }

        @MainActor
        private func notes(in conv: String, of session: AppSession, with voice: VoiceNotes) -> [JSONValue] {
            session.stores.messages.messages(in: conv).compactMap { message -> JSONValue? in
                guard let note = message.attachment, VoiceAudio.isVoice(note.mime) else {
                    return nil
                }
                let plaintext = session.attachment(note.hash, key: note.key)
                return .object([
                    "id": .string(message.id),
                    "hash": .string(note.hash.string),
                    "mime": note.mime.map(JSONValue.string) ?? .null,
                    "sealed": .bool(note.key != nil),
                    "held": .bool(session.stores.blobs.contains(note.hash)),
                    "opens": .bool(plaintext != nil),
                    "decodes": .bool(plaintext.flatMap(voice.decoder.runs(of:)) != nil),
                    "plays": .bool(plaintext.map(VoiceProbe.plays) ?? false),
                    "durationMs": note.voice?.durationMs.map { .int(Int64($0)) } ?? .null,
                    "bars": note.voice?.peaks.map { .string(Base64.encode($0)) } ?? .null,
                ])
            }
        }
    }
#endif
