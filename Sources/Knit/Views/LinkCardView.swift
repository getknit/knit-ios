#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// A link's preview card in a bubble (`LinkPreviewCard` in knit-next, ADR 2026-11.hcvg): the picture the sender's
    /// phone fetched when the card has one, the page's title and description, and the host the link points at, drawn from
    /// the card and never from the page again. A tap opens the link.
    ///
    /// Someone else's card is screened before it is drawn, its picture and words as one verdict, and draws nothing until
    /// then; one the content filter hides waits whole behind a tap, as a photo does. A card that has not opened draws
    /// nothing at all, since the link in the words is tappable meanwhile. VoiceOver reads it as part of its row, whose
    /// actions open the link.
    internal struct LinkCardView: View {
        /// What is drawn: the card, under the filter as it stands, so turning the filter on screens what shows.
        private struct Drawing: Equatable {
            var card: LinkCard
            var filters: Bool
        }

        let card: LinkCard
        /// Whether we sent it: the content filter never hides our own.
        let isMine: Bool
        /// Whether the content filter hides it until a tap.
        let covered: Bool
        /// Shows a hidden card.
        let reveal: () -> Void
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?
        @Environment(\.displayScale) private var scale
        @Environment(\.openURL) private var openURL
        /// The card the filter has seen, so a row reused for another card draws nothing until that one is screened too.
        @State private var screened: LinkCard?
        /// The picture read, with the card it belongs to.
        @State private var picture: (card: LinkCard, image: UIImage)?
        /// The card whose picture did not open: its well stays, empty, as Android's does.
        @State private var unreadable: LinkCard?

        var body: some View {
            Group {
                if covered {
                    HiddenCard(reveal: reveal)
                } else if screened == card {
                    Button {
                        if let url = URL(string: card.url) {
                            openURL(url)
                        }
                    } label: {
                        CardFace(card: card, picture: picture?.card == card ? picture?.image : nil, reading: unreadable != card)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.LinkPreviews.card(title: card.title, host: card.host))
                    .accessibilityIdentifier(AccessibilityID.chatLinkCard)
                } else {
                    // A view of no size while the filter looks: a Group with nothing in it never appears, so the task
                    // below would never run and the card would wait for good.
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .task(id: Drawing(card: card, filters: screening?.filtersContent ?? false)) {
                // Screened first, so a card the filter would hide is never drawn before it has seen it.
                _ = await screening?.hides(card: card, isMine: isMine)
                screened = card
                guard card.hasImage, picture?.card != card else {
                    return
                }
                let pixels = Int((Layout.linkCardWidth * scale).rounded(.up))
                if let image = await photos?.picture(of: card, pixels: pixels) {
                    picture = (card, image)
                } else {
                    unreadable = card
                }
            }
        }
    }

    /// The card itself: its picture across the top, cropped to fill, then the title, the description and the host.
    private struct CardFace: View {
        let card: LinkCard
        let picture: UIImage?
        /// Whether the picture may still come: a spinner shows until it does or fails.
        let reading: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if card.hasImage {
                    CardPicture(picture: picture, reading: reading)
                }
                VStack(alignment: .leading, spacing: Layout.hairline) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(Self.titleLines)
                    if let description = card.description {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(Self.descriptionLines)
                    }
                    // The host reads left to right whatever the page's language, so an address never mirrors.
                    Text(card.host)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                        .padding(.top, Layout.hairline)
                }
                .multilineTextAlignment(.leading)
                .padding(Layout.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: Layout.linkCardWidth)
            .background(Palette.incomingBubble)
            .clipShape(.rect(cornerRadius: Layout.photoCorner))
            .contentShape(.rect(cornerRadius: Layout.photoCorner))
        }

        /// The most lines the title takes, and the description (Android's 2 and 3).
        private static let titleLines = 2
        private static let descriptionLines = 3
    }

    /// A card's picture across its top, cropped to fill, over a well with a spinner while it decodes. A picture that does
    /// not open leaves the well empty (`CardPicture`'s `onError` in knit-next).
    private struct CardPicture: View {
        let picture: UIImage?
        let reading: Bool

        var body: some View {
            ZStack {
                Palette.secondaryText.opacity(Self.well)
                if let picture {
                    // The card's label names it; the picture adds nothing VoiceOver can read.
                    // swiftlint:disable:next accessibility_label_for_image
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .accessibilityIgnoresInvertColors()
                } else if reading {
                    ProgressView()
                }
            }
            .frame(width: Layout.linkCardWidth, height: Layout.linkCardPicture)
            .clipped()
        }

        /// How strongly the well under a picture still decoding shows.
        private static let well = 0.15
    }

    /// What a hidden card shows until it is tapped (`HiddenCard` in knit-next): a glyph over a line that says why. The line
    /// is decorative to VoiceOver, which hears the row's value and offers Show link preview instead.
    private struct HiddenCard: View {
        let reveal: () -> Void

        var body: some View {
            Button(action: reveal) {
                VStack(spacing: Layout.small) {
                    Image(systemName: "eye.slash")
                    Text(Copy.LinkPreviews.hidden)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Palette.secondaryText)
                .padding(.vertical, Layout.large)
                .padding(.horizontal, Layout.medium)
                .frame(width: Layout.linkCardWidth)
                .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.photoCorner))
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            .accessibilityIdentifier(AccessibilityID.chatLinkCardHidden)
        }
    }
#endif
