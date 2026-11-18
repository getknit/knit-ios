import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The floors a relay asks for (ADR 2026-11.adrq, P6), on the plane itself: a refusal that lands after the open deadline
/// ended its dial, a stale one, the last refusal's word, and the bound on what the plane keeps by handle.
extension SpoolConnectionTests {
    private static func refused(_ header: String?) -> SpoolDialFailure {
        SpoolDialFailure(.http, status: 503, retryAfter: header.map { SpoolRetryAfter(header: Array($0.utf8)) })
    }

    private static func dialTokens(_ plane: inout SpoolPlane) -> [SpoolRelayHandle: SpoolConnectionToken] {
        var tokens: [SpoolRelayHandle: SpoolConnectionToken] = [:]
        for case .dial(let relay, let token, _) in plane.takeActions() {
            tokens[relay] = token
        }
        return tokens
    }

    /// A dial past its open deadline, then its refusal with `Retry-After: 30`: no second failure, but the redial moves to
    /// the floor. A refusal under a token no longer the last, or for a relay not carried, changes nothing.
    @Test func aRefusalAfterTheOpenDeadlineRaisesTheRedialToItsFloor() throws {
        let lab = try SpoolEngineLabTests.greeted()
        let engine = lab[1].engine
        let token = try lab.dialed(1)
        lab.advance(SpoolLink.openMilliseconds)
        #expect(lab.link(1)?.counts.dialTimeouts == 1 && lab.link(1)?.failures == 1)
        #expect(lab.waited(1) < 30_000, "the curve alone")

        let now = lab[1].clock.monotonicMilliseconds()
        lab.planes[1].dialFailed(lab.relay, token: token, Self.refused("30"), engine: engine)
        #expect(lab.link(1)?.nextDialAt == now + 30_000, "raised to the floor")
        #expect(lab.link(1)?.failures == 1 && lab.link(1)?.counts.dialFailures == 0, "and no second failure")
        #expect(lab.planes[1].askedFloors[lab.relay] == now + 30_000)

        lab.planes[1].dialFailed(lab.relay, token: SpoolConnectionToken(value: 999), Self.refused("60"), engine: engine)
        #expect(lab.link(1)?.nextDialAt == now + 30_000 && lab.planes[1].askedFloors[lab.relay] == now + 30_000, "a stale token")
        let unknown = SpoolRelayHandle(number: 77)
        lab.planes[1].dialFailed(unknown, token: token, Self.refused("60"), engine: engine)
        #expect(lab.planes[1].askedFloors[unknown] == nil, "a relay not carried keeps no floor")
    }

    /// The floor is the last refusal's word: one that names no `Retry-After` clears an older floor rather than keeping it.
    /// Every path dials a relay only once its floor has passed, so the second dial is set due by hand.
    @Test func aLaterRefusalWithNoRetryAfterClearsTheFloor() throws {
        let fixture = EngineFixture(SpoolEngineLabTests.alice)
        var plane = SpoolPlane(me: fixture.me.nodeId)
        let relay = SpoolRelayHandle(number: 1)
        let added = plane.add(relay, url: try #require(SpoolLab.url), engine: fixture.engine)
        #expect(added)
        plane.resume(engine: fixture.engine)
        let firstDial = Self.dialTokens(&plane)
        let first = try #require(firstDial[relay])
        let now = fixture.clock.monotonicMilliseconds()
        plane.dialFailed(relay, token: first, Self.refused("30"), engine: fixture.engine)
        #expect(plane.askedFloors[relay] == now + 30_000)

        plane.relays[relay]?.link.nextDialAt = now
        plane.dialDue(engine: fixture.engine)
        let secondDial = Self.dialTokens(&plane)
        let second = try #require(secondDial[relay])
        plane.dialFailed(relay, token: second, Self.refused(nil), engine: fixture.engine)
        #expect(plane.askedFloors[relay] == nil, "cleared")
        plane.pause(engine: fixture.engine)
        plane.resume(engine: fixture.engine)
        let third = Self.dialTokens(&plane)[relay]
        #expect(third != nil, "a resume dials at once")
    }

    /// Two relays refused with `Retry-After: 60` and removed, then eight more refused: the floors stay at eight, the removed
    /// relays' going first, and once a minute has passed none is left.
    @Test func theFloorsKeptByHandleStayBounded() throws {
        let fixture = EngineFixture(SpoolEngineLabTests.alice)
        var plane = SpoolPlane(me: fixture.me.nodeId)
        let url = try #require(SpoolLab.url)
        let gone = [SpoolRelayHandle(number: 1), SpoolRelayHandle(number: 2)]
        for relay in gone {
            let added = plane.add(relay, url: url, engine: fixture.engine)
            #expect(added)
        }
        plane.resume(engine: fixture.engine)
        for (relay, token) in Self.dialTokens(&plane) {
            plane.dialFailed(relay, token: token, Self.refused("60"), engine: fixture.engine)
        }
        for relay in gone {
            plane.remove(relay, engine: fixture.engine)
        }
        #expect(plane.askedFloors.count == 2, "a removed relay keeps its floor")

        let carried = (3...(2 + SpoolPlane.maxRelays)).map { SpoolRelayHandle(number: $0) }
        for relay in carried {
            let added = plane.add(relay, url: url, engine: fixture.engine)
            #expect(added)
        }
        for (relay, token) in Self.dialTokens(&plane) {
            plane.dialFailed(relay, token: token, Self.refused("60"), engine: fixture.engine)
        }
        #expect(plane.askedFloors.count == SpoolPlane.maxRelays)
        #expect(Set(plane.askedFloors.keys) == Set(carried), "the removed relays' floors went first")

        fixture.clock.advance(SpoolBackoff.maxRetryAfterMilliseconds)
        plane.remove(carried[0], engine: fixture.engine)
        let readded = plane.add(gone[0], url: url, engine: fixture.engine)
        #expect(readded)
        #expect(plane.askedFloors.isEmpty, "every floor has passed")
    }
}
