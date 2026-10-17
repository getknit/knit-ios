import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Carol's ratchet entries in `ios-emitted-v1.json` (ADR 2026-10.5sk9's P7b amendment, the iOS half of companion change
/// A10): built from one run of her engine (``EmittedRatchetFrames``), with what a reader needs to open them
/// (``EmittedRatchetReplay``).
extension EmittedRatchetFrames {
    /// The entries and the section one run makes, and what the run sent.
    struct Vectors {
        var frames: [String: VectorFrame]
        var section: EmittedRatchet
        var made: Made
    }

    /// The ratchet entries for the file, each keeping the committed frame's wire while it is still current, so a rewrite
    /// moves only what changed.
    static func vectors(carol: IdentityKeys, alice: IdentityKeys, bob: IdentityKeys, committed: EmittedVectors?) throws -> Vectors {
        let made = try make(carol: carol, alice: alice, bob: bob)
        let opened = try EmittedRatchetReplay.replay(made.frames, carol: carol, alice: alice, bob: bob)
        let names = EmittedRatchetReplay.names(carol: carol, alice: alice, bob: bob)
        var frames: [String: VectorFrame] = [:]
        for name in Name.engineFrames {
            let frame = try #require(made.frames[name])
            let fresh = try EmittedRatchetReplay.entry(frame, opened: try #require(opened.plaintexts[name]), names: names)
            let kept = committed?.frames[name].map(\.wire).flatMap { isCurrent($0, signed: frame.wire.signed, by: carol.bundle) ? $0 : nil }
            frames[name] = kept.map(fresh.carrying) ?? fresh
        }
        let profileWire =
            try committed?.frames[Name.profile].map(\.wire).flatMap { isCurrentProfile($0, of: carol) ? $0 : nil }
            ?? signedWire(try profileFrame(of: carol), by: carol)
        frames[Name.profile] = VectorFrame(
            sender: "carol", prekey: "carolSpk1", capabilities: ratchetCapabilities, version: profileVersion, wire: profileWire)

        let reply = made.bobReply
        let replayed = try #require(opened.sealed[Name.bobReply])
        #expect(replayed.wire.signed == reply.wire.signed, "a fresh Bob's reply is the run's, byte for byte")
        let committedReply = committed?.ratchet?.seals[Name.bobReply]?.wire
        let replyWire =
            committedReply.flatMap { isCurrent($0, signed: reply.wire.signed, by: bob.bundle) ? $0 : nil } ?? Hex.encode(reply.wire.encoded)
        let seal = EmittedRatchet.Seal(
            sender: "bob",
            recipient: "carol",
            id: bobReplyId,
            sentAt: reply.envelope.sentAt,
            body: replyBody,
            version: EncEnvelope.Version.compactRatchet,
            draws: [EmittedRatchet.Draw(kind: "keyPair", seed: bobReplySeed)],
            plaintext: Hex.encode(MessageContent(body: replyBody).sealBytes(v3: true).plaintext),
            wire: replyWire
        )
        let section = EmittedRatchet(
            about: EmittedRatchetReplay.about,
            prekeys: try EmittedRatchetReplay.prekeys(),
            carolDraws: made.draws,
            seals: [Name.bobReply: seal],
            replay: EmittedRatchetReplay.steps
        )
        return Vectors(frames: frames, section: section, made: made)
    }

    /// `relay` signed by `sender`, as hex.
    static func signedWire(_ relay: RelayEnvelope, by sender: IdentityKeys) throws -> String {
        let signed = relay.encoded
        return Hex.encode(WireEnvelope(sig: try sender.signature(for: signed), signed: signed).encoded)
    }
}

/// An entry the run did not make.
private struct Missing: Error, CustomStringConvertible {
    let name: String

