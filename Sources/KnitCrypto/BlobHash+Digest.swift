import Crypto
public import KnitWire

extension BlobHash {
    /// The content address of `bytes`: their SHA-256 as lowercase hex (`sha256Hex`, `mesh/BlobHash.kt:20`), which a
    /// FILE_HEADER's key, a profile's `avatarHash` and a `blobreq` all name.
    public init(of bytes: [UInt8]) {
        self.init(computedDigest: Array(SHA256.hash(data: bytes)))
    }
}
