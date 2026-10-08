#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// What the viewer shows: someone's profile photo, or a photo from a chat, which Save can add to the library.
    internal struct ViewedPhoto: Identifiable, Hashable {
        /// The blob.
        var hash: BlobHash
        /// The key that opens a photo sealed in a DM or a group.
        var key: String?
        /// The bar's title: whose photo it is, or who sent it.
        var title: String
        /// What VoiceOver calls the photo.
        var label: String
        /// Whether Save is offered: for a chat's photo, not a profile's.
        var savable: Bool

        var id: Self { self }

        /// `photo`, the profile photo of whoever `title` names.
        static func profile(_ photo: BlobHash, title: String) -> Self {
            Self(hash: photo, key: nil, title: title, label: Copy.Photo.profilePhoto, savable: false)
        }

        /// A chat's photo `attachment`, sent by whoever `sender` names.
        static func chat(_ attachment: ChatAttachment, sender: String) -> Self {
            Self(hash: attachment.hash, key: attachment.key, title: sender, label: Copy.Attachments.photo, savable: true)
        }
    }

    /// A photo full screen on black, until Done (`profile_details_view_photo` and the chat's `FullscreenImage` in
    /// knit-next). A chat's photo has Save, which adds it to the library as it was sent.
    internal struct PhotoViewer: View {
        /// The size the viewer decodes at: past any photo the mesh carries, which is 1280 pixels at most on its long side,
        /// so it shows one whole. A moving photo's frames are decoded at it too.
        static let pixels = 2048
        /// How long the line that says how Save went stays, in seconds.
        private static let resultShown = 3

        let photo: ViewedPhoto
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?
        @Environment(\.dismiss) private var dismiss
        @State private var image: UIImage?
        @State private var animation: AnimatedPhoto?
        @State private var saving = false
        @State private var result: String?

        var body: some View {
            NavigationStack {
                ViewerStage(image: image, animation: animation, label: photo.label, result: result)
                    .navigationTitle(photo.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.black, for: .navigationBar, .bottomBar)
                    .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
                    .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
                    .toolbar { toolbar }
            }
            // A container of its own, so the screen's identifier leaves the photo and Done their own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.photoViewerScreen)
            .task(id: photo) {
                // A profile's photo, the kind Save is not offered for, stays dark when the content filter hides it as a
                // face. A chat's photo opens only once its bubble has shown it.
                if !photo.savable, await screening?.hidesFace(photo.hash) == true {
                    return
                }
                image = await photos?.attachment(photo.hash, key: photo.key, pixels: Self.pixels)
                // A chat's photo that moves plays here, as Android's viewer plays it; a profile's photo is always a still.
                if image != nil, photo.savable {
                    animation = await photos?.animation(photo.hash, key: photo.key, unsaved: nil)
                }
            }
        }

        /// Done, and Save for a chat's photo once it shows.
        @ToolbarContentBuilder private var toolbar: some ToolbarContent {
            ToolbarItem(placement: .confirmationAction) {
                Button(Copy.Common.done) { dismiss() }
            }
            if photo.savable {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await save() }
                    } label: {
                        Label(Copy.Attachments.save, systemImage: "square.and.arrow.down")
                    }
                    // White, as Done's label is: the accent's blue reads dim on the bar's dark glass.
                    .tint(.white)
                    .disabled(image == nil || saving)
                    .accessibilityIdentifier(AccessibilityID.photoViewerSave)
                }
            }
        }

        /// Adds the photo to the library as it was sent, and says how that went for a moment.
        private func save() async {
            saving = true
            defer { saving = false }
            let outcome: PhotoSaver.Outcome =
                if let data = await photos?.original(photo.hash, key: photo.key) {
                    await PhotoSaver.save(data)
                } else {
                    .failed
                }
            let said =
                switch outcome {
                case .saved:
                    Copy.Attachments.saved
                case .denied:
                    Copy.Attachments.saveDenied
                case .failed:
                    Copy.Attachments.saveFailed
                }
            result = said
            AccessibilityNotification.Announcement(said).post()
            try? await Task.sleep(for: .seconds(Self.resultShown))
            if result == said {
                result = nil
            }
        }
    }

    /// The photo on black, playing when it moves, and how Save went over its bottom.
    private struct ViewerStage: View {
        let image: UIImage?
        let animation: AnimatedPhoto?
        let label: String
        let result: String?

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image, let animation {
                    AnimatedPhotoView(photo: animation, poster: image, pixels: PhotoViewer.pixels, fills: false)
                        .aspectRatio(image.size, contentMode: .fit)
                        .accessibilityElement()
                        .accessibilityLabel(label)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIgnoresInvertColors()
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(label)
                        .accessibilityIgnoresInvertColors()
                }
            }
            .overlay(alignment: .bottom) {
                if let result {
                    SaveResult(text: result)
                }
            }
        }
    }

    /// How Save went, over the bottom of the photo.
    private struct SaveResult: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Layout.medium)
                .padding(.vertical, Layout.small)
                .background(Palette.viewerCaption, in: .rect(cornerRadius: Layout.bubbleCorner))
                .padding()
                .accessibilityIdentifier(AccessibilityID.photoViewerResult)
        }
    }
#endif
