import Foundation
import KnitMesh
import KnitPeer
import KnitTestSupport
import KnitWire
import Testing

/// `knit-peer`'s switches for device trials, which change nothing unless asked.
@Suite struct PeerTrialSwitchTests {
    private func run(_ arguments: [String]) throws -> RunOptions {
        guard case .run(let options) = try PeerCommand.parse(arguments, environment: ["HOME": "/home/tester"]) else {
            throw UsageError.missing("run")
        }
        return options
    }

    /// `--stop-reading-after`: the far end's writes stall once the peer stops reading (ADR 2026-10.f5zs).
    @Test func thePeerStopsReadingOnlyWhenATrialAsks() throws {
        #expect(try run([]).stopReadingAfterSeconds == nil, "the peer reads its channels unless a trial asks")
        #expect(try run(["--stop-reading-after", "30"]).stopReadingAfterSeconds == 30)
        #expect(try run(["--stop-reading-after", "0"]).stopReadingAfterSeconds == 0)
        #expect(throws: UsageError.invalid(flag: "--stop-reading-after", value: "90000")) {
            try run(["--stop-reading-after", "90000"])
        }
        #expect(throws: UsageError.self) { try run(["--stop-reading-after", "soon"]) }
        #expect(PeerCommand.usage.contains("--stop-reading-after is for trials"))
    }

    /// `--flood`: undecodable frames to every live link, which the far end's inbound credit is tried against (ADR
    /// 2026-10.f5zs, rule 6).
    @Test func thePeerFloodsOnlyWhenATrialAsks() throws {
        #expect(try run([]).floodBytesPerSecond == nil, "the peer writes no junk unless a trial asks")
        #expect(try run(["--flood", "65536"]).floodBytesPerSecond == 65_536)
        #expect(try run(["--flood", "1"]).floodBytesPerSecond == 1)
        #expect(try run(["--flood", "16777216"]).floodBytesPerSecond == 16_777_216)
        for bad in ["0", "-5", "16777217", "lots"] {
            #expect(throws: UsageError.invalid(flag: "--flood", value: bad)) { try run(["--flood", bad]) }
        }
        #expect(PeerCommand.usage.contains("[--flood BYTES_PER_SECOND]"))
        #expect(PeerCommand.usage.contains("--flood is for trials too"))
    }

    /// `--lying`: the five lying commands take only with it, and every lie starts unset (`door-cap-lying-peers`).
    @Test func thePeerLiesOnlyWhenATrialAsks() throws {
        #expect(try run([]).lying == false, "the lying commands are refused unless a trial asks")
        #expect(try run(["--lying"]).lying)
        #expect(try run(["run", "--lying", "--flood", "1"]).lying, "beside the other trial switches")
        #expect(throws: UsageError.missingValue("--flood")) { try run(["--flood", "--lying"]) }
        #expect(throws: UsageError.repeated("--lying")) { try run(["--lying", "--lying"]) }
        #expect(PeerCommand.usage.contains("[--lying]"))
        #expect(PeerCommand.usage.contains("--lying is for trials too"))
    }

    /// `--only-link`: an allow list in the link manager (knit-ios #58), absent unless asked, refusing an empty list or a bad id.
    @Test func thePeerLinksWithAnyoneUnlessATrialNamesWhom() throws {
        #expect(try run([]).onlyLinks == nil)
        let low = fixtureNodeId(8)
        let high = fixtureNodeId(9)
        #expect(try run(["--only-link", "\(low.string),\(high.string)"]).onlyLinks == [low, high])
        #expect(try run(["run", "--only-link", low.string, "--flood", "1"]).onlyLinks == [low])
        for bad in ["", ",", "\(low.string),", "nobody", "\(low.string),nobody"] {
            #expect(throws: UsageError.invalid(flag: "--only-link", value: bad)) { try run(["--only-link", bad]) }
        }
        #expect(PeerCommand.usage.contains("[--only-link NODE_ID[,NODE_ID...]]"))
        #expect(PeerCommand.usage.contains("--only-link is for trials too"))
    }

    /// `status` names the allow list, sorted, so a harness can check it before a flood; `null` without one.
    @Test func statusNamesTheAllowList() async throws {
        let low = fixtureNodeId(8)
        let high = fixtureNodeId(9)
        var configuration = LinkManager.Configuration()
        configuration.onlyLinks = [high, low]
        let listed = PeerRig(linkConfiguration: configuration)
        await listed.node.start(name: nil)
        #expect(try await listed.send(#"{"cmd":"status"}"#)["onlyLink"] as? [String] == [low.string, high.string].sorted())
        let open = PeerRig()
        await open.node.start(name: nil)
        let status = try await open.send(#"{"cmd":"status"}"#)
        #expect(status["onlyLink"] is NSNull && status["lying"] is NSNull)
    }

    /// The seal's switches (the `link-seal` contract's T5 and T6): honest unless asked, and a PSM only from the dynamic range.
    @Test func theSealSwitchesChangeNothingUnlessAsked() throws {
        let plain = try run([])
        #expect(plain.sealSwitch == "on" && !plain.flipsSealedBit && plain.listenPSM == nil)
        for name in ["on", "off", "downgrade", "plain-reply"] {
            #expect(try run(["--seal", name]).sealSwitch == name)
        }
        #expect(throws: UsageError.self) { try run(["--seal", "maybe"]) }
        #expect(try run(["--flip-sealed-bit"]).flipsSealedBit)
        #expect(try run(["--psm", "200"]).listenPSM == 200)
        #expect(throws: UsageError.invalid(flag: "--psm", value: "127")) { try run(["--psm", "127"]) }
        #expect(throws: UsageError.invalid(flag: "--psm", value: "256")) { try run(["--psm", "256"]) }
        #expect(PeerCommand.usage.contains("[--seal on|off|downgrade|plain-reply] [--flip-sealed-bit] [--psm PSM]"))
    }
}
