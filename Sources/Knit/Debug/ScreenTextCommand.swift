#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitControl

    /// `{"cmd":"screen-text","text":"…"}`: what the content filter's model scores a message (ADR 2026-10.e4kz). `scores`
    /// are the sixteen labels in model order, as decimal strings since a control line carries no fractions, or `null` when
    /// the model is missing; `blocks` names the enforced label past its line, or is `null`. The word list and the
    /// positions taken out are left aside: this is the model alone, which `tools/models/toxicity/parity.py` checks too.
    internal struct ScreenTextCommand: Decodable {
        static let name = "screen-text"

        let cmd: String
        let text: String
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// What `classifier` scores the text.
        func answer(_ classifier: any TextClassifier) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name), "ok": true]
            if let tag {
                reply["tag"] = .string(tag)
            }
            let scores = await classifier.scores(of: text)
            reply["labels"] = .array(AbusiveText.labels.map(JSONValue.string))
            reply["scores"] = scores.map { .array($0.map { .string(Self.decimal($0)) }) } ?? .null
            reply["blocks"] = scores.flatMap(AbusiveText.blockingLabel).map(JSONValue.string) ?? .null
            return JSONValue.object(reply).line
        }

        private static func decimal(_ value: Float) -> String {
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        }
    }
#endif
