#if os(iOS)
    import Accessibility
    import ImageIO
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// A photo from the mesh that moves, read but not decoded (``PhotoDecoder/animation(_:)``): its bytes, opened when
    /// sealed, and when each frame shows. A class, so a player tells one photo from another without comparing bytes.
    internal final class AnimatedPhoto: Sendable {
        /// The photo's bytes, a sealed one's opened.
        let bytes: Data
        /// When each frame shows.
        let timing: AnimationTiming

        init(bytes: Data, timing: AnimationTiming) {
            self.bytes = bytes
            self.timing = timing
        }

        /// What the photo's bytes weigh in memory, for a cache's budget.
        var cost: Int {
            bytes.count
        }
    }

    /// A moving photo playing in place of its first frame, as Android's Coil plays a GIF or an animated WebP in a bubble
    /// and in the viewer (`AttachmentImage` and `FullscreenImageViewer.kt` in knit-next). It shows `poster`, the first
    /// frame already decoded, until it can play, and whenever it should not: while off screen, and while Auto-Play
    /// Animated Images is off in Settings. Each frame is decoded at `pixels` as it falls due, so a playing photo holds two
    /// frames, never the whole clip, and one scrolled away holds none.
    internal struct AnimatedPhotoView: UIViewRepresentable {
        let photo: AnimatedPhoto
        let poster: UIImage
        /// The most pixels a frame is decoded at, on its long side.
        let pixels: Int
        /// Whether the photo fills its frame and is cut to it, as in a bubble, or fits inside it, as in the viewer.
        let fills: Bool

        func makeUIView(context _: Context) -> AnimatedPhotoPlayer {
            AnimatedPhotoPlayer()
        }

        func updateUIView(_ player: AnimatedPhotoPlayer, context _: Context) {
            player.show(photo, poster: poster, pixels: pixels, fills: fills)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView _: AnimatedPhotoPlayer, context _: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions(by: poster.size)
        }
    }

    /// The UIKit half of ``AnimatedPhotoView``: a layer whose contents a display link moves on from frame to frame, by the
    /// clock rather than by counting ticks, so a late tick skips frames instead of slowing the photo.
    internal final class AnimatedPhotoPlayer: UIView {
        /// The display link's pace: GIFs rarely run past 30 frames a second, and Android's play at 15.
        private static let pace = CAFrameRateRange(minimum: slowest, maximum: fastest, preferred: fastest)
        private static let fastest: Float = 30
        private static let slowest: Float = 8

        private var photo: AnimatedPhoto?
        private var poster: UIImage?
        private var pixels = 0
        private var link: CADisplayLink?
        private var frames: FrameSource?
        private var decoding: Task<Void, Never>?
        private var shown = 0
        /// When the photo started, on the clock, as if it had played without a pause.
        private var start = ContinuousClock.now
        /// How far it had played when it last stopped.
        private var played = Duration.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isAccessibilityElement = false
            accessibilityIgnoresInvertColors = true
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(settingChanged),
                name: AccessibilitySettings.animatedImagesEnabledDidChangeNotification,
                object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        /// Plays `photo`, from its start when it is another photo than the one playing.
        func show(_ photo: AnimatedPhoto, poster: UIImage, pixels: Int, fills: Bool) {
            layer.contentsGravity = fills ? .resizeAspectFill : .resizeAspect
            self.poster = poster
            guard photo !== self.photo || pixels != self.pixels else {
                return
            }
            stop()
            self.photo = photo
            self.pixels = pixels
            frames = nil
            played = .zero
            showPoster()
            playIfShown()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                stop()
                // A row scrolled away lets go of its frames and its decoder; it plays on from where it stopped when it is back.
                frames = nil
            } else {
                playIfShown()
            }
        }

        /// Called on whichever thread posts the change, so it hops to the main actor rather than assume it is there.
        @objc nonisolated private func settingChanged() {
            Task { @MainActor in applySetting() }
        }

        private func applySetting() {
            if AccessibilitySettings.animatedImagesEnabled {
                playIfShown()
            } else {
                stop()
                showPoster()
            }
        }

        /// Starts the display link while the photo is on screen and Settings lets photos play.
        private func playIfShown() {
            guard link == nil, photo != nil, window != nil, AccessibilitySettings.animatedImagesEnabled else {
                return
            }
            start = .now - played
            let ticks = CADisplayLink(target: Ticks(self), selector: #selector(Ticks.tick))
            ticks.preferredFrameRateRange = Self.pace
            ticks.add(to: .main, forMode: .common)
            link = ticks
        }

        private func stop() {
            if link != nil {
                played = .now - start
            }
            link?.invalidate()
            link = nil
            decoding?.cancel()
            decoding = nil
        }

        private func showPoster() {
            layer.contents = poster?.cgImage
            shown = 0
        }

        /// Shows the frame due now, decoding it off the main actor; a tick while one decodes waits for it.
        func tick() {
            guard let photo, decoding == nil else {
                return
            }
            let due = photo.timing.frame(at: .now - start)
            guard due != shown else {
                return
            }
            let source = frames ?? FrameSource(photo.bytes, pixels: pixels)
            frames = source
            decoding = Task { [weak self] in
                let image = await source.frame(due)
                guard let self, !Task.isCancelled else {
                    return
                }
                decoding = nil
                if let image, self.photo === photo {
                    layer.contents = image.cgImage
                    shown = due
                }
            }
        }
    }

    /// The display link's target, which holds its player weakly: a display link holds its target until it is
    /// invalidated.
    private final class Ticks: NSObject {
        private weak var player: AnimatedPhotoPlayer?

        init(_ player: AnimatedPhotoPlayer) {
            self.player = player
        }

        @MainActor @objc func tick() {
            player?.tick()
        }
    }

    /// One photo's decoder, off the main actor: each frame as a thumbnail no larger than `pixels` on its long side, turned
    /// upright, decoded when asked for.
    private actor FrameSource {
        private let source: CGImageSource?
        private let options: CFDictionary

        init(_ bytes: Data, pixels: Int) {
            source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            options =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(pixels, 1),
                ] as CFDictionary
        }

        /// Frame `index`, or `nil` when it does not decode.
        func frame(_ index: Int) -> UIImage? {
            source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, index, options) }.map { UIImage(cgImage: $0) }
        }
    }
#endif
