import Foundation
import KnitControl
import KnitMesh
import KnitPeer
import Testing

/// knit-peer's `advert` over its control lines (ADR 2026-11.prsp): the switch kept in memory for the run, behind the gate its
/// links were configured with (``PeerAdvertSwitch``), and no GATT server to report.
@Suite(.timeLimit(.minutes(1))) struct PeerAdvertTests {
    @Test func theSwitchIsKeptForTheRunAndAShutGateOnlyStores() async throws {
        let rig = PeerRig()
        var reply = try await rig.send(#"{"cmd":"advert"}"#)
        #expect(reply["build"] as? Bool == false, "a node made without the gate, as `main` never makes one")
        #expect(reply["gatt"] is NSNull)
        reply = try await rig.send(#"{"cmd":"advert","blind":"on"}"#)
        #expect(reply["applied"] as? Bool == false && reply["why"] as? String == "build")
        #expect((reply["switch"] as? [String: Any])?["value"] as? Bool == true)
        reply = try await rig.send(#"{"cmd":"advert","blind":"clear"}"#)
        #expect((reply["switch"] as? [String: Any])?["stored"] is NSNull)
        #expect((reply["switch"] as? [String: Any])?["default"] as? Bool == true, "the links' switch at construction")
    }

    @Test func theSwitchTakesItsDefaultFromTheLinks() async {
        let host = PeerAdvertSwitch(build: true, defaultSwitch: false)
        #expect(host.build && !host.defaultSwitch)
        #expect(await host.stored() == .clear)
        await host.store(.on)
        #expect(await host.stored() == .on)
        #expect(await host.serving() == nil)
    }
}
