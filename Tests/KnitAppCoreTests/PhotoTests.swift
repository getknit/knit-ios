import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A picture the fake codec decoded: only its size matters here.
struct FakeImage: PreparedImage {
    let pixelWidth: Int
    let pixelHeight: Int
}

/// A codec that reads any bytes as a 640 by 480 picture, unless told it cannot read, and crops into a "JPEG" that
/// names the crop. Its chat photos fail with `refuses` when that is set.
struct FakeCodec: ImageCodec {
    var reads = true
    var crops = true
    var refuses: PhotoFailure?

    func prepare(_ data: Data) -> (any PreparedImage)? {
        reads && !data.isEmpty ? FakeImage(pixelWidth: 640, pixelHeight: 480) : nil
    }

    func profilePhoto(from image: any PreparedImage, crop: CropRect) -> [UInt8]? {
        crops ? Array("\(image.pixelWidth)x\(image.pixelHeight) \(crop)".utf8) : nil
    }

    /// The picked bytes behind a marker, as a JPEG, so a test can tell what was prepared from what was picked.
    func chatPhoto(from data: Data) -> Result<OutgoingPhoto, PhotoFailure> {
        if let refuses {
            return .failure(refuses)
        }
        return reads && !data.isEmpty
            ? .success(OutgoingPhoto(bytes: Array("ready ".utf8) + Array(data), mime: "image/jpeg")) : .failure(.unreadable)
    }
}

/// Faces: who wears which photo and initial on every surface that names someone, and the user's own photo, chosen,
/// cropped, saved and removed (ADR 2026-10.nh55).
@MainActor
@Suite struct PhotoTests {
    private static let samPhoto = Array("Sam's photo".utf8)
    private static let myPhoto = Array("my photo".utf8)

    /// Pins Sam with a photo whose bytes are held, as the engine leaves him once his push lands.
    private func pinSamWithPhoto(_ rig: AppRig) async -> BlobHash {
        let hash = BlobHash(of: Self.samPhoto)
        rig.stores.blobs.insert(Self.samPhoto, hash: hash, mime: "image/jpeg", storedAt: 1)
        var sam = AppRig.sam.record(name: "Sam")
        sam.avatarHash = hash
        sam.advertisedAvatarHash = hash
        rig.stores.peers.upsert(sam)
        await rig.session.handle(.peerUpdated(AppRig.sam.nodeId))
        return hash
    }

    // MARK: Faces

    @Test func aPersonsFaceIsTheirPhotoOrTheirInitialOnTheirTint() async {
        let rig = AppRig()
        let photo = await pinSamWithPhoto(rig)
        let sam = rig.session.directory.face(for: AppRig.sam.nodeId)
        #expect(sam == .person(AppRig.sam.nodeId.string, name: "Sam", photo: photo))
        #expect(sam.kind == .person && sam.initial == "S" && sam.tint == AvatarTint.slot(for: AppRig.sam.nodeId.string))
        let stranger = rig.session.directory.face(for: AppRig.stranger.nodeId)
        #expect(stranger.photo == nil)
        #expect(stranger.initial == Monogram.initial(of: Alias.alias(for: AppRig.stranger.nodeId.string)), "a stranger's alias")
        let notAnId = rig.session.directory.face(forMember: "not a node id")
        #expect(notAnId.photo == nil && notAnId.initial.count == 1)
    }

    /// Our own face shows our photo, which our profile names; no peer row stands for us.
    @Test func ourOwnFaceShowsOurPhoto() async {
        let rig = AppRig()
        await rig.session.setAvatar(Self.myPhoto)
        let mine = rig.session.directory.face(for: rig.me)
        #expect(mine.photo == BlobHash(of: Self.myPhoto))
        #expect(rig.session.photo(BlobHash(of: Self.myPhoto)) == Self.myPhoto)
        #expect(rig.session.photo(BlobHash(of: Self.samPhoto)) == nil)
    }

    @Test func aGroupsFaceIsItsOtherMembersInNodeIdOrder() async {
        let rig = AppRig()
        let photo = await pinSamWithPhoto(rig)
        await rig.pin(AppRig.priya, name: "Priya")
        let group = await rig.group([AppRig.priya, AppRig.sam], createdBy: AppRig.priya)
        let face = rig.session.directory.face(of: group)
        #expect(face.kind == .group && face.key == group.id && face.photo == nil)
        let ids = [AppRig.sam, AppRig.priya].map(\.nodeId.string).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        #expect(face.members.map(\.key) == ids)
        #expect(face.members.first { $0.key == AppRig.sam.nodeId.string }?.photo == photo)
        let pair = await rig.group([AppRig.sam], createdBy: AppRig.sam)
        #expect(rig.session.directory.face(of: pair).members.isEmpty, "one other is the glyph, not a cluster")
    }

