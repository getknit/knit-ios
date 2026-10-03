#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The cropper, full screen (`AvatarCropDialog.kt` in knit-next): the picked photo pans and zooms under a fixed,
    /// centered circle, and Choose keeps the square the circle covers for the profile's Save. VoiceOver zooms it by
    /// swiping up and down.
    internal struct AvatarCropView: View {
        let source: DeviceImage
        let cancel: () -> Void
        let choose: (AvatarFraming) -> Void
        @State private var framing: AvatarFraming
        @Environment(\.dynamicTypeSize) private var typeSize

        init(source: DeviceImage, cancel: @escaping () -> Void, choose: @escaping (AvatarFraming) -> Void) {
            self.source = source
            self.cancel = cancel
            self.choose = choose
            _framing = State(initialValue: AvatarFraming(sourceWidth: source.pixelWidth, sourceHeight: source.pixelHeight))
        }

        var body: some View {
            // The hint and the buttons sit on plain black above and below the photo, which is clipped between them, so
            // their text never lies over a bright picture.
            VStack(spacing: 0) {
                Text(Copy.Photo.cropHint)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(Layout.page)
                CropArea(source: source, framing: $framing)
                    .clipped()
                // Side by side at the far edges while they fit; at the accessibility sizes one goes under the other,
                // where side by side broke both words.
                let layout =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: Layout.medium)) : AnyLayout(HStackLayout(spacing: Layout.page))
                layout {
                    Button(Copy.Common.cancel, action: cancel)
                    if !typeSize.isAccessibilitySize {
                        Spacer()
                    }
                    Button(Copy.Photo.cropChoose) { choose(framing) }
                        .bold()
                        .disabled(framing.diameter <= 0)
                        .accessibilityIdentifier(AccessibilityID.photoCropChoose)
                }
                .padding(Layout.page)
            }
            .foregroundStyle(.white)
            .background(Color.black.ignoresSafeArea())
            // A container of its own, so the screen's identifier leaves Choose's on the button inside.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.photoCropScreen)
        }
    }

    /// The photo under the circle, which a drag pans and a pinch zooms, and VoiceOver zooms by swiping up and down.
    private struct CropArea: View {
        let source: DeviceImage
        @Binding var framing: AvatarFraming
        /// How far the drag under way had moved, and the pinch had zoomed, when last heard.
        @State private var dragged = CGSize.zero
        @State private var pinched: CGFloat = 1

        var body: some View {
            GeometryReader { proxy in
                ZStack {
                    photo
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    CircleMask(diameter: framing.diameter)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
                .gesture(pan.simultaneously(with: zoom))
                .onAppear { framing.fit(width: proxy.size.width, height: proxy.size.height) }
                .onChange(of: proxy.size) { _, size in framing.fit(width: size.width, height: size.height) }
            }
        }

        private var photo: some View {
            Image(decorative: source.image, scale: 1)
                .resizable()
                .frame(
                    width: CGFloat(source.pixelWidth) * framing.pointsPerPixel,
                    height: CGFloat(source.pixelHeight) * framing.pointsPerPixel
                )
                .offset(x: framing.offsetX, y: framing.offsetY)
                .accessibilityElement()
                .accessibilityLabel(Copy.Photo.zoom)
                .accessibilityValue(Text(framing.scale, format: .percent.precision(.fractionLength(0))))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        framing.zoom(by: AvatarFraming.zoomStep)
                    case .decrement:
                        framing.zoom(by: 1 / AvatarFraming.zoomStep)
                    @unknown default:
                        break
                    }
                }
        }

        private var pan: some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    framing.pan(dx: value.translation.width - dragged.width, dy: value.translation.height - dragged.height)
                    dragged = value.translation
                }
                .onEnded { _ in dragged = .zero }
        }

        private var zoom: some Gesture {
            MagnifyGesture()
                .onChanged { value in
                    framing.zoom(by: value.magnification / pinched)
                    pinched = value.magnification
                }
                .onEnded { _ in pinched = 1 }
        }
    }

    /// Dims everything outside a centered circle of `diameter` points, and rings the circle.
    private struct CircleMask: View {
        /// How dark the dimming outside the circle is.
        private static let scrim = 0.5
        /// The ring's width.
        private static let ring: CGFloat = 2
        /// Half of anything.
        private static let half: CGFloat = 0.5

        let diameter: CGFloat

        var body: some View {
            GeometryReader { proxy in
                let circle = CGRect(
                    x: (proxy.size.width - diameter) * Self.half,
                    y: (proxy.size.height - diameter) * Self.half,
                    width: diameter,
                    height: diameter
                )
                ZStack {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        path.addEllipse(in: circle)
                    }
                    .fill(.black.opacity(Self.scrim), style: FillStyle(eoFill: true))
                    Circle()
                        .stroke(.white, lineWidth: Self.ring)
                        .frame(width: diameter, height: diameter)
                }
            }
        }
    }
#endif
