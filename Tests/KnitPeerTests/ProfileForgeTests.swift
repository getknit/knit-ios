import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's `pad-profile` forge (ADR 2026-10.r88m, "The door"): our own profile, signed once at exactly the length
/// asked for, under the one id shape the router admits, every field but the status and version as the engine emitted
/// them; and an honest engine taking it as a phone would: the cap pins with its status cut, a byte over is refused at the
/// door, and the next honest edit outranks it.
@Suite(.timeLimit(.minutes(1))) struct ProfileForgeTests {
    private let keys = identity(1)
    private let photo = fixtureBytes(2000, seed: 9)

    /// An engine for ``keys`` that has published a photo and an edit, its clock then a second on.
    private struct Published {
        let engine: MeshEngine
        let clock: SteppingClock
        var stores: MeshStores { engine.stores }
        var own: OwnProfile { engine.stores.ownProfile.load() }

        /// What custody holds as our current profile.
        var frame: CarriedFrame? {
            stores.custody.frame(
                FrameId.profileId(sender: engine.nodeId.string, publishedAt: own.publishedAt), now: clock.wallMilliseconds())
        }

        func forge(_ signedBytes: Int) throws(ProfileForge.Refusal) -> ProfileForge.Forged {
            try ProfileForge.forge(
                signedBytes: signedBytes,
                own: own,
                custody: stores.custody,
                kept: stores.ownProfile.keptFrame(),
                identity: identity(1),
                now: clock.wallMilliseconds()
            )
        }
    }

    private func published() -> Published {
        let clock = SteppingClock()
        let engine = MeshEngine(
            identity: keys,
            deviceTag: "0123456789abcdef",
            stores: .inMemory(ownProfile: OwnProfile(name: "Liar")),
            transport: CapturingTransport(peer: identity(2).nodeId),
            clock: clock,
            random: CountingGenerator()
        )
        engine.start()
        engine.setAvatar(photo)
        clock.advance(by: 10)
        engine.updateProfile(name: "Liar", status: "lying low", openToChat: true)
        clock.advance(by: 1000)
        return Published(engine: engine, clock: clock)
    }

    private func receiver(_ seed: Int) -> MeshEngine {
        MeshEngine(
            identity: identity(seed),
            deviceTag: nil,
            stores: .inMemory(ownProfile: OwnProfile(name: "Phone")),
            transport: CapturingTransport(peer: keys.nodeId),
            clock: StillClock(),
            random: CountingGenerator()
        )
    }

    private func deliver(_ wire: WireEnvelope, to engine: MeshEngine) throws {
        engine.receive(InboundFrame(wire: wire, envelope: try RelayEnvelope(decoding: wire.signed), from: keys.nodeId))
    }

    @Test(arguments: [8192, 8193, 1024, 4096, 20_000])
    func theForgeIsOurProfileAtExactlyTheLengthSignedOnce(signedBytes: Int) throws {
        let liar = published()
        let own = liar.own
        let original = try #require(liar.frame)
        let forged = try liar.forge(signedBytes)

        #expect(forged.wire.signed.count == signedBytes && forged.signedBytes == signedBytes)
        #expect(keys.bundle.isValidSignature(forged.wire.sig, for: forged.wire.signed), "signed by our key")
        #expect(forged.wire.relay && forged.wire.ttl == WireEnvelope.defaultTTL && forged.wire.hops == 0, "flooded, as an edit is")
        let envelope = try RelayEnvelope(decoding: forged.wire.signed)
        #expect(FrameId.admits(envelope), "the router's id gate lets it through")
        let now = liar.clock.wallMilliseconds()
        #expect(envelope.id == forged.id && forged.id == FrameId.profileId(sender: keys.nodeId.string, publishedAt: now))
        #expect(envelope.sentAt == forged.publishedAt && forged.publishedAt == now && envelope.type == .profile)
        #expect(envelope.senderId == keys.nodeId.string && envelope.recipientId == nil && envelope.group == nil)

        var content = try ProfileContent(decoding: envelope.payload)
        let emitted = try ProfileContent(decoding: original.envelope.payload)
        #expect(content.version == now && forged.version == now && now > own.version, "a version above ours")
        let padding = content.status.dropFirst(emitted.status.count)
        #expect(content.status.hasPrefix(emitted.status) && !padding.isEmpty && padding.allSatisfy { $0 == ProfileForge.paddingLetter })
        content.status = emitted.status
        content.version = emitted.version
        #expect(content == emitted, "every other field as the engine emitted it")
        #expect(emitted.avatarHash == BlobHash(of: photo).string && emitted.deviceTag == "0123456789abcdef" && emitted.openToChat)

        #expect(liar.own == own, "the forge saves nothing")
        liar.clock.advance(by: 1)
        liar.engine.updateProfile(name: own.name, status: own.status, openToChat: own.openToChat)
        #expect(liar.own.version > forged.version && liar.own.publishedAt > forged.publishedAt, "the next honest edit outranks it")
    }

    @Test func theForgeRefusesUnlessOurVersionIsBelowTheClock() throws {
        let liar = published()
        let own = liar.own
        #expect(throws: ProfileForge.Refusal.versionNotBehindClock(version: own.version, now: own.version)) {
            try ProfileForge.forge(
                signedBytes: 8192, own: own, custody: liar.stores.custody, kept: .absent, identity: keys, now: own.version)
        }
        #expect(throws: ProfileForge.Refusal.versionNotBehindClock(version: own.version, now: own.version - 1)) {
            try ProfileForge.forge(
                signedBytes: 8192, own: own, custody: liar.stores.custody, kept: .absent, identity: keys, now: own.version - 1)
        }
    }

    @Test func theForgeFailsLoudlyWhenCustodyLostOurProfileAndNoneIsKept() throws {
        let liar = published()
        let own = liar.own
        let now = liar.clock.wallMilliseconds()
        let id = FrameId.profileId(sender: keys.nodeId.string, publishedAt: own.publishedAt)
        #expect(throws: ProfileForge.Refusal.noProfileInCustody(id: id)) {
            try ProfileForge.forge(
                signedBytes: 8192, own: own, custody: MeshStores.inMemory().custody, kept: .absent, identity: keys, now: now)
        }
        #expect(throws: ProfileForge.Refusal.noProfileInCustody(id: id)) {
            try ProfileForge.forge(
                signedBytes: 8192, own: own, custody: MeshStores.inMemory().custody, kept: .unreadable, identity: keys, now: now)
        }
        var unpublished = own
        unpublished.publishedAt -= 1
        let other = FrameId.profileId(sender: keys.nodeId.string, publishedAt: unpublished.publishedAt)
        #expect(throws: ProfileForge.Refusal.noProfileInCustody(id: other)) {
            try ProfileForge.forge(
                signedBytes: 8192,
                own: unpublished,
                custody: liar.stores.custody,
                kept: liar.stores.ownProfile.keptFrame(),
                identity: keys,
                now: now
            )
        }
        let held = try #require(liar.frame)
        var flipped = held.reserved
        flipped.sig[0] ^= 0x01
        #expect(throws: ProfileForge.Refusal.noProfileInCustody(id: id), "a kept frame whose signature fails is not read") {
            try ProfileForge.forge(
                signedBytes: 8192, own: own, custody: MeshStores.inMemory().custody, kept: .kept(flipped), identity: keys, now: now)
        }
    }

    /// knit-peer keeps custody in memory, so after a restart our profile is in the kept frame alone (ADR 2026-11.xfcq): the
    /// forge reads it there, every field as the engine emitted it.
    @Test func theForgeReadsTheKeptFrameWhenCustodyLostOurProfile() throws {
        let liar = published()
        let own = liar.own
        let held = try #require(liar.frame)
        #expect(liar.stores.ownProfile.keptFrame() == .kept(held.reserved), "the engine kept what it published")
        let forged = try ProfileForge.forge(
            signedBytes: 4096,
            own: own,
            custody: MeshStores.inMemory().custody,
            kept: liar.stores.ownProfile.keptFrame(),
            identity: keys,
            now: liar.clock.wallMilliseconds()
        )
        var content = try ProfileContent(decoding: try RelayEnvelope(decoding: forged.wire.signed).payload)
        let emitted = try ProfileContent(decoding: held.envelope.payload)
        content.status = emitted.status
        content.version = emitted.version
        #expect(content == emitted && forged.signedBytes == 4096)
    }

    /// Custody holds a frame under our profile's id that is no profile of ours: one whose payload does not read, and one
    /// of another type. Neither is forged from.
    @Test func theForgeRefusesAFrameUnderOurIdThatIsNotOurProfile() throws {
        let liar = published()
        let own = liar.own
        let now = liar.clock.wallMilliseconds()
        let id = FrameId.profileId(sender: keys.nodeId.string, publishedAt: own.publishedAt)
        for type in [FrameType.profile, .chat] {
            let custody = MeshStores.inMemory().custody
            let envelope = RelayEnvelope(type: type, id: id, senderId: keys.nodeId.string, sentAt: own.publishedAt, payload: [0x00])
            let signed = envelope.encoded
            let stored = custody.store(
                CarriedFrame(envelope: envelope, sig: try keys.signature(for: signed), signed: signed), origin: .own, now: now)
            #expect(stored.held, "custody holds it")
            #expect(throws: ProfileForge.Refusal.unreadableProfile(id: id)) {
                try ProfileForge.forge(signedBytes: 8192, own: own, custody: custody, kept: .absent, identity: keys, now: now)
            }
        }
        #expect(ProfileForge.Refusal.unreadableProfile(id: id).description == "the frame held as \(id) is not our profile")
        #expect(ProfileForge.Refusal.signing.description == "the identity refused to sign the forged profile")
    }

    /// Every length from 1 on is either hit exactly or refused: below the shortest forge, and the byte a CBOR length header
    /// skips as the status passes 23 and 255 letters.
    @Test func aLengthTheForgeCannotHitExactlyIsRefused() throws {
        let liar = published()
        var hit: [Int] = []
        var refused: [Int] = []
        for length in 1...1500 {
            do {
                let forged = try liar.forge(length)
                #expect(forged.wire.signed.count == length)
                hit.append(length)
            } catch {
                #expect(error == .unreachableLength(signedBytes: length))
                refused.append(length)
            }
        }
        let shortest = try #require(hit.first)
        #expect(refused.contains(1) && refused.contains(shortest - 1))
        #expect(refused.contains { $0 > shortest }, "a header's widening skips a length")
        #expect(refused.filter { $0 > shortest }.count <= 4, "and only a few")
    }

    /// An honest engine takes the forges as a phone does (contract case 4): one a byte over the cap is refused before
    /// verify and leaves no row, pin or custody row; one at the cap pins with its status cut; our next honest edit outranks
    /// it, and a re-serve of the forge is then stale, on the same phone and on one that hears them the other way round.
    @Test func anHonestEngineRefusesOneByteOverPinsTheCapAndTakesTheHonestEditAfter() throws {
        let liar = published()
        let phone = receiver(2)
        let over = try liar.forge(8193)
        try deliver(over.wire, to: phone)
        #expect(phone.profileOversizeRefused == 1)
        #expect(phone.stores.peers.peer(keys.nodeId) == nil, "no row, so no pin")
        #expect(phone.stores.peers.profileFrame(of: keys.nodeId) == nil, "no proof")
        #expect(!phone.stores.custody.contains(over.id), "no custody row")

        liar.clock.advance(by: 1)
        let atCap = try liar.forge(8192)
        try deliver(atCap.wire, to: phone)
        #expect(phone.profileOversizeRefused == 1)
        let pinned = try #require(phone.stores.peers.peer(keys.nodeId), "the cap pins")
        #expect(pinned.status.utf16.count == TextLimits.status && pinned.status.hasPrefix("lying low"), "its status cut")
        #expect(pinned.updatedAt == atCap.version && phone.stores.custody.contains(atCap.id))

        liar.clock.advance(by: 1)
        let own = liar.own
        liar.engine.updateProfile(name: own.name, status: own.status, openToChat: own.openToChat)
        let honest = try #require(liar.frame)
        try deliver(honest.reserved, to: phone)
        let row = try #require(phone.stores.peers.peer(keys.nodeId))
        #expect(row.status == "lying low" && row.updatedAt > atCap.version, "the honest profile wins")

        try deliver(atCap.wire, to: phone)
        #expect(phone.stores.peers.peer(keys.nodeId) == row, "a re-serve changes nothing")

        let late = receiver(3)
        try deliver(honest.reserved, to: late)
        let first = try #require(late.stores.peers.peer(keys.nodeId))
        try deliver(atCap.wire, to: late)
        #expect(late.stores.peers.peer(keys.nodeId) == first && first.status == "lying low", "the forge is stale behind it")
    }
}
