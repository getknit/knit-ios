import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire
import Testing

@testable import KnitAppCore

/// How far a photo streaming in has got, as its bubble shows it: the share and the line under the ring, and the session's
/// samples while a thread waits on one (knit-next ADR 2026-10.y9qh, `ArrivingFileTest` and
/// `ChatViewModelTest.arrivalsAreReadForTheWindowsAwaitedAttachmentsOnly`).
@MainActor
@Suite struct PhotoArrivalTests {
    private static let photo = Array("Sam's sunset".utf8)
    private static let hash = BlobHash(of: photo)

    /// `bytes` as the caption writes a size.
    private static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }

    /// A ring needs a total the bytes stay within: a header that declared none, or a sender that overran its own, is shown
    /// by its count alone, since the total is the peer's claim and never a bound.
    @Test func theShareNeedsATotalTheBytesStayWithin() {
        #expect(PhotoArrival(bytes: 0, total: 200).fraction == 0)
        #expect(PhotoArrival(bytes: 50, total: 200).fraction == 0.25)
        #expect(PhotoArrival(bytes: 200, total: 200).fraction == 1)
        #expect(PhotoArrival(bytes: 201, total: 200).fraction == nil, "an overrun shows the count")
        #expect(PhotoArrival(bytes: 50, total: nil).fraction == nil)
        #expect(PhotoArrival(bytes: 0, total: 0).fraction == nil)
        let reading = FileIntake.Reading(key: Self.hash, bytes: 84_000, total: 204_800)
        #expect(PhotoArrival(reading) == PhotoArrival(bytes: 84_000, total: 204_800))
    }

    /// The line under the ring says how much of how much, or only how much when there is no share to show
    /// (`chat_attachment_arriving`, `chat_attachment_arriving_bytes`).
    @Test func theCaptionSaysHowMuchOfHowMuch() {
        #expect(PhotoArrival(bytes: 84_000, total: 204_800).caption == "\(Self.size(84_000)) of \(Self.size(204_800))")
        #expect(PhotoArrival(bytes: 52_000, total: nil).caption == "\(Self.size(52_000)) received")
        #expect(PhotoArrival(bytes: 300, total: 200).caption == "\(Self.size(300)) received", "an overrun says only its count")
        #expect(PhotoArrival(bytes: 120, total: 200).whole == PhotoArrival(bytes: 200, total: 200))
        #expect(PhotoArrival(bytes: 300, total: nil).whole == PhotoArrival(bytes: 300, total: 300))
    }

    /// A sample takes what the mesh reports, moves no revision, and asks for the next soon while a file streams and
    /// later while none does (`ArrivalTicker`'s 500 ms and 2 s).
    @Test func aSampleTakesTheReadingsAndPacesTheNext() async {
        let rig = AppRig()
        let before = rig.session.revision
        #expect(await rig.session.sampleArrivals() == AppSession.arrivalIdlePause)
        #expect(rig.session.arrivals.byHash.isEmpty)
        rig.mesh.arriving.withLock { $0 = [Self.hash: FileIntake.Reading(key: Self.hash, bytes: 4096, total: 8192)] }
        #expect(await rig.session.sampleArrivals() == AppSession.arrivalActivePause)
        #expect(rig.session.arrivals[Self.hash] == PhotoArrival(bytes: 4096, total: 8192))
        #expect(rig.session.revision == before, "a moving ring rebuilds no rows")
    }

    /// Behind another app no bubble is on screen, so a sample reads nothing and waits the idle pause.
    @Test func aSampleReadsNothingWhileKnitIsNotInFront() async {
        let rig = AppRig()
        await rig.session.setActive(false)
        rig.mesh.arriving.withLock { $0 = [Self.hash: FileIntake.Reading(key: Self.hash, bytes: 1, total: 2)] }
        #expect(await rig.session.sampleArrivals() == AppSession.arrivalIdlePause)
        #expect(rig.session.arrivals.byHash.isEmpty, "the reading staged was never taken")
    }

    /// The mesh stores a photo in the turn its last chunk lands, before the event that redraws its row reaches the
    /// session. A photo that leaves the readings with its bytes held stays whole until that event, so the bubble never
    /// steps back to waiting in between; one that leaves with its bytes missing was cut off and drops at once.
    @Test func aStoredPhotoStaysWholeUntilItsRowRedrawsAndACutOneDrops() async {
        let rig = AppRig()
        let cut = BlobHash(of: Array("Priya's lake".utf8))
        rig.mesh.arriving.withLock { arriving in
            arriving = [
                Self.hash: FileIntake.Reading(key: Self.hash, bytes: 7000, total: 8192),
                cut: FileIntake.Reading(key: cut, bytes: 100, total: 900),
            ]
        }
        await rig.session.sampleArrivals()
        rig.stores.blobs.insert(Self.photo, hash: Self.hash, mime: "image/jpeg", storedAt: 2)
        rig.mesh.arriving.withLock { $0 = [:] }
        await rig.session.sampleArrivals()
        #expect(rig.session.arrivals[Self.hash] == PhotoArrival(bytes: 8192, total: 8192), "held: whole until the row redraws")
        #expect(rig.session.arrivals[cut] == nil, "cut off: back to waiting")
        await rig.session.handle(.attachmentArrived(Self.hash))
        #expect(rig.session.arrivals[Self.hash] == nil)
        await rig.session.sampleArrivals()
        #expect(rig.session.arrivals.byHash.isEmpty, "and a later sample never brings it back")
    }

    /// The hold lasts one sample: a stored photo whose event never comes, a profile photo or one whose event landed while a
    /// read was on its way, drops at the next, so nothing stays in the map for good.
    @Test func aStoredPhotoIsHeldForOneSampleOnly() async {
        let rig = AppRig()
        rig.mesh.arriving.withLock { $0 = [Self.hash: FileIntake.Reading(key: Self.hash, bytes: 7000, total: 8192)] }
        await rig.session.sampleArrivals()
        rig.stores.blobs.insert(Self.photo, hash: Self.hash, mime: "image/jpeg", storedAt: 2)
        rig.mesh.arriving.withLock { $0 = [:] }
        await rig.session.sampleArrivals()
        #expect(rig.session.arrivals[Self.hash] == PhotoArrival(bytes: 8192, total: 8192))
        await rig.session.sampleArrivals()
        #expect(rig.session.arrivals.byHash.isEmpty, "no event came, and the hold is over")
        await rig.session.sampleArrivals()
        #expect(rig.session.arrivals.byHash.isEmpty)
    }

    /// A thread samples only while one of its photos is on its way (`awaitedHashes`): once the bytes land, it stops.
    @Test func aThreadAwaitsAPhotoUntilItsBytesLand() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        let model = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        #expect(!model.awaitsPhotos, "an empty room waits on nothing")
        rig.stores.messages.save(
            MessageRecord(
                id: "sunset",
                senderId: AppRig.sam.nodeId,
                recipientId: nil,
                conversationId: Conversations.nearby,
                body: "",
                sentAt: 1000,
                arrivedAt: 1000,
                attachment: MessageAttachment(hash: Self.hash, mime: "image/jpeg")
            )
        )
        await rig.session.handle(.received(rig.stores.messages.messages(in: Conversations.nearby)[0], isRequest: false))
        #expect(model.awaitsPhotos)
        rig.stores.blobs.insert(Self.photo, hash: Self.hash, mime: "image/jpeg", storedAt: 2)
        await rig.session.handle(.attachmentArrived(Self.hash))
        #expect(!model.awaitsPhotos)
    }

    /// The photo-arriving scene's posts name photos nobody holds, and its mesh reports them streaming in: one ringed against
    /// its header's size, one counted alone, as the walk and the shots draw them.
    @Test func thePhotoArrivingSceneShowsTwoPhotosOnTheirWay() async throws {
        let identity = try #require(DemoSeed.identity)
        let stores = MeshStores.inMemory()
        DemoSeed.populate(stores, me: identity.nodeId, now: 10_000_000, scene: .photoArriving)
        let named = Set(stores.messages.messages(in: Conversations.nearby).compactMap(\.attachment?.hash))
        let staging = DemoSeed.staging(in: .photoArriving)
        #expect(named.count == 2 && Set(staging.arriving.keys) == named)
        #expect(stores.blobs.held(among: named).isEmpty, "nobody holds their bytes")
        #expect(Set(staging.arriving.values.map(\.total)) == [nil, 204_800])
        let node = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: DemoRadio(state: .on),
            clock: DemoClock(),
            random: SystemRandomNumberGenerator()
        )
        let mesh = DemoMesh(node, staging: staging)
        let session = AppSession(identity: OwnIdentity(bundle: identity.bundle), stores: stores, mesh: mesh)
        #expect(ChatModel(conversationId: Conversations.nearby, session: session).awaitsPhotos)
        #expect(await session.sampleArrivals() == AppSession.arrivalActivePause)
        #expect(session.arrivals.byHash.count == 2)
        #expect(session.arrivals.byHash.values.compactMap(\.fraction).count == 1, "one ring, one count")
    }
}
