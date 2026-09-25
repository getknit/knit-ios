import Foundation
import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// Node ids, bundles and identity keys, against knit-next's `NodeIdTest`, `PublicKeyBundleTest`,
/// `GoldenVectorTest` and `ContactCardTest`.
@Suite struct IdentityTests {
    /// `NodeIdTest.goldenIdsAreStable`: the salt, the digest and the base32 mapping.
    @Test(arguments: [
        ("android-id-123", "ffbbh6thbepahqxsv2gqog45m4"),
        ("0123456789abcdef", "4sdvhqyrkpj3vccencfotsiiua"),
        ("aaaaaaaaaaaaaaaa", "ugtomq2rcpjfgs2o5co7ckukky"),
        ("", "wnuon3pfxkl6auzh2ngvinfc3i"),
    ])
    func nodeIdsDeriveAsKnitNextDerivesThem(seed: String, expected: String) {
        #expect(NodeId(deriving: seed).string == expected)
    }

    @Test func distinctSeedsGiveDistinctCanonicalIds() {
        let ids = (1...2000).map { NodeId(deriving: "bundle-\($0)") }
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(NodeId(id.string) == id, "every derived id is canonical")
            #expect(NodeId(bytes: id.bytes) == id)
        }
        #expect(NodeId(deriving: "9774d56d682e549c").string != "9774d56d682e549c")
    }

    /// `GoldenVectorTest`'s probe: an independent encoder of the raw-key layout, which is what this port is.
    @Test func theBundleProbeEncodesAndDerivesAsKnitNext() throws {
        let probe = GoldenVectors.file.bundle
        let bundle = try #require(
            PublicKeyBundle(signingKey: fixtureBytes(32, seed: 10), agreementKey: fixtureBytes(32, seed: 20))
        )
        #expect(bundle.encoded == probe.encoded)
        #expect(bundle.nodeId.string == probe.nodeId)
        #expect(PublicKeyBundle(encoded: probe.encoded) == bundle)
    }

    /// `ContactCardTest`'s identity: an Ed25519 seed of `bytes(32, 1)` and an X25519 scalar of `bytes(32, 2)`.
    @Test func theCardIdentityDerivesKnitNextsBundleAndNodeId() throws {
        let identity = try #require(
            IdentityKeys(signingSeed: fixtureBytes(32, seed: 1), agreementScalar: fixtureBytes(32, seed: 2))
        )
        #expect(
            identity.bundle.encoded
                == "omZzaWdQdWJYIOQDCZjP1a0XI8Fp+VaqC564YZtZkr1hLCr0KOvHn43wZ2hwa2VQdWJYIHPnmXHJEQApcjYyqAtwe/T2LBJXYzRuHocY1sDcw6o6"
        )
        #expect(identity.nodeId.string == "4cgq2pnhh6p3j3afwsue3chrpi")
        #expect(identity.signingSeed == fixtureBytes(32, seed: 1))
        #expect(identity.agreementScalar == fixtureBytes(32, seed: 2))
    }

    @Test func aBundleParsesOnlyAsTwoThirtyTwoByteKeys() {
        #expect(PublicKeyBundle(encoded: "not-a-bundle") == nil)
        #expect(PublicKeyBundle(encoded: "") == nil)
        let short = PublicKeyBundleProto(sigPub: fixtureBytes(31, seed: 1), hpkePub: fixtureBytes(32, seed: 2))
        #expect(PublicKeyBundle(encoded: Base64.encode(short.encoded)) == nil)
        let trailing = PublicKeyBundleProto(sigPub: fixtureBytes(32, seed: 1), hpkePub: fixtureBytes(32, seed: 2)).encoded + [0]
        #expect(PublicKeyBundle(encoded: Base64.encode(trailing)) == nil)
        #expect(PublicKeyBundle(signingKey: fixtureBytes(31, seed: 1), agreementKey: fixtureBytes(32, seed: 2)) == nil)
        #expect(PublicKeyBundle(signingKey: fixtureBytes(32, seed: 1), agreementKey: []) == nil)
    }

    /// `PublicKeyBundleTest`: a re-parsed bundle equals itself, a rebuilt one reproduces the text, and different
    /// keys never compare equal.
    @Test func bundlesAreEqualByTheirText() throws {
        let bundle = IdentityKeys.generate().bundle
        let reparsed = try #require(PublicKeyBundle(encoded: bundle.encoded))
        #expect(reparsed == bundle)
        #expect(reparsed.hashValue == bundle.hashValue)
        #expect(PublicKeyBundle(signingKey: bundle.signingKey, agreementKey: bundle.agreementKey) == bundle)
        #expect(IdentityKeys.generate().bundle != bundle)
        #expect(Base64.decode(bundle.encoded)?.count == 84)
        #expect(bundle.encoded.utf8.count == 112)
    }

    @Test func identityKeysRefuseWrongLengths() {
        #expect(IdentityKeys(signingSeed: fixtureBytes(31, seed: 1), agreementScalar: fixtureBytes(32, seed: 2)) == nil)
        #expect(IdentityKeys(signingSeed: fixtureBytes(32, seed: 1), agreementScalar: fixtureBytes(33, seed: 2)) == nil)
    }

    @Test func theStoredFormRoundTrips() throws {
        let identity = IdentityKeys.generate()
        let restored = try #require(IdentityKeys(storedForm: identity.storedForm))
        #expect(restored.bundle == identity.bundle)
        #expect(IdentityKeys(storedForm: []) == nil)
        #expect(IdentityKeys(storedForm: CBOR.text("identity").encoded) == nil)
        let missingScalar = CBOR.map([CBOR.Entry(key: .text("signingSeed"), value: .bytes(fixtureBytes(32, seed: 1)))])
        #expect(IdentityKeys(storedForm: missingScalar.encoded) == nil)
        let textSeed = CBOR.map([
            CBOR.Entry(key: .text("signingSeed"), value: .text("seed")),
            CBOR.Entry(key: .text("agreementScalar"), value: .bytes(fixtureBytes(32, seed: 2))),
        ])
        #expect(IdentityKeys(storedForm: textSeed.encoded) == nil)
    }

    @Test func loadingCreatesOnceThenReadsBack() throws {
        let store = MemorySecretStore(secret: nil, refuses: false)
        let first = try IdentityKeys.load(from: store)
        #expect(first.origin == .created)
        #expect(store.contents == first.keys.storedForm)
        let second = try IdentityKeys.load(from: store)
        #expect(second.origin == .stored)
        #expect(second.keys.nodeId == first.keys.nodeId)
    }

    @Test func anUnreadableSecretIsReplacedAndAnUnavailableStoreIsNot() throws {
        let corrupt = MemorySecretStore(secret: [0xFF, 0x00], refuses: false)
        let replaced = try IdentityKeys.load(from: corrupt)
        #expect(replaced.origin == .replacedUnreadable)
        #expect(corrupt.contents == replaced.keys.storedForm)

        let locked = MemorySecretStore(secret: IdentityKeys.generate().storedForm, refuses: true)
        #expect(throws: SecretStoreError.unavailable("locked")) {
            try IdentityKeys.load(from: locked)
        }
    }

    @Test func aFileStoreKeepsItsSecretPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("knit-crypto-tests-\(IdentityKeys.generate().nodeId)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state/identity").path
        let store = FileSecretStore(path: path)
        #expect(try store.read() == nil)

        let loaded = try IdentityKeys.load(from: store)
        #expect(loaded.origin == .created)
        #expect(try store.read() == loaded.keys.storedForm)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try IdentityKeys.load(from: store).keys.nodeId == loaded.keys.nodeId)

        let blocked = FileSecretStore(path: path + "/beneath-a-file")
        #expect(throws: SecretStoreError.self) {
            try blocked.write([1])
        }
        let unreadable = FileSecretStore(path: directory.path)
        #expect(throws: SecretStoreError.self, "a directory is there, but no secret can be read from it") {
            try IdentityKeys.load(from: unreadable)
        }
    }
}