    var description: String { "the run made no \(name)" }
}

extension EmittedVectorTests {
    /// Carol's ratchet entries must be what her engine sends today, short of a signature: every frame but the profile is
    /// rebuilt from the same draws and compared byte for byte below the signature, which is verified.
    @Test(.disabled(if: VectorFile.writing))
    func theCommittedRatchetFramesAreCurrent() throws {
        let committed = try #require(EmittedVectors.committed, "run the tests with KNIT_WRITE_VECTORS=1 to write the file")
        let (carol, alice, bob) = (try carol(), try keyed("alice"), try bob())
        let fresh = try EmittedRatchetFrames.vectors(carol: carol, alice: alice, bob: bob, committed: committed)
        for (name, entry) in fresh.frames.sorted(by: { $0.key < $1.key }) {
            #expect(committed.frames[name] == entry, "\(name) \(Self.stale)")
        }
        #expect(committed.ratchet == fresh.section, "the ratchet section \(Self.stale)")
    }

    /// The committed frames open as each reader's steps say, to the plaintext each entry names, through this port's Android
    /// stand-ins: what knit-next's `IosEmittedVectorTest` asks of them with Android's.
    @Test(.disabled(if: VectorFile.writing))
    func bobAndAliceOpenTheCommittedRatchetFrames() throws {
        let committed = try #require(EmittedVectors.committed, "run the tests with KNIT_WRITE_VECTORS=1 to write the file")
        let section = try #require(committed.ratchet, "the file carries the ratchet section")
        let (carol, alice, bob) = (try carol(), try keyed("alice"), try bob())
        var frames: [String: Written] = [:]
        for name in EmittedRatchetFrames.Name.engineFrames {
            frames[name] = try EmittedRatchetReplay.written(try #require(committed.frames[name]).wire)
        }
        let opened = try EmittedRatchetReplay.replay(frames, steps: section.replay, carol: carol, alice: alice, bob: bob)
        let names = EmittedRatchetReplay.names(carol: carol, alice: alice, bob: bob)
        for name in EmittedRatchetFrames.Name.engineFrames {
            let entry = try #require(committed.frames[name]?.sealed)
            let bytes = try #require(opened.plaintexts[name], "\(name) was opened")
            #expect(Hex.encode(bytes) == entry.plaintext, "\(name) opens to its plaintext")
            let content = try #require(entry.version == 3 ? MessageContentV2.decode(bytes) : try MessageContent(decoding: bytes))
            #expect(EmittedRatchetReplay.content(content, names: names) == entry.content, "\(name) carries its fields")
        }
        let seal = try #require(section.seals[EmittedRatchetFrames.Name.bobReply])
        let sealed = try #require(opened.sealed[EmittedRatchetFrames.Name.bobReply])
        #expect(try EmittedRatchetReplay.written(seal.wire).wire.signed == sealed.wire.signed, "Bob's own seal is the listed one")
    }

    /// Bob's engine pins Carol's committed profiles in the file's order, as an Android phone that meets both does: the v1
    /// profile pins no prekey and no ratchet bit, and the ratchet profile, newer on both watermarks, pins carolSpk1 and the
    /// flip's bits, whatever Bob's own switch says (`crypto.md`, "Taking a peer's prekey in").
    @Test(.disabled(if: VectorFile.writing))
    func bobsEnginePinsCarolsCommittedRatchetProfile() throws {
        let committed = try #require(EmittedVectors.committed, "run the tests with KNIT_WRITE_VECTORS=1 to write the file")
        let (carol, bob) = (try carol(), try bob())
        let prekey = try #require(committed.ratchet?.prekeys["carolSpk1"])
        for ratchet in [false, true] {
            let fixture = EngineFixture(TestPeer(keys: bob), configuration: MeshConfiguration(ratchet: ratchet))
            let sender = TestPeer(keys: carol)
            let v1 = try EmittedRatchetReplay.written(try #require(committed.frames["carolProfile"]).wire)
            fixture.engine.receive(InboundFrame(wire: v1.wire, envelope: v1.envelope, from: sender.nodeId))
            #expect(fixture.stores.peers.peer(carol.nodeId)?.prekey == nil, "the v1 profile pins no prekey")
            #expect(fixture.stores.peers.peer(carol.nodeId)?.capabilities == Self.v1Capabilities)
            let entry = try #require(committed.frames[EmittedRatchetFrames.Name.profile])
            let frame = try EmittedRatchetReplay.written(entry.wire)
            fixture.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: sender.nodeId))
            let pinned = try #require(fixture.stores.peers.peer(carol.nodeId))
            #expect(pinned.prekey?.id == prekey.id && pinned.prekey.map { Hex.encode($0.pub) } == prekey.pub, "carolSpk1 pinned")
            #expect(pinned.prekeyProfileAt == entry.version && pinned.capabilities == entry.capabilities && entry.capabilities == 0x15F)
            #expect(pinned.name == EmittedRatchetFrames.profileName && pinned.status == EmittedRatchetFrames.profileStatus)
        }
    }

