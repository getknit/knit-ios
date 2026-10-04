import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A classifier that scores photos from a table by their bytes, counting each time it is asked. Bytes it does not know
/// score `nil`, as a photo the model cannot read does.
actor FakeClassifier: PhotoClassifier {
    static let explicit: [Float] = [0, 0.3, 0, 0.3, 0.3]
    static let clean: [Float] = [0, 0.3, 0.1, 0.3, 0.2999]

    private let table: [[UInt8]: [Float]]
    private(set) var asked = 0

    init(_ table: [[UInt8]: [Float]]) {
        self.table = table
    }

    func scores(of bytes: [UInt8]) -> [Float]? {
        asked += 1
        return table[bytes]
    }
}

/// The content filter for photos: Android's policy over the classifier's scores, the check before a photo is sent,
/// and what someone else's photo or face hides behind while the filter is on (ADR 2026-10.rpmq).
@MainActor
@Suite struct PhotoScreeningTests {
    private static let picked = Data("a picked photo".utf8)
    /// What ``FakeCodec`` prepares from ``picked``.
    private static let prepared = Array("ready ".utf8) + Array(picked)
    private static let sunset = Array("Sam's sunset".utf8)

    private func filter(_ rig: AppRig, _ table: [[UInt8]: [Float]], filters: Bool = true) -> (PhotoScreening, FakeClassifier) {
        let classifier = FakeClassifier(table)
        let preferences = MemoryPreferences(filtersContent: filters)
        return (PhotoScreening(classifier: classifier, preferences: preferences, session: rig.session), classifier)
    }

    /// Someone else's photo in the room, its bytes held.
    private func roomPhoto(_ bytes: [UInt8], in rig: AppRig) -> ChatAttachment {
        let hash = BlobHash(of: bytes)
        rig.stores.blobs.insert(bytes, hash: hash, mime: "image/jpeg", storedAt: 1)
        return ChatAttachment(hash: hash, kind: .photo, key: nil, isHeld: true, label: Copy.Attachments.photo)
    }

    // MARK: The policy

    /// hentai, porn and sexy sum to the threshold (`NsfwImageModerator.kt`), and scores from some other model count
    /// as clean.
    @Test func theUnsafeClassesSumToTheThreshold() {
        #expect(ExplicitPhoto.classes == ["drawings", "hentai", "neutral", "porn", "sexy"])
        #expect(ExplicitPhoto.threshold == 0.9)
        #expect(ExplicitPhoto.isExplicit(FakeClassifier.explicit))
        #expect(!ExplicitPhoto.isExplicit(FakeClassifier.clean), "a hair under 0.9")
        #expect(!ExplicitPhoto.isExplicit([1, 0, 0, 0, 0]) && !ExplicitPhoto.isExplicit([0, 0, 1, 0, 0]))
        #expect(abs(ExplicitPhoto.unsafeScore([0.1, 0.2, 0.3, 0.15, 0.25]) - 0.6) < 1e-6)
        #expect(ExplicitPhoto.unsafeScore([1, 1, 1]) == 0 && !ExplicitPhoto.isExplicit([]))
    }

    // MARK: Sending

    /// A photo about to be sent is checked whether or not the filter is on, and nothing about it is kept.
    @Test func aPhotoAboutToBeSentIsCheckedWhateverTheFilterSays() async {
        let rig = AppRig()
        let (screening, classifier) = filter(rig, [Self.prepared: FakeClassifier.explicit], filters: false)
        #expect(await screening.isExplicit(outgoing: Self.prepared))
        #expect(await screening.isExplicit(outgoing: Self.prepared))
        #expect(await classifier.asked == 2, "each pick is asked afresh")
        #expect(await !screening.isExplicit(outgoing: Self.sunset), "a photo the model cannot read goes")
        let blind = PhotoScreening(classifier: nil, preferences: MemoryPreferences(), session: rig.session)
        #expect(await !blind.isExplicit(outgoing: Self.prepared), "with no model, nothing is held back")
    }

