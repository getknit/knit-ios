import KnitSync
import KnitWire
import Testing

@testable import KnitAppCore

/// A link becoming a card on the sender's phone (`LinkPreviewServiceTest.kt` in knit-next, ADR 2026-11.hcvg): the gates in
/// their order, the picture that may fail alone, the room's screens, the memo and the budget.
@Suite struct LinkPreviewServiceTests {
    private static let url = "https://example.com/story"
    private static let page = TableFetcher.html(
        "<meta property='og:title' content='Title'><meta property='og:description' content='Desc'>"
            + "<meta property='og:image' content='https://cdn.example.com/a.png'>")

    /// A service over fakes, and what they saw.
    private struct Rig {
        let gate = SwitchedGate()
        let fetcher: TableFetcher
        let shrunk = Lock<ShrunkPicture?>(ShrunkPicture(bytes: [UInt8](repeating: 2, count: 8), mime: "image/webp"))
        let now = Lock<Int64>(1000)
        let words = Lock<[String]>([])
        let pictures = Lock<[[UInt8]]>([])
        let wordsFlag = Lock(false)
        let pictureFlag = Lock(false)
        let service: LinkPreviewService

        init(fetcher: TableFetcher = TableFetcher(), givesUpAtOnce: Bool = false) {
            fetcher.setPage(LinkPreviewServiceTests.url, LinkPreviewServiceTests.page)
            self.fetcher = fetcher
            let (picture, clock) = (shrunk, now)
            service = LinkPreviewService(
                gate: gate,
                fetcher: fetcher,
                shrink: { _ in picture.withLock { $0 } },
                now: { clock.withLock { $0 } },
                sleep: { duration in
                    if !givesUpAtOnce {
                        try await Task.sleep(for: duration)
                    }
                }
            )
        }

        var room: LinkPreviewService.RoomScreens {
            let (read, seen, flagsWords, flagsPictures) = (words, pictures, wordsFlag, pictureFlag)
            return LinkPreviewService.RoomScreens(
                wordsFlagged: { text in
                    read.withLock { $0.append(text) }
                    return flagsWords.withLock { $0 }
                },
                pictureFlagged: { bytes in
                    seen.withLock { $0.append(bytes) }
                    return flagsPictures.withLock { $0 }
                })
        }

        func card(_ url: String = LinkPreviewServiceTests.url, inRoom: Bool = false) async -> LinkPreviewBlob? {
            guard case .card(let blob) = await service.fetchCard(url, room: inRoom ? room : nil) else {
                return nil
            }
            return blob
        }
    }

    private static func pictureAnswer() -> TableFetcher {
        TableFetcher(images: ["https://cdn.example.com/a.png": .image([UInt8](repeating: 1, count: 8), contentType: "image/png")])
    }

    @Test func aPageWithAPictureBecomesACard() async throws {
        let rig = Rig(fetcher: Self.pictureAnswer())
        let card = try #require(await rig.card(inRoom: true))
        #expect(card.url == Self.url && card.title == "Title" && card.description == "Desc")
        #expect(card.image == [UInt8](repeating: 2, count: 8) && card.imageMime == "image/webp")
        #expect(rig.fetcher.requests == [Self.url, "https://cdn.example.com/a.png"])
        #expect(rig.words.withLock { $0 } == ["Title\nDesc"] && rig.pictures.withLock { $0.count } == 1)
    }

    @Test func withoutARouteNothingIsFetchedAndTheAnswerIsNotRemembered() async {
        let rig = Rig()
        rig.gate.set(online: false)
        #expect(await rig.service.fetchCard(Self.url, room: nil) == .offline)
        #expect(rig.fetcher.requests.isEmpty)
        rig.gate.set(online: true)
        #expect(await rig.card() != nil)
        #expect(rig.fetcher.requests.count == 2, "the page, and its picture")
    }

    @Test func lowDataModeDefersTheFetchWithoutTouchingTheNetwork() async {
        let rig = Rig()
        rig.gate.set(online: true, restricted: true)
        #expect(await rig.service.fetchCard(Self.url, room: nil) == .restricted)
        #expect(rig.fetcher.requests.isEmpty)
    }

    @Test func aLinkThePolicyRefusesNeverReachesTheGateOrTheNetwork() async {
        let rig = Rig()
        rig.gate.set(online: false)
        #expect(await rig.service.fetchCard("https://10.0.0.1/admin", room: nil) == .noCard)
        #expect(await rig.service.fetchCard("https://example.com:8443/", room: nil) == .noCard)
        #expect(rig.fetcher.requests.isEmpty)
    }

    @Test func aPageThatIsNotHtmlOrHasNoTitleYieldsNoCard() async {
        let rig = Rig()
        rig.fetcher.setPage(Self.url, .notHTML)
        #expect(await rig.service.fetchCard(Self.url, room: nil) == .noCard)
        rig.fetcher.setPage(Self.url, TableFetcher.html("<meta property='og:description' content='desc but no title'>"))
        #expect(await rig.service.fetchCard(Self.url, room: nil) == .noCard)
        rig.fetcher.setPage(Self.url, .failed("http 404"))
        #expect(await rig.service.fetchCard(Self.url, room: nil) == .noCard)
        #expect(rig.fetcher.requests == [Self.url, Self.url, Self.url], "no picture was asked for")
    }

