import KnitTestSupport
import KnitWire
import Testing

/// A JPEG's EXIF-less bytes and orientation (ADR 2026-10.f3mv, knit-ios #12): only EXIF goes, everything else stays byte
/// for byte, and anything the walk does not understand answers `nil`, which names nothing.
@Suite struct ExiflessJPEGTests {
    private typealias Fixture = JPEGFixture

    private func exif(orientation: Int, little: Bool = false) -> [UInt8] {
        Fixture.exif(Fixture.orientationTIFF(orientation, little: little))
    }

    // MARK: What goes

    @Test func onlyTheExifSegmentGoesAndXmpStays() throws {
        let read = try #require(ExiflessJPEG.read(Fixture.jpeg(exif: [exif(orientation: 6)])))
        #expect(read.kept == Fixture.jpeg())
        #expect(read.kept.firstRange(of: Fixture.xmp) != nil, "XMP is an APP1 too, and no EXIF")
        #expect(read.orientation == 6)
    }

    @Test func theSameScanUnderAndroidsExifAndUnderPhotosRewriteHasOneName() throws {
        // #12: Photos replaced Knit for Android's 54-byte EXIF with its own 302 bytes and touched nothing else.
        let android = try #require(ExiflessJPEG.read(Fixture.jpeg(exif: [Fixture.androidExif], extra: [Fixture.mpf])))
        let apple = try #require(ExiflessJPEG.read(Fixture.jpeg(exif: [Fixture.appleExif], extra: [Fixture.mpf])))
        #expect(Fixture.androidExif.count == 54 && Fixture.appleExif.count == 302)
        #expect(android == apple)
        #expect(android.kept == Fixture.jpeg(extra: [Fixture.mpf]) && android.orientation == 1)
    }

    @Test func everythingFromTheScanOnIsKeptVerbatim() throws {
        // A later scan, EOI, a gain map's JPEG and bytes that look like EXIF all belong to the tail, which is not walked.
        let tail = Fixture.sos + [0x01, 0xFF, 0xD9] + Fixture.soi + exif(orientation: 3) + Array("a gain map".utf8)
        let picked = Fixture.jpeg(exif: [exif(orientation: 1)], trailer: tail)
        let read = try #require(ExiflessJPEG.read(picked))
        #expect(read.kept == Fixture.jpeg(trailer: tail))
        #expect(read.orientation == 1)
    }

    @Test func fillBytesStayAndOnlyTheSegmentsOwnBytesGo() throws {
        let tables = Fixture.dqt + Fixture.frame + Fixture.sos
        let read = try #require(ExiflessJPEG.read(Fixture.soi + [0xFF, 0xFF] + exif(orientation: 8) + [0xFF] + tables))
        #expect(read.kept == Fixture.soi + [0xFF, 0xFF, 0xFF] + tables)
        #expect(read.orientation == 8)
    }

    @Test func whatIsKeptReadsAsItselfUpright() throws {
        let read = try #require(ExiflessJPEG.read(Fixture.jpeg(exif: [Fixture.appleExif], trailer: [1, 2, 3])))
        let again = try #require(ExiflessJPEG.read(read.kept))
        #expect(again.kept == read.kept && again.orientation == 1)
    }

    // MARK: Orientation

    @Test(arguments: [true, false])
    func everyOrientationReadsInEitherByteOrder(little: Bool) throws {
        for orientation in 1...8 {
            let read = try #require(ExiflessJPEG.read(Fixture.jpeg(exif: [exif(orientation: orientation, little: little)])))
            #expect(read.orientation == orientation)
        }
    }

    @Test func noExifAndNoTagAndZeroAllReadUpright() {
        #expect(ExiflessJPEG.read(Fixture.jpeg())?.orientation == 1)
        let untagged = Fixture.tiff(little: true, entries: [Fixture.TIFFEntry(tag: 0x011A, type: 5, count: 1, value: [0, 0, 0, 0])])
        #expect(ExiflessJPEG.read(Fixture.jpeg(exif: [Fixture.exif(untagged)]))?.orientation == 1)
        // Android's `UPRIGHT` holds `ORIENTATION_UNDEFINED`, 0 (`AttachmentStore.kt:514`, knit-next `5f521cb9`).
        #expect(ExiflessJPEG.read(Fixture.jpeg(exif: [exif(orientation: 0)]))?.orientation == 1)
        #expect(ExiflessJPEG.read(Fixture.jpeg(exif: [exif(orientation: 0, little: true)]))?.orientation == 1)
    }

