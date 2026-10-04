import Crypto
import Foundation
import Testing

/// The classifiers the app bundles (ADR 2026-10.rpmq, ADR 2026-10.e4kz) are in the tree and whole. Without one the
/// content filter lets every photo or message through and says nothing, so a checkout that lost it, or a tool that put
/// a stub in its place, has to fail here rather than on a phone. `scripts/check.sh xcode` and `release` check that they
/// reach the app.
@Suite struct ModelAssetTests {
    private static let package = "App/Models/NSFW.mlpackage"
    private static let textPackage = "App/Models/Toxicity.mlpackage"

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

    /// The text classifier is whole too: ALBERT base v2's float16 weights come to about 23 MB, shared by its twelve
    /// layers, which the conversion keeps once.
    @Test func theTextClassifierIsWhole() throws {
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: RepoFiles.data("\(Self.textPackage)/Manifest.json")) as? [String: Any])
        let entries = try #require(manifest["itemInfoEntries"] as? [String: [String: String]])
        let root = try #require(manifest["rootModelIdentifier"] as? String)
        #expect(entries[root]?["path"] == "com.apple.CoreML/model.mlmodel")
        #expect(try RepoFiles.data("\(Self.textPackage)/Data/com.apple.CoreML/model.mlmodel").count > 50_000)
        let weights = try RepoFiles.data("\(Self.textPackage)/Data/com.apple.CoreML/weights/weight.bin").count
        #expect(weights > 20_000_000 && weights < 30_000_000)
    }

    /// The tokenizer and the room's word list are knit-next's files, byte for byte (`tools/models/toxicity/common.py`
    /// pins the same hashes), so both phones read a message the same way.
    @Test func theTokenizerAndTheWordListAreAndroids() throws {
        let pins = [
            "App/Models/ToxicityTokenizer.json": "77e18685566ddefc3267601b473a3c55aa6fa2735611e1eae67dee9a27e4d966",
            "App/Models/Profanity.txt": "33f3ecf64ef23f819508a5b4fb5df58843f8ca2bf430392c6b5a3faab2de9ff5",
        ]
        for (path, pinned) in pins {
            let digest = SHA256.hash(data: try RepoFiles.data(path)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == pinned, "\(path) is no longer knit-next's file")
        }
    }
}
