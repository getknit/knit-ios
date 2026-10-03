#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// Someone's profile photo, full screen on black, until Done (`profile_details_view_photo` in knit-next).
    internal struct PhotoViewer: View {
        /// The size the viewer decodes at: past any profile photo, so it shows one whole.
        private static let pixels = 1024

        let photo: BlobHash
        let title: String
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(\.dismiss) private var dismiss
        @State private var image: UIImage?

        var body: some View {
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel(Copy.Photo.profilePhoto)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.Common.done) { dismiss() }
                    }
                }
            }
            // A container of its own, so the screen's identifier leaves the photo and Done their own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.photoViewerScreen)
            .task(id: photo) { image = await photos?.image(photo, pixels: Self.pixels, unsaved: nil) }
        }
    }
#endif