    // MARK: Where faces show

    @Test func theChatListShowsEachThreadsFace() async throws {
        let rig = AppRig()
        let photo = await pinSamWithPhoto(rig)
        await rig.pin(AppRig.priya, name: "Priya")
        await rig.receive("in the room", from: AppRig.priya.nodeId)
        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.receive("hi", from: AppRig.sam.nodeId, to: rig.me)
        let group = await rig.group([AppRig.priya, AppRig.sam], name: "Hikers", createdBy: AppRig.priya)
        // Sam, whom we accepted, writing in it is what takes it out of the requests.
        await rig.receive("hello group", from: AppRig.sam.nodeId, in: group)
        let rows = ChatListModel(session: rig.session).state.rows
        #expect(rows.first?.face == .room)
        #expect(try #require(rows.first { $0.id == AppRig.sam.nodeId.string }).face.photo == photo)
        #expect(try #require(rows.first { $0.id == group.id }).face == rig.session.directory.face(of: group))
    }

    @Test func aThreadShowsItsFaceAndTheFacesOfOthersBesideTheirMessages() async {
        let rig = AppRig()
        let photo = await pinSamWithPhoto(rig)
        await rig.receive("in the room", from: AppRig.sam.nodeId)
        _ = await rig.session.send("me too", in: Conversations.nearby)
        let room = ChatModel(conversationId: Conversations.nearby, session: rig.session).state
        #expect(room.face == .room)
        #expect(room.messages.first { !$0.isMine }?.authorFace?.photo == photo)
        #expect(room.messages.first(where: \.isMine)?.authorFace == nil, "our own messages wear no face")

        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.receive("hi", from: AppRig.sam.nodeId, to: rig.me)
        let direct = ChatModel(conversationId: AppRig.sam.nodeId.string, session: rig.session).state
        #expect(direct.face.photo == photo)
        #expect(direct.messages.allSatisfy { $0.authorFace == nil }, "a DM's title already says who")

        let group = await rig.group([AppRig.priya, AppRig.sam], createdBy: AppRig.priya)
        await rig.receive("hello group", from: AppRig.sam.nodeId, in: group)
        let thread = ChatModel(conversationId: group.id, session: rig.session).state
        #expect(thread.face == rig.session.directory.face(of: group))
        #expect(thread.messages.first { $0.body == "hello group" }?.authorFace?.photo == photo)
        #expect(thread.messages.filter { $0.notice != nil }.allSatisfy { $0.authorFace == nil }, "a status line wears none")
    }

    @Test func profilesGroupInfoRequestsContactsAndSettingsShowFaces() async throws {
        let rig = AppRig()
        let photo = await pinSamWithPhoto(rig)
        await rig.session.setAvatar(Self.myPhoto)
        #expect(PeerProfileModel(nodeId: AppRig.sam.nodeId, session: rig.session).state.face.photo == photo)

        let group = await rig.group([AppRig.priya, AppRig.sam], createdBy: AppRig.sam)
        let info = GroupInfoModel(groupId: group.id, session: rig.session).state
        #expect(info.face == rig.session.directory.face(of: group))
        #expect(info.members.first(where: \.isMe)?.face.photo == BlobHash(of: Self.myPhoto), "we wear our own photo there")
        #expect(info.members.first { $0.peer == AppRig.sam.nodeId }?.face.photo == photo)

        await rig.receive("hello?", from: AppRig.stranger.nodeId, to: rig.me)
        let requests = RequestsModel(session: rig.session).rows
        let stranger = try #require(requests.first { $0.id == AppRig.stranger.nodeId.string })
        #expect(stranger.face == rig.session.directory.face(for: AppRig.stranger.nodeId))
        #expect(try #require(requests.first { $0.id == group.id }).face == rig.session.directory.face(of: group))

        rig.stores.conversations.accept(AppRig.sam.nodeId.string)
        await rig.session.handle(.peerUpdated(AppRig.sam.nodeId))
        let contacts = NewMessageModel(session: rig.session).candidates
        #expect(contacts.first { $0.id == AppRig.sam.nodeId }?.face.photo == photo)

        let settings = SettingsModel(session: rig.session, permission: nil, about: AboutInfo(version: "1", build: "1"))
        #expect(settings.profileFace.photo == BlobHash(of: Self.myPhoto))
        #expect(ChatListModel(session: rig.session).ownFace == settings.profileFace)
    }

    /// The name page previews what peers will draw: the initial of the name as typed, or of the alias, on our tint.
    @Test func onboardingPreviewsTheFaceThePeersWillDraw() {
        let rig = AppRig()
        let model = OnboardingModel(session: rig.session, preferences: MemoryPreferences(hasOnboarded: false), permission: nil)
        #expect(model.face.initial == Monogram.initial(of: rig.session.identity.alias))
        model.name = "  robin"
        #expect(model.face.initial == "R")
        #expect(model.face.tint == AvatarTint.slot(for: rig.me.string))
    }