    // MARK: What names nothing

    /// Each case, one JPEG this walk refuses to name: its structure, then its EXIF's.
    private static let refused = refusedWalks.merging(refusedTIFFs) { first, _ in first }

    private static let rest = Fixture.dqt + Fixture.frame + Fixture.sos + Fixture.entropy + Fixture.eoi

    private static let refusedWalks: [String: [UInt8]] = {
        var cases: [String: [UInt8]] = [
            "nothing": [],
            "a lone FF": [0xFF],
            "a GIF": Array("GIF89a".utf8) + [0, 1, 0, 1],
            "a PNG": [0x89] + Array("PNG\r\n".utf8),
            "no marker after SOI": Fixture.soi + [0x12, 0x34],
            "fill to the end": Fixture.soi + [0xFF, 0xFF, 0xFF],
            "no SOS": Fixture.soi + Fixture.app0 + Fixture.dqt,
            "a length of 1": Fixture.soi + [0xFF, 0xE0, 0x00, 0x01] + rest,
            "a length past the end": Fixture.soi + [0xFF, 0xE0, 0x7F, 0xFF] + rest,
            "a cut length": Fixture.soi + [0xFF, 0xE0, 0x00],
        ]
        for marker: UInt8 in [0x00, 0x01, 0xD0, 0xD3, 0xD7, 0xD8, 0xD9] {
            cases["FF \(marker) before SOS"] = Fixture.soi + Fixture.app0 + [0xFF, marker] + rest
        }
        return cases
    }()

    private static let refusedTIFFs: [String: [UInt8]] = {
        let exif = { (tiff: [UInt8]) in Fixture.soi + Fixture.exif(tiff) + rest }
        let header = Fixture.orientationTIFF(1, little: false)
        let orientation = Fixture.TIFFEntry(tag: 0x0112, type: 3, count: 1, value: [0, 1, 0, 0])
        return [
            "an unknown byte order": exif(Array("XX".utf8) + header.dropFirst(2)),
            "a short TIFF": exif(Array(header.prefix(7))),
            "IFD0 past the end": exif(Array(header.prefix(4)) + [0, 0, 0xFF, 0xFF] + header.dropFirst(8)),
            "entries past the end": exif(Array(header.prefix(8)) + [0x00, 0x09] + header.dropFirst(10)),
            "orientation 9": exif(Fixture.orientationTIFF(9, little: true)),
            "orientation 65535": exif(Fixture.orientationTIFF(65_535, little: false)),
            "orientation as a LONG": exif(
                Fixture.tiff(little: false, entries: [Fixture.TIFFEntry(tag: 0x0112, type: 4, count: 1, value: [0, 0, 0, 1])])),
            "orientation twice over": exif(
                Fixture.tiff(little: false, entries: [Fixture.TIFFEntry(tag: 0x0112, type: 3, count: 2, value: [0, 1, 0, 1])])),
            "two orientation tags": exif(Fixture.tiff(little: false, entries: [orientation, orientation])),
            "two EXIF segments": Fixture.soi + Fixture.exif(header) + Fixture.exif(header) + rest,
        ]
    }()

    @Test(arguments: refused.keys.sorted())
    func namesNothing(_ name: String) throws {
        let bytes = try #require(Self.refused[name])
        #expect(ExiflessJPEG.read(bytes) == nil, "\(name)")
    }

    @Test func aJPEGCutAnywhereBeforeItsScanNamesNothing() throws {
        let picked = Fixture.jpeg(exif: [Fixture.appleExif])
        let scan = try #require(picked.firstRange(of: Fixture.sos)).upperBound
        for length in 0..<scan {
            #expect(ExiflessJPEG.read(Array(picked.prefix(length))) == nil, "cut at \(length)")
        }
        for length in scan...picked.count {
            #expect(ExiflessJPEG.read(Array(picked.prefix(length))) != nil, "cut after the scan's header at \(length)")
        }
    }
}
