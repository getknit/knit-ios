#if os(iOS)
    import KnitAppCore
    import KnitMesh
    import KnitWire
    import SwiftUI

    /// What a message carries beside its words, in its bubble (`AttachmentImage` in knit-next's `ChatScreen.kt`): a photo,
    /// which opens the viewer, or a voice message or a file, which this build names and cannot open.
    internal struct AttachmentView: View {
        let attachment: ChatAttachment
        let open: () -> Void

        var body: some View {
            switch attachment.kind {
            case .photo:
                MessagePhoto(attachment: attachment, open: open)
            case .voice, .file:
                AttachmentTile(attachment: attachment)
            case .link:
                // A thread never holds one: a link's card shows nothing the link in the text does not.
                EmptyView()
            }
        }
    }

    /// A message's photo: the picture once its bytes are here, at its own shape; until then a placeholder that says why
    /// it waits; and a line that says so when the bytes do not open, which a wrong key, a damaged blob or a type this
    /// build cannot read leaves behind.
    private struct MessagePhoto: View {
        let attachment: ChatAttachment
        let open: () -> Void
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(\.displayScale) private var scale
        @State private var image: UIImage?
        @State private var failed = false

        var body: some View {
            Group {
                if let image {
                    let size = Self.frame(for: image.size)
                    Button(action: open) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipShape(.rect(cornerRadius: Layout.photoCorner))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(attachment.label)
                } else if failed {
                    PhotoPlaceholder(text: Copy.Attachments.photoUnreadable) {
                        Image(systemName: "exclamationmark.triangle")
                            .accessibilityHidden(true)
                    }
                    .accessibilityIdentifier(AccessibilityID.chatAttachmentUnavailable)
                } else if attachment.isHeld {
                    // The bytes are here and decoding: the spinner holds the photo's place for the moment it takes.
                    ProgressView()
                        .frame(width: Layout.photoWidth, height: Layout.photoPlaceholder)
                } else {
                    WaitingPhoto(hash: attachment.hash)
                }
            }
            .task(id: attachment) {
                guard attachment.isHeld else {
                    return
                }
                let pixels = Int((Layout.photoWidth * scale).rounded(.up))
                let decoded = await photos?.attachment(attachment.hash, key: attachment.key, pixels: pixels)
                image = decoded
                failed = decoded == nil
            }
        }

        /// The size a photo of `pixels` takes: ``Layout/photoWidth`` wide, unless that would stand it taller than
        /// ``Layout/photoMaxHeight``, which then caps it.
        private static func frame(for pixels: CGSize) -> CGSize {
            let aspect = pixels.width / max(pixels.height, 1)
            let height = min(Layout.photoWidth / max(aspect, .ulpOfOne), Layout.photoMaxHeight)
            return CGSize(width: height * aspect, height: height)
        }
    }

    /// A photo still on its way: a spinner while its arrival is likely, and an hourglass after ``Layout/photoPatience``
    /// seconds (`WaitingIndicator.kt`), over the line that says what it waits for.
    private struct WaitingPhoto: View {
        let hash: BlobHash
        @State private var stalled = false

        var body: some View {
            PhotoPlaceholder(text: Copy.Attachments.photoWaiting) {
                if stalled {
                    Image(systemName: "hourglass")
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                }
            }
            .accessibilityIdentifier(AccessibilityID.chatAttachmentWaiting)
            .task(id: hash) {
                guard !stalled else {
                    return
                }
                try? await Task.sleep(for: .seconds(Layout.photoPatience))
                if !Task.isCancelled {
                    stalled = true
                }
            }
        }
    }

    /// The square a photo shows until it can: a glyph, which is decorative, over a line that says why.
    private struct PhotoPlaceholder<Glyph: View>: View {
        let text: String
        @ViewBuilder let glyph: Glyph

        var body: some View {
            VStack(spacing: Layout.small) {
                glyph
                    .accessibilityHidden(true)
                Text(text)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .padding(Layout.medium)
            .frame(width: Layout.photoPlaceholder)
            .frame(minHeight: Layout.photoPlaceholder)
            .background(.fill.tertiary, in: .rect(cornerRadius: Layout.photoCorner))
            .accessibilityElement(children: .combine)
        }
    }

    /// A voice message or a file from Android: its name, and that this build cannot open it.
    private struct AttachmentTile: View {
        let attachment: ChatAttachment

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Layout.medium) {
                Image(systemName: attachment.kind == .voice ? "waveform" : "doc")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Layout.hairline) {
                    Text(attachment.label)
                        .font(.subheadline.bold())
                    Text(attachment.kind == .voice ? Copy.Attachments.voiceUnsupported : Copy.Attachments.fileUnsupported)
                        .font(.caption)
                }
            }
            .padding(.horizontal, Layout.medium)
            .padding(.vertical, Layout.small)
            .frame(maxWidth: Layout.photoWidth, alignment: .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: Layout.bubbleCorner))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.chatAttachmentTile)
        }
    }

    /// The photo the composer holds, and the button that takes it out (`AttachmentPreview` in knit-next).
    internal struct StagedPhotoView: View {
        let staged: StagedPhoto
        let remove: () -> Void
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(\.displayScale) private var scale
        @State private var image: UIImage?

        var body: some View {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.clear.background(.fill.tertiary)
                    }
                }
                .frame(width: Layout.stagedPhoto, height: Layout.stagedPhoto)
                .clipShape(.rect(cornerRadius: Layout.photoCorner))
                .accessibilityElement()
                .accessibilityLabel(Copy.Attachments.stagedPhoto)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(AccessibilityID.chatStagedPhoto)
                Button(action: remove) {
                    Label(Copy.Attachments.removePhoto, systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        // A badge on a thumbnail of fixed size: at the accessibility sizes it would cover the photo.
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Palette.viewerCaption)
                        .frame(width: Layout.hitTarget, height: Layout.hitTarget, alignment: .topTrailing)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.chatRemovePhoto)
            }
            .task(id: staged.hash) {
                let pixels = Int((Layout.stagedPhoto * scale).rounded(.up))
                image = await photos?.image(staged.hash, pixels: pixels, unsaved: staged.photo.bytes)
            }
        }
    }
#endif