    // MARK: Our own photo

    @Test func aChosenPhotoIsCroppedAndWaitsForSave() async throws {
        let rig = AppRig()
        let model = OwnProfileModel(session: rig.session, codec: FakeCodec())
        #expect(!model.hasPhoto && model.face.photo == nil)
        await model.choosePhoto(Data("picked".utf8))
        let source = try #require(model.cropSource)
        #expect(model.isCropping && source.pixelWidth == 640 && source.pixelHeight == 480)
        var framing = AvatarFraming(sourceWidth: source.pixelWidth, sourceHeight: source.pixelHeight)
        framing.fit(width: 400, height: 800)
        await model.cropPhoto(framing)
        #expect(!model.isCropping && model.cropSource != nil, "the cropper keeps its picture as it closes")
        let jpeg = try #require(model.unsavedPhoto)
        #expect(jpeg == Array("640x480 \(CropRect(left: 80, top: 0, width: 480, height: 480))".utf8), "the center square")
        #expect(model.face.photo == BlobHash(of: jpeg) && model.hasPhoto && model.hasChanges)
        #expect(rig.mesh.calls.avatars.isEmpty, "nothing is published before Save")

        await model.save()
        #expect(rig.mesh.calls.avatars == [BlobHash(of: jpeg)])
        #expect(rig.mesh.calls.profiles.isEmpty, "the fields did not change, so only the photo is published")
        #expect(!model.hasChanges && model.unsavedPhoto == nil)
        #expect(rig.stores.ownProfile.load().avatarHash == BlobHash(of: jpeg))
    }

    @Test func aRemovedPhotoGoesAtSaveWithTheFieldsBesideIt() async {
        let rig = AppRig()
        await rig.session.setAvatar(Self.myPhoto)
        let model = OwnProfileModel(session: rig.session, codec: FakeCodec())
        #expect(model.hasPhoto && !model.hasChanges)
        model.removePhoto()
        #expect(!model.hasPhoto && model.face.photo == nil && model.hasChanges)
        model.name = "Robin"
        await model.save()
        #expect(rig.mesh.calls.avatars == [BlobHash(of: Self.myPhoto), nil])
        #expect(rig.mesh.calls.profiles == ["Robin||false"])
        #expect(rig.stores.ownProfile.load().avatarHash == nil)
    }

    /// Removing a photo picked and not yet saved goes back to none, which is no change.
    @Test func removingAnUnsavedPhotoIsNoChange() async {
        let rig = AppRig()
        let model = OwnProfileModel(session: rig.session, codec: FakeCodec())
        await model.choosePhoto(Data("picked".utf8))
        await model.cropPhoto(AvatarFraming(sourceWidth: 640, sourceHeight: 480))
        #expect(model.hasChanges)
        model.removePhoto()
        #expect(!model.hasChanges && !model.hasPhoto)
    }

    /// Cropping the published photo again to the same bytes is no change either.
    @Test func theSamePhotoAgainIsNoChange() async {
        let rig = AppRig()
        let model = OwnProfileModel(session: rig.session, codec: FakeCodec())
        await model.choosePhoto(Data("picked".utf8))
        await model.cropPhoto(AvatarFraming(sourceWidth: 640, sourceHeight: 480))
        await model.save()
        await model.choosePhoto(Data("picked".utf8))
        await model.cropPhoto(AvatarFraming(sourceWidth: 640, sourceHeight: 480))
        #expect(!model.hasChanges)
        #expect(rig.mesh.calls.avatars.count == 1)
    }

    @Test func aPhotoThatCannotBeReadOrCroppedSaysSoAndChangesNothing() async {
        let rig = AppRig()
        let unreadable = OwnProfileModel(session: rig.session, codec: FakeCodec(reads: false))
        await unreadable.choosePhoto(Data("picked".utf8))
        #expect(unreadable.photoFailed && !unreadable.isCropping && unreadable.cropSource == nil && !unreadable.hasChanges)

        let undelivered = OwnProfileModel(session: rig.session, codec: FakeCodec())
        await undelivered.choosePhoto(nil)
        #expect(undelivered.photoFailed, "the picker could not hand the photo over")

        let uncroppable = OwnProfileModel(session: rig.session, codec: FakeCodec(crops: false))
        await uncroppable.choosePhoto(Data("picked".utf8))
        await uncroppable.cropPhoto(AvatarFraming(sourceWidth: 640, sourceHeight: 480))
        #expect(uncroppable.photoFailed && !uncroppable.isCropping && !uncroppable.hasChanges)

        let codecless = OwnProfileModel(session: rig.session)
        await codecless.choosePhoto(Data("picked".utf8))
        #expect(codecless.photoFailed)
    }

