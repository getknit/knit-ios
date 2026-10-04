#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitControl
    import KnitWire

    /// `{"cmd":"screen","photo":"<base64>"}`: what the content filter's model scores a photo, read as a thread reads one
    /// (ADR 2026-10.rpmq). `scores` are the five classes in model order, as decimal strings since a control line carries
    /// no fractions, or `null` when the model is missing or cannot read the photo; `unsafe` is their sum the threshold is
    /// held to, and `explicit` the verdict. `tools/models/nsfw/score.py` scores the same photo with Android's model.
    internal struct ScreenCommand: Decodable {
        static let name = "screen"

        let cmd: String
        let photo: String
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// What `classifier` scores the photo.
        func answer(_ classifier: any PhotoClassifier) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            guard let bytes = Base64.decode(photo) else {
                reply["ok"] = false
                reply["error"] = "photo is not base64"
                return JSONValue.object(reply).line
            }
            let scores = await classifier.scores(of: bytes)
            reply["ok"] = true
            reply["classes"] = .array(ExplicitPhoto.classes.map(JSONValue.string))
            reply["scores"] = scores.map { .array($0.map { .string(Self.decimal($0)) }) } ?? .null
            reply["unsafe"] = scores.map { .string(Self.decimal(ExplicitPhoto.unsafeScore($0))) } ?? .null
            reply["explicit"] = .bool(scores.map(ExplicitPhoto.isExplicit) ?? false)
            return JSONValue.object(reply).line
        }

        private static func decimal(_ value: Float) -> String {
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        }
    }
#endif
