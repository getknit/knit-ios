import KnitWire
import Testing

@testable import KnitAppCore
@testable import KnitMesh

/// Invites, and the sheets they open (ADR 2026-11.adrq, P6): an opened link must start with an invite's prefix, no build
/// takes cleartext, the sheet names the host the dialler uses, a new invite replaces the sheet, and a refusal names its
/// reason and no part of the link.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct RelayInviteSheetTests {
    @Test func anOpenedLinkMustStartWithAnInvitesPrefixAndPastedTextIsSearched() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        let url = "wss://relay.example/spool/v1"
        rig.relays.offer(opened: "see " + RelayRig.invite(url))
        #expect(rig.relays.sheet == nil && rig.relays.notice == nil, "not an invite link: some other link's business")
        rig.relays.offer(opened: "https://getknit.app/c#abc")
        #expect(rig.relays.sheet == nil && rig.relays.notice == nil)
        rig.relays.offer(pasted: "Join my relay: " + RelayRig.appLink(url) + " thanks")
        #expect(rig.relays.sheet?.kind == .add(try #require(AcceptedSpoolURL(url, allowCleartext: false))))
        #expect(RelayIntake.isInviteLink(RelayRig.appLink(url)) && RelayIntake.isInviteLink(RelayRig.invite(url)))
    }

    /// `ws://` is a test socket's alone: no invite takes it, in a debug build or any other.
    @Test func aCleartextInviteIsRefusedInEveryBuild() {
        for debugBuild in [true, false] {
            let rig = RelayRig(target: RecordingTarget(), debugBuild: debugBuild)
            rig.relays.load()
            rig.relays.offer(opened: RelayRig.invite("ws://127.0.0.1:9470/spool/v1"))
            #expect(rig.relays.notice == .refused(.unusableRelay) && rig.relays.sheet == nil)
        }
        #expect(RelayIntake.pasted(RelayRig.invite("ws://localhost:9470/spool/v1")) == .refused(.unusableRelay))
        // An invite the parser takes but the factory refuses: a `%` in the authority.
        #expect(RelayIntake.pasted(RelayRig.invite("wss://relay%2Eexample/spool/v1")) == .refused(.unusableRelay))
    }

    /// The host shown is the factory's reading of the invite's URL, the one the socket dials: a renamed house host folds
    /// into the current one, and only the house address is called Knit's.
    @Test func theSheetNamesTheHostTheDiallerUses() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        let lone = rig.relays.rows[0]
        rig.relays.remove(lone.handle)
        rig.relays.offer(opened: RelayRig.invite("wss://lax.spool.getknit.app/spool/v1"))
        guard case .add(let url) = try #require(rig.relays.sheet).kind else {
            Issue.record("an add sheet")
            return
        }
        let shown = RelayHost(url)
        #expect(shown.host == "public-1.spool.getknit.app" && shown.isKnits && shown.owner == Copy.Relays.knitsRelay)
        #expect(url.socketURLText == SpoolURL.house)
        let token = try #require(AcceptedSpoolURL(SpoolURL.house + "?k=abc", allowCleartext: false))
        #expect(!RelayHost(token).isKnits && RelayHost(token).owner == Copy.Relays.notKnits, "the house host with a token is not Knit's")
    }

    @Test func aSecondInviteReplacesTheSheetAndOnlyTheShownOneIsAdded() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        rig.relays.offer(opened: RelayRig.invite("wss://first.example/spool/v1"))
        let first = try #require(rig.relays.sheet)
        rig.relays.offer(opened: RelayRig.invite("wss://second.example/spool/v1"))
        let shown = try #require(rig.relays.sheet)
        #expect(shown.id != first.id, "a new presentation")
        rig.relays.confirm(shown)
        #expect(rig.relays.rows.map(\.title) == ["public-1.spool.getknit.app", "second.example"])
        #expect(rig.relays.sheet == nil)
        // A stale sheet's tap applies what it showed, and leaves a newer sheet up.
        rig.relays.offer(opened: RelayRig.invite("wss://third.example/spool/v1"))
        let third = try #require(rig.relays.sheet)
        rig.relays.confirm(first)
        #expect(rig.relays.sheet == third)
        #expect(rig.relays.rows.map(\.title).last == "first.example")
    }

    @Test func aRefusedInviteNamesItsReasonAndNoPartOfTheLink() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        let refused = [
            RelayRig.invite("ws://127.0.0.1:9470/spool/v1?k=secret"),
            RelayRig.invite("https://relay.example/spool/v1"),
            RelayInvite.schemePrefix + "!!!!",
        ]
        for link in refused {
            rig.relays.offer(opened: link)
            let message = try #require(rig.relays.notice).message
            for part in ["127.0.0.1", "secret", "relay.example", "!!!!", "knit://"] {
                #expect(!message.contains(part))
            }
        }
        #expect(RelayNotice.refused(.notAnInvite).message == Copy.RelayConsent.notAnInvite)
        #expect(RelayNotice.refused(.unusableRelay).message == Copy.RelayConsent.unusableInvite)
    }

    @Test func aRelayAlreadyListedIsRefusedBeforeAndAtTheTap() throws {
        let rig = RelayRig(target: RecordingTarget())
        rig.relays.load()
        rig.relays.offer(opened: RelayRig.invite(SpoolURL.house))
        #expect(rig.relays.notice == .duplicate && rig.relays.sheet == nil)
        let url = "wss://relay.example/spool/v1"
        rig.relays.offer(opened: RelayRig.invite(url))
        let sheet = try #require(rig.relays.sheet)
        try rig.add(url)
        rig.relays.confirm(sheet)
        #expect(rig.relays.notice == .duplicate && rig.relays.rows.count == 2)
    }

    /// The invite the Simulator's walk pastes (`KnitUITests+Relays.swift`) is the one this build mints.
    @Test func theWalksInviteIsTheOneThisBuildMints() {
        #expect(
            RelayRig.invite("wss://lab.relay.example/spool/v1?k=walk")
                == "knit://r/omF2AWF1eCd3c3M6Ly9sYWIucmVsYXkuZXhhbXBsZS9zcG9vbC92MT9rPXdhbGs")
    }

    /// The share sheet stages contact cards alone: a relay invite is no contact link, so it never reaches Add contact.
    @Test func aRelayInviteIsNoContactLink() {
        #expect(!AddContactModel.isContactLink(RelayRig.appLink("wss://relay.example/spool/v1")))
        #expect(!AddContactModel.isContactLink(RelayRig.invite("wss://relay.example/spool/v1")))
    }
}

