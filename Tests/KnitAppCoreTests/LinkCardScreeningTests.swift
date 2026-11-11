import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// The content filter over a link's preview card (`screenLinkPreview` in knit-next, ADR 2026-11.hcvg): its picture and its
/// words fold into one verdict, so a flagged card hides whole, someone else's only and only while the filter is on.
@MainActor
@Suite struct LinkCardScreeningTests {
    private static let nude: [UInt8] = [0xFF, 0xD8, 1]
    private static let sunset: [UInt8] = [0xFF, 0xD8, 2]
    private static let unreadable: [UInt8] = [0xFF, 0xD8, 3]

    /// A session whose filter flags "darn" in the room alone and "zorblax" everywhere, and scores pictures from a table.
    private struct Filter {
        let rig: AppRig
        let screening: PhotoScreening
        let classifier: FakeClassifier

        @MainActor
        init() {
            let words = TextScreening(classifier: nil, words: WordFilter(words: ["darn"]), slurs: WordFilter(words: ["zorblax"]))
            rig = AppRig(screening: words, linkPreviews: LinkPreviews())
            rig.session.filtersContent = true
            classifier = FakeClassifier([
                LinkCardScreeningTests.nude: FakeClassifier.explicit, LinkCardScreeningTests.sunset: FakeClassifier.clean,
            ])
            screening = PhotoScreening(classifier: classifier, session: rig.session)
        }
    }

    /// A card held in the blob store, as the thread would draw it.
    private func card(title: String = "A page", image: [UInt8]? = nil, inRoom: Bool = true, in rig: AppRig) -> LinkCard {
        let mime = image.map { _ in "image/jpeg" }
        let blob = LinkPreviewBlob(url: "https://example.com/\(title.count)", title: title, image: image, imageMime: mime)
        let bytes = blob.encoded
        rig.stores.blobs.insert(bytes, hash: BlobHash(of: bytes), mime: LinkPreviewBlob.mime, storedAt: 1)
        return LinkCard(blob, hash: BlobHash(of: bytes), key: nil, inRoom: inRoom)
    }

    @Test func anExplicitPictureHidesTheWholeCard() async {
        let filter = Filter()
        let (rig, screening, classifier) = (filter.rig, filter.screening, filter.classifier)
        let flagged = card(image: Self.nude, in: rig)
        #expect(!screening.isHiding(card: flagged, isMine: false), "nothing is known before it is screened")
        #expect(await screening.hides(card: flagged, isMine: false))
        #expect(screening.isHiding(card: flagged, isMine: false))
        #expect(await screening.hides(card: flagged, isMine: false))
        #expect(await classifier.asked == 1, "one verdict, kept")
        #expect(await !screening.hides(card: card(title: "Sunset", image: Self.sunset, in: rig), isMine: false))
    }

    /// The words are read as a message's are in its thread: the room's list in the room, the slur list everywhere.
    @Test func itsWordsAreReadAsTheThreadReadsThem() async {
        let filter = Filter()
        let (rig, screening) = (filter.rig, filter.screening)
        #expect(await screening.hides(card: card(title: "Darn it", in: rig), isMine: false))
        #expect(await !screening.hides(card: card(title: "Darn it, again", inRoom: false, in: rig), isMine: false))
        #expect(await screening.hides(card: card(title: "Zorblax", inRoom: false, in: rig), isMine: false))
    }

    @Test func ourOwnCardAndAnUnfilteredThreadHideNothing() async {
        let filter = Filter()
        let (rig, screening, classifier) = (filter.rig, filter.screening, filter.classifier)
        let flagged = card(title: "Zorblax", image: Self.nude, in: rig)
        #expect(await !screening.hides(card: flagged, isMine: true))
        #expect(!screening.isHiding(card: flagged, isMine: true))
        #expect(await classifier.asked == 0, "our own card is never screened")
        screening.filtersContent = false
        #expect(await !screening.hides(card: flagged, isMine: false))
        screening.filtersContent = true
        #expect(await screening.hides(card: flagged, isMine: false), "turned back on, it screens and hides")
    }

    /// A picture the model cannot read is let through, as a photo is, and asked about again; words that flag the card
    /// settle it whatever the picture.
    @Test func aPictureThatCannotBeScoredIsAskedAboutAgain() async {
        let filter = Filter()
        let (rig, screening, classifier) = (filter.rig, filter.screening, filter.classifier)
        let unscored = card(image: Self.unreadable, in: rig)
        #expect(await !screening.hides(card: unscored, isMine: false))
        #expect(await !screening.hides(card: unscored, isMine: false))
        #expect(await classifier.asked == 2)
        let blob = LinkPreviewBlob(url: "https://example.com/gone", title: "Gone", image: Self.sunset, imageMime: "image/jpeg")
        let gone = LinkCard(blob, hash: BlobHash(of: [9]), key: nil, inRoom: true)
        #expect(await !screening.hides(card: gone, isMine: false), "a blob that went leaves its picture unscored")
        #expect(await classifier.asked == 2, "nothing to score")
        let flaggedWords = card(title: "Zorblax", image: Self.unreadable, in: rig)
        #expect(await screening.hides(card: flaggedWords, isMine: false))
        #expect(screening.isHiding(card: flaggedWords, isMine: false))
    }
}
