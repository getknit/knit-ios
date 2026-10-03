#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitWire
    import Observation
    import UIKit

    /// The photos faces and threads draw, decoded from the blob store off the main actor and kept by hash and size. View
    /// state carries only hashes, so this is where an image lives. A size is rounded up to a power of two, so the faces
    /// of one person at 36 to 96 points share one decode of their 256-pixel photo. A photo sealed in a DM or a group is
    /// opened here, in memory, with the key its message carried, and only the decoded image is kept.
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
        nonisolated private static func original(_ hash: BlobHash, key: String?, session: AppSession) async -> Data? {
            session.attachment(hash, key: key).map { Data($0) }.flatMap { PhotoDecoder.isMeshPhoto($0) ? $0 : nil }
        }
    }
#endif