/// The sheets over a real mesh whose spool starts paused: the switch's sheet names exactly what the factory opens, and an
/// invite added with the switch off dials nothing.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct RelaySheetMeshTests {
    @Test func theSwitchsSheetListsExactlyTheHostsTheMeshOpens() async throws {
        let sockets = CountingSockets()
        let mesh = try pausedMesh(sockets)
        let rig = RelayRig(target: mesh)
        rig.relays.load()
        try rig.add("wss://lab.relay.example:8443/spool/v1?k=abc")
        try rig.add("wss://parked.relay.example/spool/v1")
        rig.relays.setParked(3, true)
        await mesh.start()
        rig.phases.send(.scene(.active))
        rig.relays.setSwitch(true)
        let sheet = try #require(rig.relays.sheet)
        guard case .turnOn(let joining) = sheet.kind else {
            Issue.record("a switch sheet")
            return
        }
        let hosts = joining.compactMap(\.host)
        #expect(hosts.count == joining.count, "every relay reads")
        #expect(hosts.map(\.host) == ["public-1.spool.getknit.app", "lab.relay.example:8443"])
        #expect(hosts.map(\.isPrivate) == [false, true])
        rig.relays.confirm(sheet)
        await rig.flush()
        await eventually { sockets.opens == hosts.count }
        #expect(Set(sockets.hosts) == Set(hosts.map(\.host)))
        await mesh.stop()
    }

    @Test func anInviteAcceptedWithTheSwitchOffDialsNothing() async throws {
        let sockets = CountingSockets()
        let mesh = try pausedMesh(sockets)
        let rig = RelayRig(target: mesh)
        rig.relays.load()
        await mesh.start()
        rig.phases.send(.scene(.active))
        try rig.add("wss://relay.example/spool/v1")
        await rig.flush()
        #expect(rig.relays.rows.count == 2 && !rig.relays.spoolEnabled)
        #expect(await mesh.spoolStatus.relays.isEmpty, "the mesh carries nothing")
        #expect(sockets.opens == 0)
        await mesh.stop()
    }

    /// A list whose relay 2 was added with its address kept, read again with reads failing: the house relay reads, relay 2
    /// does not.
    private static func oneUnreadable(_ sockets: CountingSockets) throws -> (Mesh, RelayRig) {
        let preferences = MemoryPreferences()
        let secrets = MemoryRelaySecrets()
        let first = RelayRig(target: RecordingTarget(), preferences: preferences, secrets: secrets)
        first.relays.load()
        try first.add("wss://lab.relay.example/spool/v1")
        secrets.failures = [.reads]
        let mesh = try pausedMesh(sockets)
        let rig = RelayRig(target: mesh, preferences: preferences, secrets: secrets)
        rig.relays.load()
        return (mesh, rig)
    }

    /// The switch's sheet names relay 2 by number while it does not read. It reads before the tap: the tap shows a fresh sheet
    /// with its host instead of applying the old one, and nothing is dialled until that one is confirmed.
    @Test func aSwitchSheetThatWentStaleIsShownAgainAndDialsNothing() async throws {
        let sockets = CountingSockets()
        let (mesh, rig) = try Self.oneUnreadable(sockets)
        await mesh.start()
        rig.phases.send(.scene(.active))
        rig.relays.setSwitch(true)
        let stale = try #require(rig.relays.sheet)
        #expect(stale.kind == .turnOn([RelayJoin(handle: 1, host: rig.relays.rows[0].host), RelayJoin(handle: 2, host: nil)]))
        rig.secrets.failures = []
        rig.relays.becameActive()
        rig.relays.confirm(stale)
        await rig.flush()
        let fresh = try #require(rig.relays.sheet, "a fresh sheet in place of the stale one")
        #expect(fresh.id != stale.id && !rig.relays.spoolEnabled && sockets.opens == 0)
        guard case .turnOn(let joining) = fresh.kind else {
            Issue.record("a switch sheet")
            return
        }
        #expect(joining.compactMap(\.host).map(\.host) == ["public-1.spool.getknit.app", "lab.relay.example"])
        rig.relays.confirm(fresh)
        await rig.flush()
        await eventually { sockets.opens == 2 }
        #expect(Set(sockets.hosts) == ["public-1.spool.getknit.app", "lab.relay.example"])
        await mesh.stop()
    }

    /// A relay the switch's sheet named by number, since its address did not read, joins once it reads: no other host is
    /// dialled than the ones that sheet named.
    @Test func aRelayUnreadableAtConsentJoinsOnceItReads() async throws {
        let sockets = CountingSockets()
        let (mesh, rig) = try Self.oneUnreadable(sockets)
        await mesh.start()
        rig.phases.send(.scene(.active))
        rig.relays.setSwitch(true)
        let sheet = try #require(rig.relays.sheet)
        #expect(sheet.kind == .turnOn([RelayJoin(handle: 1, host: rig.relays.rows[0].host), RelayJoin(handle: 2, host: nil)]))
        #expect(
            RelayJoin(handle: 2, host: nil).title == "Relay 2" && RelayJoin(handle: 2, host: nil).marks == Copy.RelayConsent.joinsOnceRead)
        rig.relays.confirm(sheet)
        await rig.flush()
        await eventually { sockets.opens == 1 }
        #expect(sockets.hosts == ["public-1.spool.getknit.app"])
        rig.secrets.failures = []
        rig.relays.becameActive()
        await rig.flush()
        await eventually { sockets.opens == 2 }
        #expect(sockets.hosts == ["public-1.spool.getknit.app", "lab.relay.example"])
        await mesh.stop()
    }
}

