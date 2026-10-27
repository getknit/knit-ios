#if os(iOS)
    import KnitAppCore
    import KnitMesh
    import KnitStore
    import KnitWire
    import SwiftUI

    /// What a message carries beside its words, in its bubble (`AttachmentImage` in knit-next's `ChatScreen.kt`): a photo,
    /// which opens the viewer, or a voice message or a file, which this build names and cannot open.
    internal struct AttachmentView: View {
        let attachment: ChatAttachment
        /// Whether we sent it: the content filter never hides our own.
        let isMine: Bool
        /// Whether the content filter hides the photo until a tap (ADR 2026-10.rpmq).
        let covered: Bool
        /// Shows a hidden photo.
        let reveal: () -> Void
        let open: () -> Void

        var body: some View {
            switch attachment.kind {
            case .photo:
                MessagePhoto(attachment: attachment, isMine: isMine, covered: covered, reveal: reveal, open: open)
            case .voice, .file:
                AttachmentTile(attachment: attachment)
            case .link:
                // A thread never holds one: a link's card shows nothing the link in the text does not.
                EmptyView()
            }
        }
    }

    /// A message's photo: the picture once its bytes are here, at its own shape, playing when it moves; until then a
    /// placeholder that says why it waits; and a line that says so when the bytes do not open, which a wrong key, a
    /// damaged blob or a type this build cannot read leaves behind. Someone else's photo is screened before it is drawn,
    /// on its first frame as Android screens it, and one the content filter hides waits behind a tap (`AttachmentImage`
    /// in knit-next).
    private struct MessagePhoto: View {
        /// What is drawn: the photo, under the filter as it stands, so turning the filter on screens what shows.
        private struct Drawing: Equatable {
            var attachment: ChatAttachment
            var filters: Bool
        }

        let attachment: ChatAttachment
        let isMine: Bool
        let covered: Bool
        let reveal: () -> Void
        let open: () -> Void
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?
        @Environment(\.displayScale) private var scale
        @State private var image: UIImage?
        @State private var animation: AnimatedPhoto?
        @State private var failed = false

        var body: some View {
            // The photo's own shape, read from its bytes as they landed. A spinner or a hidden photo holds it, so a row
            // keeps its height from its first frame, and nothing around it moves as the photo decodes.
            let place = attachment.dimensions.map { Self.frame(for: CGSize(width: $0.width, height: $0.height)) }
            Group {
                if covered {
                    HiddenPhoto(place: place, reveal: reveal)
                } else if let waits = attachment.waits {
                    HeldBackPhoto(waits: waits)
                } else if let image {
                    // The stored shape where there is one: a thumbnail's sides are rounded, and the row would shift a hair.
                    let size = place ?? Self.frame(for: image.size)
                    Button(action: open) {
                        FilledPhoto(image: image, animation: animation, pixels: pixels)
                            .frame(width: size.width, height: size.height)
                            .clipShape(.rect(cornerRadius: Layout.photoCorner))
                            .accessibilityIgnoresInvertColors()
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
                        .frame(width: place?.width ?? Layout.photoWidth, height: place?.height ?? Layout.photoPlaceholder)
                } else {
                    WaitingPhoto(hash: attachment.hash)
                }
            }
            .task(id: Drawing(attachment: attachment, filters: screening?.filtersContent ?? false)) {
                guard attachment.isHeld else {
                    return
                }
                // Screened first, so an explicit photo is never drawn before the filter has seen it.
                _ = await screening?.hides(attachment, isMine: isMine)
                let decoded = await photos?.attachment(attachment.hash, key: attachment.key, pixels: pixels)
                image = decoded
                failed = decoded == nil
                // Only a photo read as moving is read again for its frames, so a still costs nothing more.
                let moves = decoded != nil && attachment.dimensions?.animated == true
                animation = moves ? await photos?.animation(attachment.hash, key: attachment.key, unsaved: nil) : nil
            }
        }

        /// The most pixels the photo is decoded at, on its long side.
        private var pixels: Int {
            Int((Layout.photoWidth * scale).rounded(.up))
        }

        /// The size a photo of `pixels` takes: ``Layout/photoWidth`` wide, unless that would stand it taller than
        /// ``Layout/photoMaxHeight``, which then caps it.
        private static func frame(for pixels: CGSize) -> CGSize {
            let aspect = pixels.width / max(pixels.height, 1)
            let height = min(Layout.photoWidth / max(aspect, .ulpOfOne), Layout.photoMaxHeight)
            return CGSize(width: height * aspect, height: height)
        }
    }

    /// A photo drawn to fill its frame: playing when it moves, its first frame otherwise.
    private struct FilledPhoto: View {
        let image: UIImage
        let animation: AnimatedPhoto?
        /// The most pixels a moving photo's frames are decoded at, on their long side.
        let pixels: Int

        var body: some View {
            if let animation {
                AnimatedPhotoView(photo: animation, poster: image, pixels: pixels, fills: true)
            } else {
                // The caller names the photo: the bubble's button, or the composer's element.
                // swiftlint:disable:next accessibility_label_for_image
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
    }

    /// A photo the engine does not fetch until something changes (knit-ios #21, ADR 2026-10.vzem): a message request's,
    /// until it is accepted, or a stranger's Nearby photo past the bound on strangers' photos. A still glyph, since nothing
    /// is on its way.
    private struct HeldBackPhoto: View {
        let waits: AttachmentWait

        var body: some View {
            PhotoPlaceholder(text: waits == .accept ? Copy.Attachments.photoAwaitsAccept : Copy.Attachments.photoPastRoomBound) {
                Image(systemName: waits == .accept ? "hand.raised" : "photo.badge.exclamationmark")
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier(AccessibilityID.chatAttachmentHeldBack)
        }
    }

    /// A photo still on its way. While a link brings its bytes, a ring fills over how much of how much is in, or, from a
    /// sender that declared no size, a still arrow over how much is in (`ArrivalIndicator`, ADR 2026-10.y9qh). Until then,
    /// Knit's stitches while its arrival is likely, and an hourglass after ``Layout/photoPatience`` seconds
    /// (`WaitingIndicator.kt`), over the line that says what it waits for. The box keeps that line's height throughout,
    /// so the row neither shrinks when bytes start nor grows back if they stop.
    private struct WaitingPhoto: View {
        let hash: BlobHash
        @State private var stalled = false
        @Environment(PhotoArrivals.self) private var arrivals: PhotoArrivals?

        var body: some View {
            let arrival = arrivals?[hash]
            PhotoPlaceholder(text: arrival?.caption ?? Copy.Attachments.photoWaiting, reserving: Copy.Attachments.photoWaiting) {
                if let arrival {
                    if let fraction = arrival.fraction {
                        ArrivalRing(fraction: fraction)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .accessibilityHidden(true)
                    }
                } else if stalled {
                    Image(systemName: "hourglass")
                        .accessibilityHidden(true)
                } else {
                    StitchIndicator()
                }
            }
            .monospacedDigit()
            .accessibilityIdentifier(arrival == nil ? AccessibilityID.chatAttachmentWaiting : AccessibilityID.chatAttachmentArriving)
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

    /// A photo the content filter hides, in the place it would take once known, until a tap shows it (ADR 2026-10.rpmq).
    private struct HiddenPhoto: View {
        let place: CGSize?
        let reveal: () -> Void

        var body: some View {
            Button(action: reveal) {
                PhotoPlaceholder(text: Copy.Moderation.hiddenPhoto, place: place) {
                    Image(systemName: "eye.slash")
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.chatAttachmentHidden)
        }
    }

    /// The square a photo shows until it can, or the photo's own shape when that is known: a glyph, which is decorative,
    /// over a line that says why. A line it may swap to, `reserving`, holds its height, laid out unseen behind it.
    private struct PhotoPlaceholder<Glyph: View>: View {
        let text: String
        var place: CGSize?
        var reserving: String?
        @ViewBuilder let glyph: Glyph

        var body: some View {
            VStack(spacing: Layout.small) {
                glyph
                    .accessibilityHidden(true)
                ZStack {
                    if let reserving {
                        Self.line(reserving)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    Self.line(text)
                }
            }
            .padding(Layout.medium)
            .frame(width: place?.width ?? Layout.photoPlaceholder)
            .frame(minHeight: place?.height ?? Layout.photoPlaceholder)
            .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.photoCorner))
            .accessibilityElement(children: .combine)
        }

        /// `text` in the box's caption, on every line it needs: the photo's height below is a floor, and the stack would
        /// otherwise share it out, cutting the line short at the largest sizes ("Sensitive photo. Ta…"). The place grows
        /// instead.
        private static func line(_ text: String) -> some View {
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
            .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.bubbleCorner))
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
        @State private var animation: AnimatedPhoto?

        var body: some View {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        // A picked GIF plays as it will in the thread, so the sender sees what goes.
                        FilledPhoto(image: image, animation: animation, pixels: pixels)
                            .accessibilityIgnoresInvertColors()
                    } else {
                        Palette.incomingBubble
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
                image = await photos?.image(staged.hash, pixels: pixels, unsaved: staged.photo.bytes)
                animation = await photos?.animation(staged.hash, key: nil, unsaved: staged.photo.bytes)
            }
        }

        /// The most pixels the photo is decoded at, on its long side.
        private var pixels: Int {
            Int((Layout.stagedPhoto * scale).rounded(.up))
        }
    }
#endif
