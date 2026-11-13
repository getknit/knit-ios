#if os(iOS) && DEBUG
    import Foundation
    import KnitBLE
    import KnitControl
    import KnitMesh

    /// `{"cmd":"skip-unpublish"}`: leaves the radio's next unpublish of its L2CAP listener unsent, with its deadline still
    /// armed, so the next mesh stop's wait runs out and the radio recycles its peripheral manager (``BLERadio/skipNextUnpublish()``,
    /// knit/knit-ios#53). Only the iPhone's radio has a listener that answers late, so the bridge answers it rather than
    /// ``MeshControl``. The reply says how many recycles this process has spent, and the PSM the listener holds.
    internal struct SkipUnpublishCommand: Decodable {
        static let name = "skip-unpublish"

        let cmd: String
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// Arms the skip on `radio`, and answers with its listener as it then stands.
        func answer(_ radio: BLERadio?) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            guard let radio else {
                reply["ok"] = false
                reply["error"] = "this build has no Bluetooth radio"
                return JSONValue.object(reply).line
            }
            let listener = await radio.skipNextUnpublish()
            reply["ok"] = true
            reply["armed"] = true
            reply["recycles"] = .int(Int64(listener.recycles))
            reply["maximumRecycles"] = .int(Int64(ListenerPublication.maximumRecycles))
            reply["recycling"] = .bool(listener.recycling)
            reply["listenerPSM"] = listener.psm.map { JSONValue.int(Int64($0)) } ?? .null
            return JSONValue.object(reply).line
        }
    }
#endif
