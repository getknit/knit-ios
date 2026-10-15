import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// knit-next's ratchet known answers (`ratchet-v1.json`, companion change A9), each rebuilt with this port's
/// primitives: Alice's first exchange with Bob from both sides, the epochs and chains it starts, her first v3 frame's
/// nonce, the header bindings, both prekeys, the root tag, one group epoch, and the AES-GCM. Tink made the answers, so a
/// match here is a match with Android. Signatures are verified, never compared: CryptoKit randomizes Ed25519, and this
/// suite also runs on the Mac.
///
/// The file's `export` answers are not checked: the spool's exports are not in this port (ADR 2026-10.5sk9), and the
/// file marks them non-normative.
@Suite struct RatchetVectorTests {
    private let file = RatchetVectors.file
    private var kats: RatchetVectors.Kats { file.kats }

    private func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(file.identities[name])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
    }

    private func draw(_ name: String) throws -> RatchetVectors.Draw {
        try #require(kats.draws[name])
    }

    /// The draw whose public value is `pub`, for the side that holds its private half.
    private func draw(holding pub: String) throws -> RatchetVectors.Draw {
        try #require(kats.draws.values.first { $0.pub == pub })
    }

    @Test(arguments: ["alice", "bob", "carol"])
    func identitiesDeriveTheirBundlesAndNodeIds(name: String) throws {
        let entry = try #require(file.identities[name])
        let keys = try identity(name)
        #expect(keys.bundle.encoded == entry.bundle)
        #expect(keys.nodeId.string == entry.nodeId)
    }

    @Test func eachDrawIsFixtureBytesAndDerivesItsPublicValue() throws {
        #expect(kats.draws.count == 5)
        for (name, draw) in kats.draws {
            #expect(hexBytes(draw.priv) == fixtureBytes(32, seed: draw.seed), "\(name)")
            #expect(try RatchetCrypto.KeyPair(privateKey: hexBytes(draw.priv)).publicKey == hexBytes(draw.pub), "\(name)")
        }
    }

    /// The identity keys X3DH takes are the X25519 halves, `hpkePub` and its scalar, and both sides reach the root.
    @Test func bothSidesOfX3DHReachTheRoot() throws {
        let x3dh = kats.x3dh
        let initiator = try identity(x3dh.initiator)
        let responder = try identity(x3dh.responder)
        #expect(hexBytes(x3dh.initiate.ikPriv) == initiator.agreementScalar)
        #expect(hexBytes(x3dh.initiate.peerIkPub) == responder.bundle.agreementKey)
        #expect(x3dh.initiate.peerSpkPub == (try draw("bobSpk")).pub)
        #expect(x3dh.initiate.ekPriv == (try draw("aliceEph")).priv)
        #expect(hexBytes(x3dh.respond.ikPriv) == responder.agreementScalar)
        #expect(hexBytes(x3dh.respond.peerIkPub) == initiator.bundle.agreementKey)
        #expect(x3dh.respond.spkPriv == (try draw("bobSpk")).priv)
        #expect(x3dh.respond.peerEkPub == (try draw("aliceEph")).pub)

        let initiated = try RatchetCrypto.x3dhInitiate(
            ikPriv: hexBytes(x3dh.initiate.ikPriv),
            ekPriv: hexBytes(x3dh.initiate.ekPriv),
            peerIkPub: hexBytes(x3dh.initiate.peerIkPub),
            peerSpkPub: hexBytes(x3dh.initiate.peerSpkPub)
        )
        let responded = try RatchetCrypto.x3dhRespond(
            ikPriv: hexBytes(x3dh.respond.ikPriv),
            spkPriv: hexBytes(x3dh.respond.spkPriv),
            peerIkPub: hexBytes(x3dh.respond.peerIkPub),
            peerEkPub: hexBytes(x3dh.respond.peerEkPub)
        )
        #expect(initiated == hexBytes(x3dh.root))
        #expect(responded == hexBytes(x3dh.root))
    }

    /// Each epoch from the sender's side, and its exchange from the receiver's: the HKDF takes the exchange as input key
    /// material and the root as salt, and its info is the whole of `info`.
    @Test func eachEpochDerivesItsInfoAndBothHalves() throws {
        #expect(kats.deriveEpoch.count == 2)
        for epoch in kats.deriveEpoch {
            #expect(epoch.sessionRoot == kats.x3dh.root, "\(epoch.note)")
            #expect(try RatchetCrypto.KeyPair(privateKey: hexBytes(epoch.senderEpochPriv)).publicKey == hexBytes(epoch.senderEpochPub))
            #expect(try RatchetCrypto.dh(hexBytes(epoch.senderEpochPriv), hexBytes(epoch.basePub)) == hexBytes(epoch.dhShared))
            let base = try draw(holding: epoch.basePub)
            #expect(try RatchetCrypto.dh(hexBytes(base.priv), hexBytes(epoch.senderEpochPub)) == hexBytes(epoch.dhShared))
            #expect(epoch.dir == (epoch.senderIsInitiator ? "i" : "r"))

            let info = RatchetCrypto.epochInfo(senderIsInitiator: epoch.senderIsInitiator, senderEpoch: epoch.se, baseEpoch: epoch.pe)
            #expect(info == hexBytes(epoch.info), "\(epoch.note)")
            let keys = RatchetCrypto.deriveEpoch(
                sessionRoot: hexBytes(epoch.sessionRoot),
                dhShared: hexBytes(epoch.dhShared),
                senderIsInitiator: epoch.senderIsInitiator,
                senderEpoch: epoch.se,
                baseEpoch: epoch.pe
            )
            #expect(keys.chainKey == hexBytes(epoch.chainKey), "\(epoch.note)")
            #expect(keys.export == hexBytes(epoch.export), "\(epoch.note)")
            #expect(keys.chainKey + keys.export == hexBytes(epoch.okm), "\(epoch.note)")
        }
    }

    @Test func eachChainStepsFromItsEpochsChainKey() {
        #expect(kats.chain.count == 2)
        for (chain, epoch) in zip(kats.chain, kats.deriveEpoch) {
            #expect(chain.ck0 == epoch.chainKey, "\(chain.sender)")
            check(chain, messageKey: RatchetCrypto.messageKey, nextChainKey: RatchetCrypto.nextChainKey)
        }
    }

    /// Alice's first frame: its message key is her chain's at n 0, its AAD the v1 header, and its nonce derives from
    /// that key over the AAD with the header binding appended.
    @Test func theFirstV3FramesNonceDerivesFromItsKeyAndBoundAad() throws {
        let nonce = kats.messageNonce
        #expect(nonce.mk == (try #require(kats.chain.first?.steps.first)).mk)
        #expect(hexBytes(nonce.aad) == Array(nonce.aadText.utf8))
        let parts = nonce.aadText.split(separator: "|").map(String.init)
        try #require(parts.count == 4)
        let sentAt = try #require(Int64(parts[2]))
        #expect(MessageCrypto.header(id: parts[0], senderId: parts[1], sentAt: sentAt, thread: parts[3]) == hexBytes(nonce.aad))

        let binding = try #require(kats.headerBindingBytes[nonce.headerBinding])
        let boundAad = hexBytes(nonce.aad) + RatchetCrypto.headerBindingBytes(header(binding))
        #expect(boundAad == hexBytes(nonce.boundAad))
        #expect(RatchetCrypto.messageNonce(messageKey: hexBytes(nonce.mk), aad: boundAad) == hexBytes(nonce.nonce))
    }

    @Test func eachHeaderBindsToItsBytes() throws {
        #expect(kats.headerBindingBytes.count == 4)
        for (name, binding) in kats.headerBindingBytes {
            #expect(RatchetCrypto.headerBindingBytes(header(binding)) == hexBytes(binding.bytes), "\(name)")
        }
        // The init that rides is Alice's: her first epoch's key, her ephemeral and Bob's prekey 1.
        let first = try #require(kats.headerBindingBytes["initFlags0"])
        #expect(first.ek == (try draw("aliceEpoch1")).pub)
        #expect(first.initial?.eph == (try draw("aliceEph")).pub)
    }

    /// Tink signed each prekey; this port verifies the signature, takes the prekey in, and signs the same bytes.
    @Test func eachPrekeysSignedBytesVerifyAgainstItsOwner() throws {
        #expect(kats.spkSigningBytes.count == 2)
        for prekey in kats.spkSigningBytes {
            let owner = try identity(prekey.owner)
            let bytes = RatchetCrypto.spkSigningBytes(id: prekey.id, pub: hexBytes(prekey.pub))
            #expect(bytes == hexBytes(prekey.bytes), "\(prekey.owner)")
            #expect(owner.bundle.isValidSignature(hexBytes(prekey.sig), for: bytes), "\(prekey.owner)")
            let info = PrekeyInfo(id: prekey.id, pub: hexBytes(prekey.pub), sig: hexBytes(prekey.sig))
            #expect(PeerPrekey(verifying: info, signedBy: owner.bundle)?.publicKey == hexBytes(prekey.pub))

            let pair = try RatchetCrypto.KeyPair(privateKey: hexBytes(try draw("\(prekey.owner)Spk").priv))
            let ours = try SignedPrekey.mint(id: prekey.id, signedBy: owner, createdAt: 0) { pair }
            #expect(ours.publicKey == hexBytes(prekey.pub))
            #expect(owner.bundle.isValidSignature(ours.signature, for: hexBytes(prekey.bytes)))
        }
    }

    @Test func theRootTagIsTheRootsEightBytesReadBigEndian() {
        let tag = kats.rootTag
        #expect(tag.root == kats.x3dh.root)
        #expect(RatchetCrypto.rootTag(hexBytes(tag.root)) == tag.int64)
        let bytes = hexBytes(tag.bytes)
        #expect(bytes.count == 8)
        #expect(Int64(bitPattern: bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }) == tag.int64)
    }

    @Test func theGroupEpochDerivesFromItsSeedAndSteps() throws {
        let group = kats.group
        let members = try group.groupMembers.map { try identity($0).nodeId.string }
        #expect(GroupId.derive(members) == group.groupId)
        #expect(try identity(group.sender).nodeId.string == group.senderId)
        #expect(hexBytes(group.seed) == fixtureBytes(32, seed: group.seedSeed))

        #expect(GroupRatchetCrypto.epochInfo(groupId: group.groupId, senderId: group.senderId, epoch: group.epoch) == hexBytes(group.info))
        let keys = GroupRatchetCrypto.deriveEpoch(
            seed: hexBytes(group.seed), groupId: group.groupId, senderId: group.senderId, epoch: group.epoch)
        #expect(keys.chainKey == hexBytes(group.chainKey))
        #expect(keys.export == hexBytes(group.export))
        #expect(group.chain.ck0 == group.chainKey)
        check(group.chain, messageKey: GroupRatchetCrypto.messageKey, nextChainKey: GroupRatchetCrypto.nextChainKey)
    }

    @Test func theAesGcmSealIsTinksToTheByte() throws {
        let aes = kats.aesGcm
        let sealed = try RatchetCrypto.seal(
            hexBytes(aes.plaintext), key: hexBytes(aes.key), nonce: hexBytes(aes.iv), aad: hexBytes(aes.aad))
        #expect(sealed == hexBytes(aes.sealed))
        #expect(
            RatchetCrypto.open(hexBytes(aes.sealed), key: hexBytes(aes.key), nonce: hexBytes(aes.iv), aad: hexBytes(aes.aad))
                == hexBytes(aes.plaintext))
    }

    private func header(_ binding: RatchetVectors.HeaderBinding) -> RatchetHeader {
        RatchetHeader(
            se: binding.se,
            ek: hexBytes(binding.ek),
            pe: binding.pe,
            n: binding.n,
            initial: binding.initial.map { RatchetInit(eph: hexBytes($0.eph), pkid: $0.pkid, at: $0.at) },
            flags: binding.flags
        )
    }

    private func check(_ chain: RatchetVectors.Chain, messageKey: ([UInt8]) -> [UInt8], nextChainKey: ([UInt8]) -> [UInt8]) {
        #expect(chain.steps.map(\.n) == [0, 1, 2, 3], "\(chain.sender)")
        var chainKey = hexBytes(chain.ck0)
        for step in chain.steps {
            #expect(chainKey == hexBytes(step.ck), "\(chain.sender) step \(step.n)")
            #expect(messageKey(chainKey) == hexBytes(step.mk), "\(chain.sender) step \(step.n)")
            chainKey = nextChainKey(chainKey)
            #expect(chainKey == hexBytes(step.nextCk), "\(chain.sender) step \(step.n)")
        }
    }
}
