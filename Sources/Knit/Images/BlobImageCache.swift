#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitWire
    import Observation
    import UIKit

    /// The photos faces draw, decoded from the blob store off the main actor and kept by hash and size. View state
    /// carries only hashes, so this is where an image lives. A size is rounded up to a power of two, so the faces of
    /// one person at 36 to 96 points share one decode of their 256-pixel photo.
    @MainActor
    @Observable
    internal final class BlobImageCache {
        /// The smallest size decoded, in pixels.
        private static let smallest = 64
        /// What the decoded images may take, in bytes, before the oldest go: 64 photos of 256 pixels, more than any
        /// screen shows at once.
        private static let budget = photosKept * ProfilePhoto.side * ProfilePhoto.side * bytesPerPixel
        private static let photosKept = 64
        private static let bytesPerPixel = 4
        private static let growth = 2

        /// One decode: a photo at one size.
        private struct Key: Hashable {
            var hash: BlobHash
            var side: Int
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
        /// a face may show. `unsaved` stands in for the store, for a photo picked and not yet saved.
        func image(_ hash: BlobHash, pixels: Int, unsaved: [UInt8]?) async -> UIImage? {
            let key = Key(hash: hash, side: Self.bucket(pixels))
            if let image = images[key] {
                order.removeAll { $0 == key }
                order.append(key)
                return image
            }
            if let pending = decoding[key] {
                return await pending.value
            }
            let source = session
            let task = Task { await Self.decode(hash, side: key.side, unsaved: unsaved, session: source) }
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
        nonisolated private static func decode(_ hash: BlobHash, side: Int, unsaved: [UInt8]?, session: AppSession) async -> UIImage? {
            guard let bytes = unsaved ?? session.photo(hash),
                let image = PhotoDecoder.thumbnail(Data(bytes), side: side, types: PhotoDecoder.meshTypes, pixels: PhotoDecoder.meshPixels)
            else {
                return nil
            }
            return UIImage(cgImage: image)
        }
    }
#endif
