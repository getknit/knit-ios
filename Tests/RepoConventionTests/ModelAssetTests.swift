import Foundation
import Testing

/// The photo classifier the app bundles (ADR 2026-10.rpmq) is in the tree and whole. Without it the content filter
/// lets every photo through and says nothing, so a checkout that lost it, or a tool that put a stub in its place,
/// has to fail here rather than on a phone. `scripts/check.sh xcode` and `release` check that it reaches the app.
@Suite struct ModelAssetTests {
    private static let package = "App/Models/NSFW.mlpackage"

    /// The manifest names the model, and the model and its float16 weights are there at their real size: the weights
    /// of MobileNetV2 140/224 come to about 8.6 MB.
    @Test func thePhotoClassifierIsWhole() throws {
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: RepoFiles.data("\(Self.package)/Manifest.json")) as? [String: Any])
        let entries = try #require(manifest["itemInfoEntries"] as? [String: [String: String]])
        let root = try #require(manifest["rootModelIdentifier"] as? String)
        #expect(entries[root]?["path"] == "com.apple.CoreML/model.mlmodel")
        #expect(try RepoFiles.data("\(Self.package)/Data/com.apple.CoreML/model.mlmodel").count > 100_000)
        #expect(try RepoFiles.data("\(Self.package)/Data/com.apple.CoreML/weights/weight.bin").count > 8_000_000)
    }
}