    @Test func cancellingTheCropKeepsThePhotoAsItWas() async {
        let rig = AppRig()
        let model = OwnProfileModel(session: rig.session, codec: FakeCodec())
        await model.choosePhoto(Data("picked".utf8))
        model.cancelCrop()
        #expect(!model.isCropping && !model.hasChanges)
        await model.cropPhoto(AvatarFraming(sourceWidth: 640, sourceHeight: 480))
        #expect(!model.hasChanges, "with the cropper gone there is nothing to crop")
    }

    /// The face follows the name as typed, and the alias while it is blank.
    @Test func ourFaceFollowsTheNameAsTyped() {
        let rig = AppRig()
        let model = OwnProfileModel(session: rig.session, codec: FakeCodec())
        #expect(model.face.initial == Monogram.initial(of: rig.session.identity.alias))
        model.name = "zed"
        #expect(model.face.initial == "Z")
    }

    // MARK: The demo

    @Test func theLaunchOptionsReadTheDemosPhoto() {
        #expect(!LaunchOptions(arguments: ["-seedDemo"]).demoPhoto)
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoPhoto"]).demoPhoto)
        #expect(!LaunchOptions(arguments: ["-demoPhoto", "-seedDemo"]).demoPhotoMoves)
        let moving = LaunchOptions(arguments: ["-seedDemo", "-demoPhoto", "gif"])
        #expect(moving.demoPhoto && moving.demoPhotoMoves)
    }
}

// MARK: The demo's pictures

// Apart from the rest only to keep the suite under SwiftLint's body length.
extension PhotoTests {
    /// The marketing scene gives everyone their face, made by whoever seeds it (ADR 2026-10.2acj).
    @Test func theMarketingSceneWearsFaces() throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 1_000_000, scene: .marketing) { Array("\($0)".utf8) }
        let own = try #require(stores.ownProfile.load().avatarHash)
        #expect(stores.blobs.bytes(of: own) == Array("\(DemoPortrait.maya)".utf8))
        let named = Dictionary(stores.peers.allPeers().map { ($0.name, $0) }) { first, _ in first }
        let faces: [(String, DemoPortrait)] = [
            ("Sam Rivera", .sam), ("Dani Cho", .dani), ("Theo Blake", .theo), ("Priya N.", .priya), ("Jonas W.", .jonas),
            ("Lena F.", .lena), ("River Salas", .river),
        ]
        #expect(faces.count == named.count, "everyone wears a face")
        for (name, portrait) in faces {
            let peer = try #require(named[name])
            #expect(peer.avatarHash == BlobHash(of: Array("\(portrait)".utf8)), "\(name)")
            #expect(peer.advertisedAvatarHash == peer.avatarHash, "\(name)'s photo is the one their profile names")
            #expect(peer.avatarHash.flatMap(stores.blobs.bytes(of:)) != nil)
        }
    }

    /// The marketing scene's photos, made by whoever seeds it, each in the clear with its bytes held: the room's post by
    /// the fire, a photo in each DM, and one in the group, so a shot of any of them shows one.
    @Test func theMarketingScenesPhotos() throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 1_000_000, scene: .marketing) { _ in
            nil
        } snap: { picture in
            Array("snap \(picture)".utf8)
        }
        let carrying = stores.messages.messages(in: Conversations.nearby).filter { $0.attachment != nil }
        let post = try #require(carrying.first)
        #expect(carrying.count == 1 && post.body == "Saved you a spot by the fire 🔥")
        let photo = Array("snap \(DemoSnapshot.campfire)".utf8)
        #expect(post.attachment == MessageAttachment(hash: BlobHash(of: photo), mime: "image/jpeg"))
        #expect(stores.blobs.bytes(of: BlobHash(of: photo)) == photo)
        let elsewhere: [String: DemoSnapshot] = ["dm-dani-d": .summit, "dm-sam-e": .lake, "group-e": .trail]
        for (id, picture) in elsewhere {
            let message = try #require(stores.messages.message(id), "\(id)")
            #expect(message.attachment?.hash == BlobHash(of: Array("snap \(picture)".utf8)), "\(id)")
        }
        #expect(stores.ownProfile.load().avatarHash == nil, "the faces have a maker of their own")
    }

    /// Without a maker, or in the edge cases, nobody has a photo.
    @Test(arguments: DemoScene.allCases)
    func aSceneWithoutAMakerHasNoPhotos(scene: DemoScene) throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 1_000_000, scene: scene)
        #expect(stores.blobs.allHashes().isEmpty)
        let made = MeshStores.inMemory()
        DemoSeed.populate(made, me: identity.nodeId, now: 1_000_000, scene: .edgeCases) { Array("\($0)".utf8) }
        #expect(made.blobs.allHashes().isEmpty, "the edge cases stay as they were")
    }
}
