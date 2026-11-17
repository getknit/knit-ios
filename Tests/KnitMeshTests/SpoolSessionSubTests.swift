import KnitWire
import Testing

@testable import KnitMesh

/// A `sub`'s answers, and a scope whose `sub` the spool never finishes answering (P3a's blobs review): an unscoped `err`
/// with the `sub`'s `q`, which the daemon sends for `internal` and for a batch past its own `maxScopes`, or 30 s of
/// nothing, forgets each scope still without an anchor so the next round subscribes it again. A `ticket` answers no
/// `sub` and refuses nothing. And an `err` that comes after its request is over moves nothing.
@Suite struct SpoolSessionSubTests {
    private typealias Fixture = SpoolSessionFixture
    private let scope = SpoolSessionFixture.scope
    private let other = SpoolSessionFixture.other

    private func sub(_ scopes: [SpoolID]) -> [ScopeSub] {
        scopes.map { ScopeSub(scope: $0.bytes, bounds: Fixture.bounds) }
    }

    /// A `ticket` answers no `sub` (B-7.2-8), so an unscoped one with the `sub`'s `q` refuses nothing (P3a's security
    /// follow-up): the batch stays waiting, and its 30 s lapse settles it.
    @Test func anUnscopedTicketOnASubRefusesNothing() {
        var session = Fixture.ready(Fixture.hello(limits: nil))
        _ = session.subscribe(sub([scope, other]), now: 0)
        _ = session.drain()
        session.receive(Fixture.err(SpoolErrorCode.ticket, request: 1))
        let events = session.drain().events
        #expect(session.isSubscribed(scope) && session.isSubscribed(other))
        #expect(events.contains { if case .dropped(.unmatched) = $0 { true } else { false } })
        #expect(!events.contains { if case .scopeRefused = $0 { true } else { false } })
    }

    @Test func anUnscopedErrOnASubStrandsNoScopeOfItsBatch() {
        var session = Fixture.ready(Fixture.hello(limits: nil))
        let first = session.subscribe(sub([scope, other]), now: 0)
        #expect(first == [scope, other])
        _ = session.drain()

        session.receive(Fixture.err(SpoolErrorCode.internal, request: 1))
        let events = session.drain().events
        #expect(!session.isSubscribed(scope))
        #expect(!session.isSubscribed(other))
        let refused = events.compactMap { event -> SpoolID? in
            guard case .scopeRefused(let scope, let refusal) = event, refusal.code.is(SpoolErrorCode.internal) else {
                return nil
            }
            return scope
        }
        #expect(refused == [scope, other])

        let again = session.subscribe(sub([scope, other]), now: 0)
        #expect(again == [scope, other], "the next round subscribes both again")
        #expect(session.drain().records.count == 1)
    }

    @Test func aSubWhoseAnswersNeverComeIsForgottenAfter30Seconds() {
        var session = Fixture.ready()
        _ = session.subscribe(sub([scope, other]), now: 1000)
        session.receive(Fixture.digest())
        _ = session.drain()
        #expect(session.nextDeadline == 31_000)

        session.tick(now: 30_999)
        #expect(session.drain().isEmpty)
        session.tick(now: 31_000)
        #expect(session.drain().events == [.subscriptionLapsed(other)])
        #expect(session.isSubscribed(scope), "its digest came")
        #expect(!session.isSubscribed(other))
        #expect(session.nextDeadline == nil)
        #expect(session.fault == nil, "a sub strikes nothing")
    }

    @Test func aScopeDeclaredAgainKeepsItsEarlierAnswer() {
        var session = Fixture.ready()
        _ = session.subscribe(sub([scope]), now: 0)
        session.receive(Fixture.digest())
        _ = session.subscribe(sub([scope, other]), now: 0)
        _ = session.drain()
        session.receive(Fixture.err(SpoolErrorCode.malformed, request: 2))

        #expect(session.drain().events.count == 1)
        #expect(session.isSubscribed(scope), "anchored, so only declared again")
        #expect(!session.isSubscribed(other))
    }

    @Test func aScopedErrWithASubsQRefusesOnlyAScopeThatSubNamed() {
        var session = Fixture.ready()
        _ = session.subscribe(sub([scope]), now: 0)
        _ = session.subscribe(sub([other]), now: 0)
        _ = session.drain()
        session.receive(Fixture.err(SpoolErrorCode.quota, request: 1, scope: other.bytes))
        #expect(session.drain().events == [.dropped(.unmatched)])
        #expect(session.isSubscribed(other))

        session.receive(Fixture.err(SpoolErrorCode.quota, request: 2, scope: other.bytes))
        #expect(!session.isSubscribed(other))
        #expect(session.subsInFlight.keys.sorted() == [1])
    }

    @Test func aLateErrAfterItsRequestTimedOutMovesNothing() throws {
        var session = Fixture.subscribed()
        session.receive(Fixture.digest())
        let pushed = session.push(scope, blobId: other, data: [1], pow: nil, now: 0)
        let push = try #require(pushed)
        session.tick(now: SpoolSession.requestMilliseconds)
        _ = session.drain()

        session.receive(Fixture.err(SpoolErrorCode.rate, request: push, scope: scope.bytes, retryMs: 1000))
        #expect(session.drain().events == [.dropped(.unmatched)])
        #expect(session.isSubscribed(scope))
        #expect(session.anchor(scope) != nil)
    }

    @Test func anErrWhoseScopeIsNotItsRequestsAnswersNothing() throws {
        var session = Fixture.subscribed([scope, other])
        let pushed = session.push(scope, blobId: Fixture.id(5), data: [1], pow: nil, now: 0)
        _ = try #require(pushed)
        _ = session.drain()
        session.receive(Fixture.err(SpoolErrorCode.quota, request: 2, scope: other.bytes))

        #expect(session.drain().events == [.dropped(.unmatched)])
        #expect(session.isSubscribed(other))
        #expect(session.nextDeadline == SpoolSession.requestMilliseconds, "the push still waits")
    }

    @Test func aClosedSocketTakesTheWaitingSubsWithIt() {
        var session = Fixture.ready()
        _ = session.subscribe(sub([scope]), now: 0)
        #expect(session.bookSize == 2, "the subscription and the scope its sub waits on")
        session.socketClosed()
        #expect(session.bookSize == 0)
    }
}
