import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The five lying commands through the whole node, `knit-peer run --lying` as its `main` builds it: each sets its lie,
/// shows in `status`'s `lying` and clears; a node run without `--lying` refuses each and says `lying` is `null`; and a
/// profile lie left set is outranked at the next start, `--lying` or not (`door-cap-lying-peers`).
@Suite(.serialized, .timeLimit(.minutes(1))) struct LyingNodeTests {
    private let photo = BlobHash(of: fixtureBytes(30_000, seed: 31))

    @Test func everyLieSetsShowsInStatusAndClears() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        let unset = try await rig.lying()
        #expect((unset["blobhas"] as? [String: Int])?.isEmpty == true && (unset["junk"] as? [String: Any])?.isEmpty == true)
        #expect(unset["advertisedPhoto"] is NSNull && unset["paddedProfile"] is NSNull)
        let counts = try #require(unset["counts"] as? [String: Any])
        #expect(
            counts.keys.sorted() == [
                "advertisedPhotoPushed", "blobAsksSent", "blobhasRewritten", "forgedProfilesWritten", "junkBytesServed",
                "junkHeadersRewritten",
            ])

        let lie = try await rig.send(#"{"cmd":"lie-blobhas","hash":"\#(photo.string)","size":2097152,"tag":"b1"}"#)
        #expect(lie["ok"] as? Bool == true && lie["reply"] as? String == "lie-blobhas" && lie["tag"] as? String == "b1")
        #expect((lie["lying"] as? [String: Any])?["blobhas"] as? [String: Int] == [photo.string: 2_097_152])
        #expect(try await rig.lying()["blobhas"] as? [String: Int] == [photo.string: 2_097_152])
        _ = try await rig.send(#"{"cmd":"lie-blobhas","hash":"\#(photo.string)","clear":true}"#)
        #expect((try await rig.lying()["blobhas"] as? [String: Int])?.isEmpty == true)

        _ = try await rig.send(#"{"cmd":"junk","hash":"\#(photo.string)","bytes":1114112,"declare":30000}"#)
        #expect(try await rig.lying()["junk"] as? [String: [String: Int]] == [photo.string: ["bytes": 1_114_112, "declare": 30_000]])
        _ = try await rig.send(#"{"cmd":"junk","hash":"\#(photo.string)","bytes":1114112}"#)
        let undeclared = try #require((try await rig.lying()["junk"] as? [String: [String: Any]])?[photo.string])
        #expect(undeclared["bytes"] as? Int == 1_114_112 && undeclared["declare"] is NSNull, "no size in the header")
        _ = try await rig.send(#"{"cmd":"junk","hash":"\#(photo.string)","clear":true}"#)
        #expect((try await rig.lying()["junk"] as? [String: Any])?.isEmpty == true && rig.parts?.blobs.junk.isEmpty == true)
        #expect(rig.parts?.radio.junkHeaders.isEmpty == true)

        _ = try await rig.send(#"{"cmd":"advertise-photo","hash":"\#(photo.string)"}"#)
        #expect(try await rig.lying()["advertisedPhoto"] as? String == photo.string)
        #expect(FileManager.default.fileExists(atPath: rig.markerPath))
        _ = try await rig.send(#"{"cmd":"advertise-photo","clear":true}"#)
        #expect(try await rig.lying()["advertisedPhoto"] is NSNull)

        rig.liarClock.advance(by: 1000)
        let pad = try await rig.send(#"{"cmd":"pad-profile","signedBytes":4000}"#)
        #expect(pad["ok"] as? Bool == true && pad["signedBytes"] as? Int == 4000 && pad["written"] as? Int == 0, "no link yet")
        let padded = try #require(try await rig.lying()["paddedProfile"] as? [String: Any])
        #expect(padded["id"] as? String == pad["id"] as? String && padded["signedBytes"] as? Int == 4000)
        rig.liarClock.advance(by: 1000)
        _ = try await rig.send(#"{"cmd":"pad-profile","clear":true}"#)
        #expect(try await rig.lying()["paddedProfile"] is NSNull)
        #expect(rig.parts?.radio.paddedProfile == nil && !FileManager.default.fileExists(atPath: rig.markerPath))

        let ask = try await rig.send(#"{"cmd":"ask-blob","hash":"\#(photo.string)","peer":"\#(rig.receiverKeys.nodeId.string)"}"#)
        #expect(ask["ok"] as? Bool == true && ask["sent"] as? Bool == false && ask["id"] is NSNull, "no link to it")
    }

    /// The link-proof trial's impostor (`link-hello-proof`, T4 and T5): set, shown in `status`'s `lying`, refused for an id
    /// that is not one, and cleared back to honest.
    @Test func theImpostorSetsShowsInStatusAndClears() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        let honest = try #require(try await rig.lying()["impostor"] as? [String: Any])
        #expect(honest["legacy"] as? Bool == false && honest["claim"] is NSNull && honest["dial"] is NSNull)
        let claimed = rig.receiverKeys.nodeId.string
        let set = try await rig.send(#"{"cmd":"impostor","legacy":true,"claim":"\#(claimed)","dial":"\#(claimed)","tag":"i"}"#)
        #expect(set["ok"] as? Bool == true && set["reply"] as? String == "impostor" && set["tag"] as? String == "i")
        let shown = try #require(try await rig.lying()["impostor"] as? [String: Any])
        #expect(shown["legacy"] as? Bool == true && shown["claim"] as? String == claimed && shown["dial"] as? String == claimed)
        for line in [#"{"cmd":"impostor","claim":"x"}"#, #"{"cmd":"impostor","dial":"x"}"#] {
            let reply = try await rig.send(line)
            #expect(reply["ok"] as? Bool == false && reply["error"] as? String == "not a node id: x", "\(line)")
        }
        let kept = try #require(try await rig.lying()["impostor"] as? [String: Any])
        #expect(kept["legacy"] as? Bool == true && kept["claim"] as? String == claimed, "nothing half set")
        _ = try await rig.send(#"{"cmd":"impostor","clear":true}"#)
        let cleared = try #require(try await rig.lying()["impostor"] as? [String: Any])
        #expect(cleared["legacy"] as? Bool == false && cleared["claim"] is NSNull && cleared["dial"] is NSNull)
    }

    @Test func aBadLyingLineIsAnsweredWithWhy() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        let cases: [(String, String)] = [
            (#"{"cmd":"lie-blobhas","size":5}"#, "missing hash"),
            (#"{"cmd":"lie-blobhas","hash":"nope","size":5}"#, "not a valid hash"),
            (#"{"cmd":"lie-blobhas","hash":"\#(photo.string)"}"#, "missing size"),
            (#"{"cmd":"lie-blobhas","hash":"\#(photo.string)","size":-1}"#, "not a valid size"),
            (#"{"cmd":"lie-blobhas","hash":"\#(photo.string)","size":"big"}"#, "not a valid lie-blobhas command"),
            (#"{"cmd":"junk","hash":"\#(photo.string)"}"#, "missing bytes"),
            (#"{"cmd":"junk","hash":"\#(photo.string)","bytes":0}"#, "junk bytes must be in 1...\(FileIntake.maxFileBytes), not 0"),
            (#"{"cmd":"junk","hash":"\#(photo.string)","bytes":5,"declare":-1}"#, "not a valid declare"),
            (#"{"cmd":"pad-profile"}"#, "missing signedBytes"),
            (#"{"cmd":"ask-blob","hash":"\#(photo.string)"}"#, "missing peer"),
            (#"{"cmd":"ask-blob","hash":"\#(photo.string)","peer":"x"}"#, "not a node id: x"),
        ]
        for (line, error) in cases {
            let reply = try await rig.send(line)
            #expect(reply["ok"] as? Bool == false && reply["error"] as? String == error, "\(line)")
        }
        #expect(rig.parts?.blobs.junk.isEmpty == true && rig.parts?.radio.blobHasLies.isEmpty == true, "nothing half set")
    }

    @Test func withoutLyingEveryLieIsRefusedAndStatusSaysNull() async throws {
        let rig = try LyingTrialRig(lying: false)
        defer { rig.remove() }
        await rig.start()
        let lines = [
            #"{"cmd":"lie-blobhas","hash":"\#(photo.string)","size":5,"tag":"t"}"#,
            #"{"cmd":"junk","hash":"\#(photo.string)","bytes":5,"tag":"t"}"#,
            #"{"cmd":"advertise-photo","hash":"\#(photo.string)","tag":"t"}"#,
            #"{"cmd":"pad-profile","signedBytes":4000,"tag":"t"}"#,
            #"{"cmd":"ask-blob","hash":"\#(photo.string)","peer":"\#(rig.receiverKeys.nodeId.string)","tag":"t"}"#,
        ]
        for (line, name) in zip(lines, ["lie-blobhas", "junk", "advertise-photo", "pad-profile", "ask-blob"]) {
            let reply = try await rig.send(line)
            #expect(reply["reply"] as? String == name && reply["ok"] as? Bool == false && reply["tag"] as? String == "t")
            #expect(reply["error"] as? String == "lying switches need knit-peer run --lying")
        }
        let status = try await rig.send(#"{"cmd":"status","tag":"s"}"#)
        #expect(status["ok"] as? Bool == true && status["tag"] as? String == "s" && status["lying"] is NSNull)
        #expect(status["nodeId"] as? String == rig.keys.nodeId.string, "the rest of status as it was")
        #expect(!FileManager.default.fileExists(atPath: rig.markerPath))
    }

    @Test func aLieLeftSetIsOutrankedAtTheNextStartWithoutLying() async throws {
        let first = try LyingTrialRig()
        defer { first.remove() }
        await first.start()
        _ = try await first.send(#"{"cmd":"advertise-photo","hash":"\#(photo.string)"}"#)
        #expect(FileManager.default.fileExists(atPath: first.markerPath))
        let lied = first.stores.ownProfile.load()
        #expect(lied.avatarHash == photo)
        await first.node.stop()

        first.liarClock.advance(by: 1000)
        let second = try LyingTrialRig(lying: false, directory: first.directory)
        second.liarClock.advance(by: 5000)
        await second.start()
        #expect(!FileManager.default.fileExists(atPath: second.markerPath), "the marker goes before ready")
        let honest = second.stores.ownProfile.load()
        #expect(honest.avatarHash == nil && honest.version > lied.version && honest.publishedAt > lied.publishedAt)
        #expect(second.lines.objects.contains { $0["event"] as? String == "ready" })
        await second.node.stop()
    }

    /// A profile switch whose marker cannot be written is answered `ok:false` with why, and nothing is set.
    @Test func aProfileSwitchWhoseMarkerCannotBeWrittenIsAnsweredWithWhy() async throws {
        let rig = try LyingTrialRig()
        defer { rig.remove() }
        await rig.start()
        try FileManager.default.createDirectory(atPath: rig.markerPath + "/in-the-way", withIntermediateDirectories: true)
        let reply = try await rig.send(#"{"cmd":"advertise-photo","hash":"\#(photo.string)","tag":"a"}"#)
        #expect(reply["ok"] as? Bool == false && reply["reply"] as? String == "advertise-photo" && reply["tag"] as? String == "a")
        #expect((reply["error"] as? String)?.hasPrefix("cannot write \(rig.markerPath): ") == true, "\(reply)")
        #expect(try await rig.lying()["advertisedPhoto"] is NSNull)
    }

    /// The last run's marker names a forge far ahead of the clock: the start cannot publish above it, says so in a
    /// warning, keeps the marker, and still reports ready.
    @Test func aStartThatCannotOutrankTheLastRunsForgeWarnsAndStillReportsReady() async throws {
        let log = LineLog()
        let rig = try LyingTrialRig(lying: false, log: log)
        defer { rig.remove() }
        let ahead = rig.liarClock.wallMilliseconds() + 86_400_000
        try FileManager.default.createDirectory(atPath: rig.directory, withIntermediateDirectories: true)
        let marker = #"{"forged":{"version":\#(ahead),"publishedAt":\#(ahead)}}"#
        #expect(FileManager.default.createFile(atPath: rig.markerPath, contents: Data(marker.utf8)))
        await rig.start()
        let warnings = log.lines(at: .warning).filter { $0.hasPrefix("lying: no honest profile published over the last run's lie: ") }
        #expect(warnings.count == 1 && warnings.first?.hasSuffix("the clock is behind the forge") == true, "\(warnings)")
        #expect(FileManager.default.fileExists(atPath: rig.markerPath), "kept for the next start")
        #expect(rig.lines.objects.contains { $0["event"] as? String == "ready" })
        await rig.node.stop()
    }
}