    /// The room refuses an explicit photo outright: it floods to everyone in range (`ChatViewModel.stage`).
    @Test func theRoomRefusesAnExplicitPhoto() async {
        let rig = AppRig()
        let (screening, _) = filter(rig, [Self.prepared: FakeClassifier.explicit])
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec(), screening: screening)
        await model.choosePhoto(Self.picked)
        #expect(model.photoRefused && model.staged == nil)
        #expect(model.explicitPhoto == nil && !model.asksAboutExplicitPhoto && !model.photoFailed)
    }

    /// A DM or a group holds an explicit photo out of the composer until the sender says to send it anyway, or drops it.
    @Test(arguments: [false, true])
    func aPrivateThreadAsksBeforeAnExplicitPhotoGoesIn(group: Bool) async throws {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let thread = group ? GroupId.derive([rig.me.string, AppRig.sam.nodeId.string]) : AppRig.sam.nodeId.string
        let (screening, _) = filter(rig, [Self.prepared: FakeClassifier.explicit])
        let model = ChatModel(conversationId: thread, session: rig.session, codec: FakeCodec(), screening: screening)

        await model.choosePhoto(Self.picked)
        #expect(model.asksAboutExplicitPhoto && model.staged == nil && !model.photoRefused)
        #expect(model.explicitPhoto?.bytes == Self.prepared)
        await model.keepExplicitPhoto()
        let staged = try #require(model.staged)
        #expect(staged.photo.bytes == Self.prepared && staged.hash == BlobHash(of: Self.prepared))
        #expect(model.explicitPhoto == nil)

        model.removePhoto()
        model.asksAboutExplicitPhoto = false
        await model.choosePhoto(Self.picked)
        model.dropExplicitPhoto()
        #expect(model.explicitPhoto == nil && model.staged == nil, "dropped, it never reached the composer")
        await model.keepExplicitPhoto()
        #expect(model.staged == nil, "there is nothing left to keep")
    }

    /// A clean photo, or one the model cannot score, goes straight into the composer, in the room as anywhere.
    @Test func aCleanPhotoGoesStraightIn() async {
        let rig = AppRig()
        let (clean, _) = filter(rig, [Self.prepared: FakeClassifier.clean])
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec(), screening: clean)
        await model.choosePhoto(Self.picked)
        #expect(model.staged?.photo.bytes == Self.prepared && !model.photoRefused)
        let (unscored, _) = filter(rig, [:])
        let other = ChatModel(conversationId: Conversations.nearby, session: rig.session, codec: FakeCodec(), screening: unscored)
        await other.choosePhoto(Self.picked)
        #expect(other.staged != nil, "a photo the model cannot read goes, as on Android")
    }

    // MARK: Showing

    /// Someone else's explicit photo hides while the filter is on. Ours never does, nor anything that is no photo or whose
    /// bytes are not here.
    @Test func someoneElsesExplicitPhotoHidesWhileTheFilterIsOn() async {
        let rig = AppRig()
        let (screening, _) = filter(rig, [Self.sunset: FakeClassifier.explicit])
        let photo = roomPhoto(Self.sunset, in: rig)
        #expect(!screening.isHiding(photo, isMine: false), "nothing hides before it is screened")
        #expect(await screening.hides(photo, isMine: false))
        #expect(screening.isHiding(photo, isMine: false) && !screening.isHiding(photo, isMine: true))
        #expect(await !screening.hides(photo, isMine: true), "our own photos are never hidden from us")
        var owed = photo
        owed.isHeld = false
        #expect(await !screening.hides(owed, isMine: false))
        var voice = photo
        voice.kind = .voice
        #expect(await !screening.hides(voice, isMine: false), "only photos are screened")
        screening.filtersContent = false
        #expect(await !screening.hides(photo, isMine: false), "the filter off shows everything")
        #expect(!screening.isHiding(photo, isMine: false))
    }

    /// A sealed photo is screened as it opens, with its message's key: the picture, not the ciphertext.
    @Test func aSealedPhotoIsScreenedOpened() async throws {
        let rig = AppRig()
        let sealed = try #require(AttachmentCrypto.seal(Self.sunset))
        let hash = BlobHash(of: sealed.blob)
        rig.stores.blobs.insert(sealed.blob, hash: hash, mime: "image/jpeg", storedAt: 1)
        let (screening, _) = filter(rig, [Self.sunset: FakeClassifier.explicit])
        let photo = ChatAttachment(hash: hash, kind: .photo, key: Base64.encode(sealed.key), isHeld: true, label: Copy.Attachments.photo)
        #expect(await screening.hides(photo, isMine: false))
        var wrong = photo
        wrong.key = Base64.encode([UInt8](repeating: 7, count: 32))
        #expect(await !screening.hides(wrong, isMine: false), "a key that opens nothing shows nothing to screen")
    }

    /// A verdict is kept, so a photo is screened once however often it is drawn, even by two at once. A photo that
    /// could not be scored is asked about again, so a model that comes back screens it.
    @Test func aPhotoIsScreenedOnceAndOneNotScoredIsAskedAgain() async {
        let rig = AppRig()
        let (screening, classifier) = filter(rig, [Self.sunset: FakeClassifier.clean])
        let photo = roomPhoto(Self.sunset, in: rig)
        let first = Task { await screening.hides(photo, isMine: false) }
        let second = Task { await screening.hides(photo, isMine: false) }
        let answers = (await first.value, await second.value)
        #expect(!answers.0 && !answers.1)
        #expect(await !screening.hides(photo, isMine: false))
        #expect(await classifier.asked == 1)

        let unreadable = roomPhoto(Array("not a photo".utf8), in: rig)
        #expect(await !screening.hides(unreadable, isMine: false))
        #expect(await !screening.hides(unreadable, isMine: false))
        #expect(await classifier.asked == 3)
        var missing = photo
        missing.hash = BlobHash(of: Array("gone".utf8))
        #expect(await !screening.hides(missing, isMine: false), "missing bytes are let through")
        #expect(await classifier.asked == 3, "and never reach the model")
    }

    /// With no model nothing hides, and nothing is read.
    @Test func noModelHidesNothing() async {
        let rig = AppRig()
        let screening = PhotoScreening(classifier: nil, preferences: MemoryPreferences(), session: rig.session)
        #expect(await !screening.hides(roomPhoto(Self.sunset, in: rig), isMine: false))
        #expect(await !screening.hidesFace(BlobHash(of: Self.sunset)))
    }

    /// Someone else's explicit face shows their initial while the filter is on, and comes back once it is off. Our own
    /// face is never hidden from us.
    @Test func someoneElsesExplicitFaceShowsTheirInitial() async {
        let rig = AppRig()
        let mine = Array("my own photo".utf8)
        var own = rig.stores.ownProfile.load()
        own.avatarHash = BlobHash(of: mine)
        rig.stores.ownProfile.save(own)
        rig.stores.blobs.insert(mine, hash: BlobHash(of: mine), mime: "image/jpeg", storedAt: 1)
        let face = roomPhoto(Self.sunset, in: rig).hash
        let (screening, _) = filter(rig, [Self.sunset: FakeClassifier.explicit, mine: FakeClassifier.explicit])
        #expect(!screening.isHidingFace(face), "nothing hides before it is screened")
        #expect(await screening.hidesFace(face))
        #expect(screening.isHidingFace(face))
        #expect(await !screening.hidesFace(BlobHash(of: mine)))
        #expect(!screening.isHidingFace(BlobHash(of: mine)))
        screening.filtersContent = false
        #expect(await !screening.hidesFace(face))
        #expect(!screening.isHidingFace(face))
    }

    // MARK: The toggle

    /// Content filtering is on until it is turned off, and stays as it was left.
    @Test func theFilterIsOnUntilTurnedOffAndRemembered() {
        let rig = AppRig()
        let preferences = MemoryPreferences()
        #expect(preferences.filtersContent)
        let screening = PhotoScreening(classifier: nil, preferences: preferences, session: rig.session)
        #expect(screening.filtersContent)
        screening.filtersContent = false
        #expect(!preferences.filtersContent)
        #expect(!PhotoScreening(classifier: nil, preferences: preferences, session: rig.session).filtersContent)
    }

    // MARK: The demo

    /// `-demoSensitive` makes every photo explicit to the demo's classifier, so the UI tests can walk the filter.
    @Test func theDemoFindsEveryPhotoExplicitOnlyWhenAsked() {
        #expect(LaunchOptions(arguments: ["-seedDemo", "-demoSensitive"]).demoSensitive)
        #expect(!LaunchOptions(arguments: ["-seedDemo"]).demoSensitive)
        let flagging = DemoPhotoClassifier(flagsEverything: true).scores(of: Self.sunset)
        let clearing = DemoPhotoClassifier(flagsEverything: false).scores(of: Self.sunset)
        #expect(flagging.map(ExplicitPhoto.isExplicit) == true)
        #expect(clearing.map(ExplicitPhoto.isExplicit) == false)
    }
}