    /// A fresh run's entries, and the facts of the seal `name`.
    private func sealed(_ name: String, in built: EmittedRatchetFrames.Vectors) throws -> VectorSealed {
        guard let entry = built.frames[name]?.sealed else {
            throw Missing(name: name)
        }
        return entry
    }

    /// What each of Carol's ratchet DMs to Bob says, against the run that makes it: the forms, the headers and the fields.
    @Test func carolsRatchetDMsSayWhatTheScenarioDid() throws {
        let (carol, alice, bob) = (try carol(), try keyed("alice"), try bob())
        let built = try EmittedRatchetFrames.vectors(carol: carol, alice: alice, bob: bob, committed: nil)
        typealias Name = EmittedRatchetFrames.Name
        typealias Frames = EmittedRatchetFrames
        let opener = try sealed(Name.dm, in: built)
        #expect(opener.version == 3 && opener.form == "dm" && opener.se == 1 && opener.pe == 0 && opener.n == 0)
        #expect(opener.initPrekey == "bobSpk1" && opener.content == VectorContent(body: Frames.dmBody))
        let inline = try sealed(Name.inlineAcks, in: built)
        #expect(inline.version == 3 && inline.se == 1 && inline.n == 1 && inline.initPrekey == "bobSpk1")
        #expect(inline.content == VectorContent(body: Frames.inlineBody, acks: [Frames.bobPostIds[0]]), "the first post's tick rides")
        let receipt = try sealed(Name.receipt, in: built)
        #expect(
            receipt.version == 3 && receipt.se == 2 && receipt.pe == 1 && receipt.n == 0 && receipt.initPrekey == nil,
            "Bob's reply confirmed")
        #expect(receipt.content == VectorContent(body: "", ctl: 5, ack: Frames.bobReplyId, acks: [Frames.bobPostIds[1]]))
        let profile = try sealed(Name.sealedProfile, in: built)
        let version = Frames.start + 6000
        #expect(profile.version == 3 && profile.se == 2 && profile.n == 1)
        #expect(
            profile.content.ctl == 8
                && profile.content.pr == .init(name: "Carol", status: Frames.profileStatus, version: version, openToChat: true))
        #expect(try sealed(Name.reaction, in: built).content.rp == .init(messageId: Frames.bobReplyId, emoji: Frames.reaction))
        let retraction = try sealed(Name.retraction, in: built).content.rp
        #expect(retraction == .init(messageId: Frames.bobReplyId, emoji: nil), "no emoji takes it back")
        #expect(try [Name.reaction, Name.retraction].map { try sealed($0, in: built).content.ctl } == [6, 6])
        let profileEntry = try #require(built.frames[Name.profile])
        #expect(Frames.isCurrentProfile(profileEntry.wire, of: carol) && profileEntry.capabilities == 0x15F)
    }

    /// What Carol's group seeds and group-form frames say, against the run that makes them, and the order her draws went.
    @Test func carolsGroupFormFramesSayWhatTheScenarioDid() throws {
        let (carol, alice, bob) = (try carol(), try keyed("alice"), try bob())
        let built = try EmittedRatchetFrames.vectors(carol: carol, alice: alice, bob: bob, committed: nil)
        typealias Name = EmittedRatchetFrames.Name
        typealias Frames = EmittedRatchetFrames
        let groupId = EmittedGroupFrames.roster(alice: alice, bob: bob, carol: carol).id
        let seed = VectorContent.Seed(epoch: 1, seed: Hex.encode(fixtureBytes(32, seed: 191)), mintedAt: Frames.start + 9000)
        let roster = VectorContent.Roster(id: groupId, members: ["alice", "bob", "carol"], createdBy: "carol")
        for (name, prekey, se) in [(Name.seedToAlice, "aliceSpk1", 1), (Name.seedToBob, nil, 2)] {
            let entry = try sealed(name, in: built)
            #expect(entry.version == 2 && entry.form == "dm" && entry.se == se && entry.initPrekey == prekey, "\(name) is named v2")
            #expect(entry.content == VectorContent(body: "", ctl: 2, gk: .init(groupId: groupId, keys: [seed], group: roster)), "\(name)")
        }
        let chat = try sealed(Name.groupChat, in: built)
        #expect(chat.version == 2 && chat.form == "group" && chat.se == 1 && chat.n == 0 && chat.pe == nil)
        #expect(chat.content == VectorContent(body: Frames.groupBody) && built.frames[Name.groupChat]?.groupId == groupId)
        let reaction = try sealed(Name.groupReaction, in: built)
        #expect(reaction.form == "group" && reaction.se == 1 && reaction.n == 1)
        #expect(
            reaction.content
                == VectorContent(body: "", ctl: 6, rp: .init(messageId: built.made.groupMessageId, emoji: Frames.groupReaction)))
        #expect(
            built.made.draws.map(\.seed) == [184, 185, 186, 191, 192, 187, 188, 189, 190, 193],
            "every draw, in order: the group seal mints before its seeds go")
    }

    /// The ratchet checks must be able to fail: a run at another clock is another set of frames, a profile with other bits
    /// or another prekey is stale, and a frame sealed to Bob does not open as Alice.
    @Test func theRatchetChecksTellACurrentFrameFromAStaleOne() throws {
        let (carol, alice, bob) = (try carol(), try keyed("alice"), try bob())
        let current = try EmittedRatchetFrames.make(carol: carol, alice: alice, bob: bob)
        let shifted = try EmittedRatchetFrames.make(carol: carol, alice: alice, bob: bob, wall: EmittedRatchetFrames.start + 1)
        for name in EmittedRatchetFrames.Name.engineFrames {
            let now = try #require(current.frames[name])
            let then = try #require(shifted.frames[name])
            let hex = Hex.encode(then.wire.encoded)
            #expect(EmittedRatchetFrames.isCurrent(Hex.encode(now.wire.encoded), signed: now.wire.signed, by: carol.bundle))
            #expect(!EmittedRatchetFrames.isCurrent(hex, signed: now.wire.signed, by: carol.bundle), "\(name) at another clock is stale")
            #expect(
                !EmittedRatchetFrames.isCurrent(Hex.encode(now.wire.encoded), signed: now.wire.signed, by: bob.bundle), "Bob signed none")
        }
        let profile = try EmittedRatchetFrames.profileFrame(of: carol)
        #expect(EmittedRatchetFrames.isCurrentProfile(try EmittedRatchetFrames.signedWire(profile, by: carol), of: carol))
        var v1Bits = try ProfileContent(decoding: profile.payload)
        v1Bits.capabilities = Self.v1Capabilities
        var stale = profile
        stale.payload = v1Bits.encoded
        #expect(!EmittedRatchetFrames.isCurrentProfile(try EmittedRatchetFrames.signedWire(stale, by: carol), of: carol), "other bits")
        var otherPrekey = try ProfileContent(decoding: profile.payload)
        let otherPair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: 9))
        otherPrekey.prekey = try SignedPrekey.mint(id: 1, signedBy: carol, createdAt: 0) { otherPair }.info
        stale.payload = otherPrekey.encoded
        #expect(!EmittedRatchetFrames.isCurrentProfile(try EmittedRatchetFrames.signedWire(stale, by: carol), of: carol), "another prekey")
        let v1Profile = try #require(EmittedVectors.committed?.frames["carolProfile"])
        #expect(!EmittedRatchetFrames.isCurrentProfile(v1Profile.wire, of: carol), "the v1 profile carries no prekey")

        let toBob = try #require(current.frames[EmittedRatchetFrames.Name.dm])
        let reader = try EmittedRatchetReplay.alice(alice)
        #expect(plaintext(try reader.android.open(toBob, from: TestPeer(keys: carol), now: toBob.envelope.sentAt)) == nil, "not Alice's")
    }
}