/// `-demoRelays`' stand-in: the demo's mesh hears the background, and every relay shows connected while the plane runs.
@Suite struct DemoRelaysTests {
    @Test func onlyDemoRelaysShowsTheDemosRelays() {
        #expect(LaunchOptions(arguments: ["Knit", "-seedDemo", "-demoRelays"]).demoRelays)
        #expect(!LaunchOptions(arguments: ["Knit", "-seedDemo"]).demoRelays)
    }

    @Test func theDemoShowsItsRelaysConnectedWhileThePlaneRuns() async throws {
        let mesh = RecordingTarget()
        let demo = DemoRelays(over: mesh)
        let url = try #require(AcceptedSpoolURL(SpoolURL.house, allowCleartext: false))
        await demo.setInBackground(true)
        #expect(mesh.calls == [.background(true)])
        #expect(demo.addSpoolRelay(SpoolRelayHandle(number: 1), url: url))
        #expect(!demo.addSpoolRelay(SpoolRelayHandle(number: 1), url: url))
        #expect(demo.relayStatus() == RelayMeshStatus(paused: true, relays: [1: .init(state: "idle", failures: 0)]))
        demo.resumeSpool()
        #expect(demo.relayStatus().relays[1]?.state == "open")
        demo.pauseSpool()
        demo.removeSpoolRelay(SpoolRelayHandle(number: 1))
        #expect(demo.relayStatus().relays.isEmpty)
    }
}
