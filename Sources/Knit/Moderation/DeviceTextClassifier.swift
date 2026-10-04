#if os(iOS)
    import CoreML
    import Foundation
    import KnitAppCore
    import KnitMesh

    /// The content filter's text classifier (ADR 2026-10.e4kz): Detoxify's `unbiased-small`, the ALBERT model Knit for
    /// Android ships as `toxicity.tflite`, rebuilt from its checkpoint as a float16 Core ML program by
    /// `tools/models/toxicity/` and bundled as `Toxicity.mlmodelc`, with Android's tokenizer as `ToxicityTokenizer.json`.
    ///
    /// A message is read as Android reads it (`MlTextModerator.infer`): `[CLS]`, its SentencePiece ids, `[SEP]`, padded
    /// to 128 with a mask over the real tokens. The model loads on the first message and runs on the CPU and the Neural
    /// Engine, never the GPU, which iOS denies an app in the background, where messages arrive too. It lets go ten
    /// minutes after its last message at the front (Android's `ModelLease`), a few seconds after it in the background, so
    /// a suspended Knit holds none of it, and at once when memory runs low. One that fails to load stays failed until
    /// Knit starts again, and every message then goes through, as Android's does.
    internal actor DeviceTextClassifier: TextClassifier {
        /// Tokens per message, `[CLS]` and `[SEP]` included (`MlTextModerator.DEFAULT_MAX_LEN`).
        private static let length = 128
        /// How long the model stays after its last message, in seconds, at the front and in the background.
        private static let idleSeconds = 600
        private static let backgroundIdleSeconds = 5

        private struct Engine {
            let model: MLModel
            let tokenizer: SentencePieceTokenizer
        }

        private enum State {
            case unloaded
            case loaded(Engine)
            case failed
        }

        private var state = State.unloaded
        private var inBackground = false
        /// Counts the messages read, so a release scheduled after one is dropped if another came since.
        private var reads = 0
        private let log: any KnitLog

        /// The bundled classifier, which reports what goes wrong to `log`.
        init(log: any KnitLog) {
            self.log = log
        }

        func scores(of text: String) -> [Float]? {
            guard let engine = engine() else {
                return nil
            }
            defer { releaseWhenIdle() }
            let (ids, mask) = engine.tokenizer.encode(text, length: Self.length)
            guard let tokens = Self.input(ids), let attention = Self.input(mask) else {
                return nil
            }
            do {
                let features = try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: tokens), "attention_mask": MLFeatureValue(multiArray: attention),
                ])
                guard let scores = try engine.model.prediction(from: features).featureValue(for: "scores")?.multiArrayValue else {
                    log.log(.warning, "text classifier: no scores in its output")
                    return nil
                }
                return (0..<scores.count).map { scores[$0].floatValue }
            } catch {
                log.log(.warning, "text classifier: prediction failed: \(error)")
                return nil
            }
        }

        /// Knit went to the background or came back: the model is let go sooner there.
        func setInBackground(_ background: Bool) {
            inBackground = background
            if background {
                releaseWhenIdle()
            }
        }

        /// Lets the model go; the next message loads it again.
        func release() {
            if case .loaded = state {
                state = .unloaded
            }
        }

        private func releaseWhenIdle() {
            reads += 1
            let read = reads
            let wait = inBackground ? Self.backgroundIdleSeconds : Self.idleSeconds
            Task {
                try? await Task.sleep(for: .seconds(wait))
                releaseIfUnread(since: read)
            }
        }

        private func releaseIfUnread(since read: Int) {
            if read == reads {
                release()
            }
        }

        private func engine() -> Engine? {
            switch state {
            case .loaded(let engine):
                return engine
            case .failed:
                return nil
            case .unloaded:
                break
            }
            guard let modelURL = Bundle.main.url(forResource: "Toxicity", withExtension: "mlmodelc"),
                let tokenizerURL = Bundle.main.url(forResource: "ToxicityTokenizer", withExtension: "json")
            else {
                log.log(.warning, "text classifier: Toxicity.mlmodelc or its tokenizer is not in the app, so no message is screened")
                state = .failed
                return nil
            }
            guard let tokenizer = (try? Data(contentsOf: tokenizerURL)).flatMap(SentencePieceTokenizer.init(json:)) else {
                log.log(.warning, "text classifier: the tokenizer did not load, so no message is screened")
                state = .failed
                return nil
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            do {
                let engine = Engine(model: try MLModel(contentsOf: modelURL, configuration: configuration), tokenizer: tokenizer)
                state = .loaded(engine)
                return engine
            } catch {
                log.log(.warning, "text classifier: the model did not load, so no message is screened: \(error)")
                state = .failed
                return nil
            }
        }

        /// `values` as one of the model's `[1, 128]` int32 inputs.
        private static func input(_ values: [Int32]) -> MLMultiArray? {
            // swiftlint:disable:next legacy_objc_type - Core ML takes a shape as NSNumbers.
            guard let array = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else {
                return nil
            }
            array.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
                for (index, value) in values.enumerated() {
                    buffer[index] = value
                }
            }
            return array
        }
    }
#endif
