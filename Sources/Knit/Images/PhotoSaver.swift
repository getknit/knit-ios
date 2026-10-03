#if os(iOS)
    import Foundation
    import Photos

    /// Adds a photo from a chat to the library (`ChatViewModel.saveImage` in knit-next, which writes to Pictures/Knit).
    /// Knit asks only to add, never to read: the picker shares what is picked without any permission, so the library
    /// stays out of Knit's sight.
    internal enum PhotoSaver {
        /// How a save went.
        enum Outcome {
            /// The photo is in the library.
            case saved
            /// Knit may not add to the library.
            case denied
            /// The library refused it.
            case failed
        }

        /// Adds `data` to the library as a photo, asking for add-only access the first time.
        static func save(_ data: Data) async -> Outcome {
            switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
            case .authorized, .limited:
                break
            case .denied, .restricted, .notDetermined:
                return .denied
            @unknown default:
                return .denied
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                return .saved
            } catch {
                return .failed
            }
        }
    }
#endif
