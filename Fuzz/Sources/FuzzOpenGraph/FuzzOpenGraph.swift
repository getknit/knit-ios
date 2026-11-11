import KnitAppCore
import KnitWire

/// Arbitrary bytes as a page a sender's fetch read, and as a redirect's base and reference (ADR 2026-11.hcvg). Nothing
/// traps. A page that yields metadata yields a title within its limit and never blank, a description within its limit,
/// and a picture only at a plain https address a card would keep. The link rules and the resolution never trap on any
/// text either.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOpenGraph(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    let text = OpenGraphParser.decode(bytes, contentType: nil)
    _ = OpenGraphParser.decodeEntities(text)
    _ = LinkPreviewPolicy.normalize(text)
    _ = LinkPreviewPolicy.firstEligible(text)
    _ = JavaURIResolution.resolve(text, against: "https://example.com/a/b?c")
    let pair = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    if let base = pair.first, let reference = pair.dropFirst().first {
        _ = JavaURIResolution.resolve(String(reference), against: String(base)).flatMap(LinkPreviewPolicy.normalize)
    }
    guard let meta = OpenGraphParser.parse(text, finalURL: "https://example.com/story/page?x=1") else {
        return 0
    }
    precondition(!meta.title.isEmpty && meta.title.utf16.count <= LinkPreviewBlob.titleMax, "a title blank or past its limit")
    if let description = meta.description {
        precondition(!description.isEmpty && description.utf16.count <= LinkPreviewBlob.descriptionMax, "a description past its limit")
    }
    if let image = meta.imageURL {
        precondition(LinkPreviewBlob.isSafeHttpURL(image) && image.lowercased().hasPrefix("https://"), "a picture at an unsafe address")
    }
    return 0
}
