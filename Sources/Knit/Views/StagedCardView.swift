#if os(iOS)
    import KnitAppCore
    import KnitCrypto
    import KnitWire
    import SwiftUI

    /// The card the composer holds for Send (`StagedLinkTile` in knit-next, ADR 2026-11.hcvg): its picture small, or a
    /// link's glyph when it has none, the page's title and its site, and a cross that sends the link without it.
    internal struct StagedCardView: View {
        let staged: LinkComposer.Staged
        let remove: () -> Void
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(\.displayScale) private var scale
        @State private var picture: UIImage?

        var body: some View {
            HStack(spacing: Layout.medium) {
                HStack(spacing: Layout.medium) {
                    thumbnail
                    VStack(alignment: .leading, spacing: Layout.hairline) {
                        Text(staged.blob.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(staged.blob.host)
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.LinkPreviews.staged(title: staged.blob.displayTitle, host: staged.blob.host))
                .accessibilityIdentifier(AccessibilityID.chatLinkStaged)
                Button(action: remove) {
                    Label(Copy.LinkPreviews.remove, systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Palette.viewerCaption)
                        .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.chatRemoveLinkCard)
            }
            .frame(maxWidth: Layout.stagedCardWidth, alignment: .leading)
            .task(id: staged.blob.url) {
                guard let image = staged.blob.image else {
                    picture = nil
                    return
                }
                let pixels = Int((Layout.stagedCardPicture * scale).rounded(.up))
                picture = await photos?.image(BlobHash(of: image), pixels: pixels, unsaved: image)
            }
        }

        /// The card's picture, or a link's glyph when it has none or it is still decoding.
        private var thumbnail: some View {
            ZStack {
                Palette.incomingBubble
                if let picture {
                    // The tile's label names the card.
                    // swiftlint:disable:next accessibility_label_for_image
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .accessibilityIgnoresInvertColors()
                } else {
                    Image(systemName: "link")
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Layout.stagedCardPicture, height: Layout.stagedCardPicture)
            .clipShape(.rect(cornerRadius: Layout.small))
        }
    }

    /// What the composer says while it fetches the draft's card (`chat_link_preview_loading`): a small spinner and a line.
    internal struct LinkLoadingLine: View {
        var body: some View {
            HStack(spacing: Layout.small) {
                ProgressView()
                    .controlSize(.small)
                Text(Copy.LinkPreviews.loading)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.chatLinkLoading)
        }
    }
#endif
