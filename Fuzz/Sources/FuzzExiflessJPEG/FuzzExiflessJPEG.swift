import KnitWire

/// The highest EXIF orientation, a mirror turned a quarter.
private let highestOrientation = 8

/// Arbitrary bytes as a picked photo, read for its EXIF-less name (ADR 2026-10.f3mv, knit-ios #12). Nothing traps, a
/// result is never larger than its input and has an orientation from 1 to 8, and what it keeps reads as itself, upright.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzExiflessJPEG(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    guard let read = ExiflessJPEG.read(bytes) else {
        return 0
    }
    precondition(read.orientation >= 1 && read.orientation <= highestOrientation, "an orientation outside 1 to 8")
    precondition(read.kept.count <= bytes.count, "more kept than read")
    let again = ExiflessJPEG.read(read.kept)
    precondition(again?.kept == read.kept && again?.orientation == 1, "what was kept did not read as itself, upright")
    return 0
}
