import Foundation
import KnitWire
import Testing

@testable import KnitAppCore

/// What a face wears without a photo, and where a group's faces and a crop fall: knit-next's `ColorSchemeTest`,
/// `GroupFacesTest`, `ClusterGeometryTest` and `AvatarCropTest`, case for case where they apply.
@Suite struct FaceTests {
    // MARK: The tint (ADR 2026-09.j8c7 in knit-next)

    /// The slot is the contract between phones: the same node id lands on the same tint on Android and here, after every
    /// update (`avatarTintSlotIsStableAcrossPhonesAndVersions`).
    @Test func aKeysSlotIsAndroidsOnEveryPhone() {
        #expect(AvatarTint.light.count == 12)
        #expect(AvatarTint.slot(for: "mfrggzdfmztwq2lknnwg23tpobyxe43uov3ho6dz") == 0)
        #expect(AvatarTint.slot(for: "ada") == 6)
        #expect(AvatarTint.slot(for: "Ada Lovelace") == 7)
        #expect(AvatarTint.slot(for: "!a1b2c3d4") == 5)
        #expect(AvatarTint.slot(for: "") == 0)
        // Java's hash of this one is Int.MIN_VALUE, the one a plain `%` would have sent negative.
        #expect(AvatarTint.slot(for: "polygenelubricants") == 4)
        #expect("lmnopqrstuvw".map { AvatarTint.slot(for: String($0)) } == Array(0..<12))
    }

    /// The hash runs over UTF-16 code units, as Java's does: an emoji is two of them.
    @Test func theHashReadsUTF16AsJavaDoes() {
        // "🦊" is D83E DD8A: (0xD83E * 31 + 0xDD8A) mod 12, as Kotlin computes it.
        #expect(AvatarTint.slot(for: "🦊") == (0xD83E * 31 + 0xDD8A) % 12)
    }

    /// The initial is text, so it clears AA's 4.5:1 for text on its disc, in both palettes
    /// (`everyAvatarTintClearsTextContrast`).
    @Test func everyInitialClearsTextContrastOnItsDisc() {
        #expect(AvatarTint.light.count == AvatarTint.dark.count, "a slot means the same hue in both modes")
        for (mode, tints) in [("light", AvatarTint.light), ("dark", AvatarTint.dark)] {
            for (slot, tint) in tints.enumerated() {
                let ratio = Self.contrast(tint.onContainer, tint.container)
                #expect(ratio >= 4.5, "\(mode) slot \(slot) is \(ratio):1")
            }
        }
    }

    /// The palette laps the wheel once, in order, and a slot is the same hue in both modes, so a person is "the green
    /// one" whether the phone is light or dark (`avatarTintsWalkTheWheelOnceAndAgreeAcrossModes`).
    @Test func thePalettesWalkTheWheelOnceAndAgreeAcrossModes() {
        for tints in [AvatarTint.light, AvatarTint.dark] {
            let hues = tints.map { Self.hue($0.container) }
            let steps = hues.indices.map { (hues[($0 + 1) % hues.count] - hues[$0] + 360).truncatingRemainder(dividingBy: 360) }
            #expect(steps.allSatisfy { $0 > 0 && $0 < 180 }, "\(steps)")
            #expect(abs(steps.reduce(0, +) - 360) <= 1)
        }
        for (light, dark) in zip(AvatarTint.light, AvatarTint.dark) {
            let gap = abs(Self.hue(light.container) - Self.hue(dark.container)).truncatingRemainder(dividingBy: 360)
            #expect(min(gap, 360 - gap) <= 20)
        }
    }

    // MARK: The initial

    @Test func theInitialIsTheFirstCharacterUpperCased() {
        #expect(Monogram.initial(of: "Ada Lovelace") == "A")
        #expect(Monogram.initial(of: "  sam") == "S")
        #expect(Monogram.initial(of: "\u{00A0}\tpriya") == "P")
        #expect(Monogram.initial(of: "ßam") == "SS", "upper-cased as Kotlin's uppercase() does")
        #expect(Monogram.initial(of: "e\u{301}lise") == "E\u{301}", "a letter keeps its accent")
    }

    @Test func aBlankNameShowsAQuestionMark() {
        #expect(Monogram.initial(of: "") == "?")
        #expect(Monogram.initial(of: "   ") == "?")
    }

    /// A leading emoji, flag or family is one character to a person, and stays whole (`AvatarLargeEmojiPreview`).
    @Test func aLeadingEmojiStaysWhole() {
        #expect(Monogram.initial(of: "🦊 Fox") == "🦊")
        #expect(Monogram.initial(of: "🇳🇿 Kiwi") == "🇳🇿")
        #expect(Monogram.initial(of: "👩‍👩‍👧 Family") == "👩‍👩‍👧")
        #expect(Monogram.initial(of: "👍🏽 ok") == "👍🏽")
    }

