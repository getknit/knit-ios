#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitWire
    import Observation
    import UIKit

    /// The photos faces and threads draw, decoded from the blob store off the main actor and kept by hash and size. View
    /// state carries only hashes, so this is where an image lives. A size is rounded up to a power of two, so the faces
    /// of one person at 36 to 96 points share one decode of their 256-pixel photo. A photo sealed in a DM or a group is
    /// opened here, in memory, with the key its message carried, and only the decoded image is kept. A message's photo
    /// stands at the size its message stores, read as its bytes landed (ADR 2026-10.6cas).
    @MainActor
    @Observable
    internal final class BlobImageCache {
        /// The smallest size decoded, in pixels.
        private static let smallest = 64
        /// What the decoded images may take, in bytes, before the oldest go: 128 faces of 256 pixels, or a dozen of a
        /// thread's photos at 1024, more than any screen shows at once.
        private static let budget = photosKept * ProfilePhoto.side * ProfilePhoto.side * bytesPerPixel
        private static let photosKept = 128
        private static let bytesPerPixel = 4
        private static let growth = 2
        /// What the moving photos kept may weigh, as bytes rather than frames, half the stills' budget: a player decodes its
        /// own frames as they fall due. Android sends no GIF past 480 pixels, so a few dozen fit.
        private static let animationBudget = budget / growth
        /// How many answers about moving photos are kept, stills among them.
        private static let animationsKept = 256

        /// One decode: a photo at one size, opened with the key a sealed one needs. A message names its blob's key, so two
        /// messages naming one blob with different keys never share a decode.
        private struct Key: Hashable {
            var hash: BlobHash
            var side: Int
            var secret: String?
        }

        @ObservationIgnored private let session: AppSession
        @ObservationIgnored private var images: [Key: UIImage] = [:]
        /// The keys held, least recently used first.
        @ObservationIgnored private var order: [Key] = []
        @ObservationIgnored private var held = 0
        @ObservationIgnored private var decoding: [Key: Task<UIImage?, Never>] = [:]
        /// The moving photos read, by hash and key, least recently used first; `nil` for one that turned out still or too
        /// large to play, so it is not read again.
        @ObservationIgnored private var animations: [Key: AnimatedPhoto?] = [:]
        @ObservationIgnored private var animationOrder: [Key] = []
        @ObservationIgnored private var animationsHeld = 0
        @ObservationIgnored private var reading: [Key: Task<AnimatedPhoto??, Never>] = [:]

        /// Photos from `session`'s blob store.
        init(session: AppSession) {
            self.session = session
        }

        /// The photo `hash`, no larger than `pixels` on its long side, or `nil` when its bytes are missing or are no image
        /// a face may show. `unsaved` stands in for the store, for a photo picked and not yet saved or sent.
        func image(_ hash: BlobHash, pixels: Int, unsaved: [UInt8]?) async -> UIImage? {
            await image(Key(hash: hash, side: Self.bucket(pixels)), unsaved: unsaved)
        }

        /// A message's photo, opened with `key` when it is sealed, no larger than `pixels` on its long side; `nil` when its
        /// bytes are missing, the key does not open them, or they are no image a thread may show.
        func attachment(_ hash: BlobHash, key: String?, pixels: Int) async -> UIImage? {
            await image(Key(hash: hash, side: Self.bucket(pixels), secret: key), unsaved: nil)
        }

        /// A message's photo as it moves, opened with `key` when it is sealed, for a player to decode frame by frame; `nil`
        /// when its bytes are missing, the key does not open them, or it is still or too large to play. `unsaved` stands in
        /// for the store, for a photo picked and not yet sent.
        func animation(_ hash: BlobHash, key secret: String?, unsaved: [UInt8]?) async -> AnimatedPhoto? {
            let key = Key(hash: hash, side: 0, secret: secret)
            if let known = animations[key] {
                animationOrder.removeAll { $0 == key }
                animationOrder.append(key)
                return known
            }
            if let pending = reading[key] {
                return await pending.value.flatMap(\.self)
            }
            let source = session
            let task = Task { await Self.animation(key, unsaved: unsaved, session: source) }
            reading[key] = task
            let read = await task.value
            reading[key] = nil
            // Bytes still missing, or a key that does not open them yet, are asked about again.
            guard let animation = read else {
                return nil
            }
            keep(animation, as: key)
            return animation
        }

        private func keep(_ animation: AnimatedPhoto?, as key: Key) {
            guard animations.updateValue(animation, forKey: key) == nil else {
                return
            }
            animationOrder.append(key)
            animationsHeld += animation?.cost ?? 0
            while animationsHeld > Self.animationBudget || animationOrder.count > Self.animationsKept, animationOrder.count > 1 {
                let oldest = animationOrder.removeFirst()
                animationsHeld -= animations.removeValue(forKey: oldest)??.cost ?? 0
            }
        }

        /// A message's photo as it was sent, opened with `key` when it is sealed, for Save: read off the main actor, and
        /// only when it is an image a thread may show.
        func original(_ hash: BlobHash, key: String?) async -> Data? {
            await Self.original(hash, key: key, session: session)
        }

        private func image(_ key: Key, unsaved: [UInt8]?) async -> UIImage? {
            if let image = images[key] {
                order.removeAll { $0 == key }
                order.append(key)
                return image
            }
            if let pending = decoding[key] {
                return await pending.value
            }
            let source = session
            let task = Task { await Self.decode(key, unsaved: unsaved, session: source) }
            decoding[key] = task
            let image = await task.value
            decoding[key] = nil
            if let image {
                keep(image, as: key)
            }
            return image
        }

        private func keep(_ image: UIImage, as key: Key) {
            guard images.updateValue(image, forKey: key) == nil else {
                return
            }
            order.append(key)
            held += Self.cost(of: image)
            while held > Self.budget, order.count > 1 {
                let oldest = order.removeFirst()
                held -= images.removeValue(forKey: oldest).map(Self.cost(of:)) ?? 0
            }
        }

        private static func cost(of image: UIImage) -> Int {
            image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        }

        /// `pixels` rounded up to a power of two, at least ``smallest``.
        private static func bucket(_ pixels: Int) -> Int {
            var side = smallest
            while side < pixels, side <= Int.max / growth {
                side *= growth
            }
            return side
        }

        @concurrent
        nonisolated private static func decode(_ key: Key, unsaved: [UInt8]?, session: AppSession) async -> UIImage? {
            guard let bytes = unsaved ?? session.attachment(key.hash, key: key.secret),
                let image = PhotoDecoder.thumbnail(
                    Data(bytes), side: key.side, types: PhotoDecoder.meshTypes, pixels: PhotoDecoder.meshPixels)
            else {
                return nil
            }
            return UIImage(cgImage: image)
        }

        @concurrent
        /// The photo `key` names as it moves: `nil` while its bytes are missing or do not open, and `.some(nil)` for one
        /// that is still or too large to play.
        nonisolated private static func animation(_ key: Key, unsaved: [UInt8]?, session: AppSession) async -> AnimatedPhoto?? {
            (unsaved ?? session.attachment(key.hash, key: key.secret)).map { PhotoDecoder.animation(Data($0)) }
        }

        @concurrent
        nonisolated private static func original(_ hash: BlobHash, key: String?, session: AppSession) async -> Data? {
            session.attachmentToSave(hash, key: key).map { Data($0) }.flatMap { PhotoDecoder.isMeshPhoto($0) ? $0 : nil }
        }
    }
#endif