    @Test func aRouteThatVanishesMidFetchReadsAsOfflineNotAsNoCard() async {
        let rig = Rig()
        rig.fetcher.setPage(Self.url, .offline)
        #expect(await rig.service.fetchCard(Self.url, room: nil) == .offline)
    }

    @Test func anyPictureFailureLeavesATextOnlyCard() async throws {
        let rig = Rig(fetcher: TableFetcher(images: ["https://cdn.example.com/a.png": .tooLarge]))
        #expect(try #require(await rig.card()).image == nil)
        let second = Self.url + "?2"
        rig.fetcher.setPage(second, Self.page)
        rig.shrunk.withLock { $0 = nil }
        #expect(try #require(await rig.card(second)).image == nil)
        let third = Self.url + "?3"
        rig.fetcher.setPage(
            third, TableFetcher.html("<meta property='og:title' content='T'><meta property='og:image' content='https://10.0.0.7/x.jpg'>"))
        #expect(try #require(await rig.card(third)).image == nil)
        #expect(rig.fetcher.requests.filter { $0.hasPrefix("https://cdn.") }.count == 2, "a picture the rules refuse is never asked for")
    }

    @Test func aFlaggedPictureIsDroppedFromARoomCardButTheCardIsKept() async throws {
        let rig = Rig(fetcher: Self.pictureAnswer())
        rig.pictureFlag.withLock { $0 = true }
        let card = try #require(await rig.card(inRoom: true))
        #expect(card.title == "Title" && card.image == nil && card.imageMime == nil)
    }

    @Test func flaggedWordsDropTheWholeRoomCard() async {
        let rig = Rig(fetcher: Self.pictureAnswer())
        rig.wordsFlag.withLock { $0 = true }
        #expect(await rig.service.fetchCard(Self.url, room: rig.room) == .noCard)
        #expect(rig.words.withLock { $0 } == ["Title\nDesc"] && rig.pictures.withLock { $0.isEmpty }, "the words first")
    }

    /// Only the room screens what is sent (knit-next ADR 2026-10.9rh6); the memo keeps the card unscreened, so the room's
    /// refusal does not carry to a DM.
    @Test func aPrivateChatsCardIsNeverScreenedAndTheMemoKeepsItsPicture() async throws {
        let rig = Rig(fetcher: Self.pictureAnswer())
        rig.wordsFlag.withLock { $0 = true }
        rig.pictureFlag.withLock { $0 = true }
        #expect(await rig.service.fetchCard(Self.url, room: rig.room) == .noCard)
        let card = try #require(await rig.card())
        #expect(card.title == "Title" && card.image != nil)
        #expect(rig.fetcher.requests.filter { $0 == Self.url }.count == 1)
        #expect(rig.words.withLock { $0.count } == 1 && rig.pictures.withLock { $0.isEmpty })
    }

    @Test func theMemoReusesACardUntilItExpiresAndKeepsItsBound() async {
        let rig = Rig()
        _ = await rig.card()
        _ = await rig.card()
        _ = await rig.card("http://example.com/story#frag")
        #expect(rig.fetcher.requests.filter { $0 == Self.url }.count == 1)
        rig.now.withLock { $0 += LinkPreviewService.memoMilliseconds + 1 }
        _ = await rig.card()
        #expect(rig.fetcher.requests.filter { $0 == Self.url }.count == 2)
        for index in 0..<LinkPreviewService.memoKept {
            rig.fetcher.setPage(Self.url + "?\(index)", Self.page)
            _ = await rig.card(Self.url + "?\(index)")
        }
        _ = await rig.card()
        #expect(rig.fetcher.requests.filter { $0 == Self.url }.count == 3, "the oldest card went past the bound")
    }

    @Test func aSlowSiteIsGivenUpOnWithinTheBudget() async {
        let rig = Rig(fetcher: TableFetcher(hangs: true), givesUpAtOnce: true)
        #expect(await rig.service.fetchCard(Self.url, room: nil) == .noCard)
    }

    @Test func theCardIsCleanedBeforeItIsHandedBack() async throws {
        let rig = Rig(fetcher: Self.pictureAnswer())
        rig.fetcher.setPage(
            Self.url,
            TableFetcher.html(
                "<meta property='og:title' content='  Spaced   out  '><meta property='og:image' content='https://cdn.example.com/a.png'>"))
        let heavy = [UInt8](repeating: 0, count: LinkPreviewBlob.imageMaxBytes + 1)
        rig.shrunk.withLock { $0 = ShrunkPicture(bytes: heavy, mime: "image/webp") }
        let card = try #require(await rig.card())
        #expect(card.title == "Spaced out")
        #expect(card.image == nil, "a picture past the cap is dropped by the card's own rule")
    }
}