    // MARK: A group's faces (ADR 2026-09.zapp in knit-next)

    @Test func aGroupsFacesLeaveUsOutAndGoByNodeIdNotRoster() {
        #expect(FaceCluster.pick(["me", "z", "a", "m"], me: "me") == ["a", "m", "z"])
        #expect(FaceCluster.pick(["me", "f", "b", "e", "a", "d", "c"], me: "me") == ["a", "b", "c", "d"])
        #expect(FaceCluster.pick(["me", "b", "a", "b", "a"], me: "me") == ["a", "b"], "a repeated id is one face")
    }

    /// One other is no cluster: it would read as that person's DM, so the group shows its glyph.
    @Test func fewerThanTwoOthersIsNoCluster() {
        #expect(FaceCluster.pick(["me", "x"], me: "me").isEmpty)
        #expect(FaceCluster.pick(["me"], me: "me").isEmpty)
        #expect(FaceCluster.pick([], me: "me").isEmpty)
    }

    /// Ids compare by their bytes: a Kelvin sign is not a K (ADR 2026-09.jc2x).
    @Test func idsCompareByTheirBytes() {
        // Swift's `==` calls these equal, so the bytes are what is compared.
        let bytes = { (ids: [String]) in ids.map { Array($0.utf8) } }
        #expect(bytes(FaceCluster.pick(["me", "\u{212A}", "K"], me: "me")) == bytes(["K", "\u{212A}"]))
        #expect(bytes(FaceCluster.pick(["\u{E9}", "e\u{301}", "x"], me: "x")) == bytes(["e\u{301}", "\u{E9}"]))
        #expect(
            bytes(FaceCluster.pick(["\u{E9}", "e\u{301}", "a"], me: "e\u{301}")) == bytes(["a", "\u{E9}"]), "only our own bytes are us")
    }

    @Test func everyCellLiesInsideTheSquareAndTheNeighboursSitAGapApart() {
        for count in FaceCluster.minimum...FaceCluster.maximum {
            for gap in [0, 0.03] {
                let cells = FaceCluster.cells(count: count, gap: gap)
                #expect(cells.count == count)
                for cell in cells {
                    #expect(cell.left >= 0 && cell.top >= 0 && cell.right <= 1 && cell.bottom <= 1)
                    #expect(cell.width > 0 && cell.height > 0)
                }
                for (index, first) in cells.enumerated() {
                    for second in cells[(index + 1)...] {
                        let apart = max(
                            max(first.left - second.right, second.left - first.right),
                            max(first.top - second.bottom, second.top - first.bottom))
                        #expect(abs(apart - gap) < 1e-9, "\(count) cells, gap \(gap): \(first) and \(second)")
                    }
                }
            }
            let area = FaceCluster.cells(count: count, gap: 0).reduce(0) { $0 + $1.width * $1.height }
            #expect(abs(area - 1) < 1e-9, "with no gap, \(count) cells tile the square")
        }
    }

    @Test func theCellsReadLeftToRightThenTopToBottom() {
        let two = FaceCluster.cells(count: 2, gap: 0.03)
        #expect(two[0].height == 1 && two[1].height == 1 && two[0].right < two[1].left)
        let three = FaceCluster.cells(count: 3, gap: 0.03)
        #expect(three[0].height == 1 && three[0].left == 0)
        #expect(three[1].bottom < three[2].top && three[1].left == three[2].left)
        let four = FaceCluster.cells(count: 4, gap: 0.03)
        #expect(four[0].right < four[1].left && four[0].bottom < four[2].top && four[2].right < four[3].left)
    }

    @Test func aCountOrGapOutsideTheGridHasNoCells() {
        #expect(FaceCluster.cells(count: 1, gap: 0.03).isEmpty)
        #expect(FaceCluster.cells(count: 5, gap: 0.03).isEmpty)
        #expect(FaceCluster.cells(count: 2, gap: 0.5).isEmpty)
        #expect(FaceCluster.cells(count: 2, gap: -0.01).isEmpty)
    }

    // MARK: The crop (`AvatarCropTest`)

    @Test func aCropAtNoZoomIsACenterCrop() {
        let diameter: Float = 800
        #expect(Self.crop((1000, 1000), diameter, 1, (0, 0)) == CropRect(left: 0, top: 0, width: 1000, height: 1000))
        #expect(Self.crop((1200, 800), diameter, 1, (0, 0)) == CropRect(left: 200, top: 0, width: 800, height: 800))
        #expect(Self.crop((800, 1200), diameter, 1, (0, 0)) == CropRect(left: 0, top: 200, width: 800, height: 800))
        #expect(Self.crop((100, 100), diameter, 1, (0, 0)) == CropRect(left: 0, top: 0, width: 100, height: 100))
    }

    @Test func zoomingHalvesTheSideAndPanningStopsAtTheEdge() {
        let diameter: Float = 800
        #expect(Self.crop((1000, 1000), diameter, 2, (0, 0)) == CropRect(left: 250, top: 250, width: 500, height: 500))
        #expect(Self.crop((1000, 1000), diameter, 2, (-1000, 0)) == CropRect(left: 500, top: 250, width: 500, height: 500))
        #expect(Self.crop((1000, 1000), diameter, 2, (1000, 0)) == CropRect(left: 0, top: 250, width: 500, height: 500))
        #expect(Self.crop((800, 1200), diameter, 2, (0, -2000)) == CropRect(left: 200, top: 800, width: 400, height: 400))
    }

    @Test func everyCropIsSquareAndInside() {
        let sizes = [(640, 480), (480, 640), (1024, 1024), (1920, 1080), (300, 900)]
        let offsets: [Float] = [-5000, -300, 0, 300, 5000]
        for (width, height) in sizes {
            for scale: Float in [1, 1.5, 2.7, 5] {
                for offsetX in offsets {
                    for offsetY in offsets {
                        let crop = Self.crop((width, height), 800, scale, (offsetX, offsetY))
                        #expect(crop.width == crop.height && crop.width >= 1)
                        #expect(crop.left >= 0 && crop.left + crop.width <= width)
                        #expect(crop.top >= 0 && crop.top + crop.height <= height)
                    }
                }
            }
        }
    }

    /// Before the cropper is measured there is no circle, and the crop is a pixel rather than a trap.
    @Test func anUnmeasuredCropperCropsAPixel() {
        #expect(AvatarFraming(sourceWidth: 640, sourceHeight: 480).crop == CropRect(left: 0, top: 0, width: 1, height: 1))
    }

    @Test func theFramingZoomsFromOneToFiveAndPansNoFurtherThanTheCircleAllows() {
        var framing = AvatarFraming(sourceWidth: 1200, sourceHeight: 800)
        framing.fit(width: 400, height: 1000)
        #expect(framing.diameter == 320)
        #expect(framing.pointsPerPixel == 0.4, "the shorter side fills the circle")
        framing.zoom(by: 0.5)
        #expect(framing.scale == 1)
        framing.pan(dx: 0, dy: 50)
        #expect(framing.offsetY == 0, "at no zoom the short side has nowhere to go")
        framing.pan(dx: 1000, dy: 0)
        #expect(framing.offsetX == 80, "(1200 × 0.4 − 320) ÷ 2")
        #expect(framing.crop == CropRect(left: 0, top: 0, width: 800, height: 800))
        framing.zoom(by: 10)
        #expect(framing.scale == AvatarFraming.maxScale)
        framing.pan(dx: -10_000, dy: -10_000)
        #expect(framing.crop == CropRect(left: 1040, top: 640, width: 160, height: 160))
        framing.zoom(by: 1 / AvatarFraming.maxScale)
        #expect(framing.offsetX == -80 && framing.offsetY == 0, "zooming out pulls the photo back over the circle")
    }

    // MARK: Helpers

    private static func crop(_ size: (Int, Int), _ diameter: Float, _ scale: Float, _ offset: (Float, Float)) -> CropRect {
        AvatarFraming.crop(source: size, diameter: diameter, scale: scale, offset: offset)
    }

    private static func channels(_ hex: Int) -> [Double] {
        [16, 8, 0].map { Double((hex >> $0) & 0xFF) / 255 }
    }

    /// WCAG's contrast ratio, as `ColorSchemeTest.contrastRatio` measures it.
    private static func contrast(_ first: Int, _ second: Int) -> Double {
        let luminance = { (hex: Int) -> Double in
            let linear = channels(hex).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }

    /// The HSL hue, as `ColorSchemeTest.hueOf` reads it.
    private static func hue(_ hex: Int) -> Double {
        let rgb = channels(hex)
        let (high, low) = (rgb.max() ?? 0, rgb.min() ?? 0)
        let spread = high - low
        guard spread > 0 else {
            return 0
        }
        let degrees: Double =
            if high == rgb[0] {
                60 * ((rgb[1] - rgb[2]) / spread).truncatingRemainder(dividingBy: 6)
            } else if high == rgb[1] {
                60 * ((rgb[2] - rgb[0]) / spread + 2)
            } else {
                60 * ((rgb[0] - rgb[1]) / spread + 4)
            }
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
