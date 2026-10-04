#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// A face in a circle (`Avatar`, `GroupAvatar` and `RoomAvatar` in knit-next): a person's photo, or their initial on
    /// the tint their node id wears; a group's photo, its other members' faces, or a people glyph on its own tint; or the
    /// room's glyph. Decorative: the name beside it says who, so VoiceOver skips it.
    internal struct AvatarView: View {
        /// The seam between a cluster's cells, in points, at every size (`CLUSTER_GAP`).
        private static let clusterGap: CGFloat = 1.5
        /// A glyph's size as a fraction of the disc.
        private static let glyphFraction: CGFloat = 0.4

        let face: Face
        let size: CGFloat
        /// A photo picked and not yet saved, which the blob store does not hold: the own profile's.
        var unsaved: [UInt8]?

        var body: some View {
            content
                .frame(width: size, height: size)
                .clipShape(.circle)
                .accessibilityHidden(true)
        }

        @ViewBuilder private var content: some View {
            switch face.kind {
            case .person:
                PhotoOr(photo: face.photo, width: size, height: size, unsaved: unsaved) {
                    Initial(face: face, width: size, height: size)
                }
            case .group:
                PhotoOr(photo: face.photo, width: size, height: size) {
                    let cells = FaceCluster.cells(count: face.members.count, gap: Self.clusterGap / size)
                    if cells.isEmpty {
                        Glyph(symbol: "person.2.fill", tint: Palette.avatarTint(face.tint), size: size * Self.glyphFraction)
                    } else {
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(zip(cells.indices, cells)), id: \.0) { index, cell in
                                let member = face.members[index]
                                PhotoOr(photo: member.photo, width: size * cell.width, height: size * cell.height) {
                                    Initial(face: member, width: size * cell.width, height: size * cell.height)
                                }
                                .frame(width: size * cell.width, height: size * cell.height)
                                .clipped()
                                .offset(x: size * cell.left, y: size * cell.top)
                            }
                        }
                        .frame(width: size, height: size, alignment: .topLeading)
                    }
                }
            case .room:
                Glyph(symbol: "person.3.fill", tint: Palette.roomTint, size: size * Self.glyphFraction)
            }
        }
    }

    /// A face's initial on its tint, half the shorter side tall whatever the text size, since it has to fit its circle,
    /// and narrowed to fit when a wide emoji is the initial. It is drawn rather than set as text: a face is decorative,
    /// and the name beside it is the text.
    private struct Initial: View {
        /// The initial's height as a fraction of the shorter side (`INITIAL_FRACTION`).
        private static let fraction: CGFloat = 0.5
        /// Half of anything.
        private static let half: CGFloat = 0.5

        let face: Face
        let width: CGFloat
        let height: CGFloat

        var body: some View {
            let tint = Palette.avatarTint(face.tint)
            let letter = Text(verbatim: face.initial)
                .font(.system(size: min(width, height) * Self.fraction, weight: .medium))
                .foregroundStyle(tint.onContainer)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tint.container))
                let text = context.resolve(letter)
                let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: size.height))
                let narrowing = min(1, size.width / max(measured.width, 1))
                context.translateBy(x: size.width * Self.half, y: size.height * Self.half)
                context.scaleBy(x: narrowing, y: narrowing)
                context.draw(text, at: .zero, anchor: .center)
            }
            .frame(width: width, height: height)
        }
    }

    /// A glyph centered on a disc of `tint`.
    private struct Glyph: View {
        let symbol: String
        let tint: (container: Color, onContainer: Color)
        let size: CGFloat

        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint.onContainer)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tint.container)
        }
    }

    /// `photo`, once it decodes, filling its frame; `placeholder` until then, and in its place when there is none or it
    /// cannot be drawn: a hash whose bytes went missing draws as no photo at all, as Android's falls back on error. So
    /// does someone else's photo that the content filter finds explicit (ADR 2026-10.rpmq), screened before it is drawn.
    private struct PhotoOr<Placeholder: View>: View {
        /// What is drawn: the photo, under the filter as it stands, so turning the filter on or off redraws the face.
        private struct Drawing: Equatable {
            var photo: BlobHash?
            var filters: Bool
        }

        let photo: BlobHash?
        let width: CGFloat
        let height: CGFloat
        var unsaved: [UInt8]?
        @ViewBuilder let placeholder: Placeholder
        @Environment(BlobImageCache.self) private var photos: BlobImageCache?
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?
        @Environment(\.displayScale) private var scale
        @State private var shown: (hash: BlobHash, image: UIImage)?

        var body: some View {
            ZStack {
                if let photo, let shown, shown.hash == photo {
                    Image(uiImage: shown.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .accessibilityHidden(true)
                } else {
                    placeholder
                }
            }
            .frame(width: width, height: height)
            .task(id: Drawing(photo: photo, filters: screening?.filtersContent ?? false)) {
                guard let photo, let photos else {
                    return
                }
                // A photo picked and not yet saved is our own.
                if unsaved == nil, await screening?.hidesFace(photo) == true {
                    shown = nil
                    return
                }
                let pixels = Int((max(width, height) * scale).rounded(.up))
                if let image = await photos.image(photo, pixels: pixels, unsaved: unsaved) {
                    shown = (photo, image)
                }
            }
        }
    }
#endif
