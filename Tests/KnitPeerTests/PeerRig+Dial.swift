import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// Plays the dialer of a link on `channel` of a node that accepts it, proving `keys`'s id as an upgraded build does (the
/// `link-hello-proof` contract, §5): our HELLO with the bit and a fresh nonce, then, once the node's reply and PROOF are
/// written, our own PROOF over both HELLOs. `deliver` hands the node a radio event, and `written` reads back the records it
/// wrote on the channel, those written before the dial included. The node then registers the link as proven.
func dialProving(
    as keys: IdentityKeys, on channel: ChannelID, deliver: (RadioEvent) async -> Void, written: () -> [LinkRecord]
) async throws {
    let before = written().count
    // Shaped like Android v2.11.0: two sealing builds refuse a plain link (the `link-seal` contract, §7).
    let proving = Capabilities.local.union(.blobHave).subtracting(.linkSeal)
    let hello = Hello(nodeId: keys.nodeId.string, capabilities: proving, nonce: LinkProof.freshNonce())
    await deliver(.accepted(channel))
    await deliver(.received(channel, record(.hello, hello.payload)))
    let answered = await waitUntil {
        let tags = written().dropFirst(before).map(\.tag)
        return tags.contains(.hello) && tags.contains(.proof)
    }
    try #require(answered, "the node answered with its HELLO and its PROOF")
    let reply = try #require(written().dropFirst(before).first { $0.tag == .hello })
    let proof = try LinkProof.payload(keys: keys, form: .plain, signer: .dialer, dialerHello: hello.payload, responderHello: reply.payload)
    await deliver(.received(channel, record(.proof, proof)))
}

/// A link record's bytes.
func record(_ tag: LinkRecord.Tag, _ payload: [UInt8]) -> [UInt8] {
    LinkRecord(tag, payload: payload).encoded ?? []
}
