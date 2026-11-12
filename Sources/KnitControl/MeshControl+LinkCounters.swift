import KnitMesh

// Apart from the actor only to keep its file inside the lint's length.
extension MeshControl {
    /// The link's proof and seal counters, for `status`.
    func linkCounters() async -> [String: JSONValue] {
        [
            // One name each on both phones (the `link-hello-proof` contract, §9).
            "linksProven": .int(Int64(await mesh.linksProven)),
            "linkProofFailed": .int(Int64(await mesh.linkProofFailed)),
            "linkClaimRefused": .int(Int64(await mesh.linkClaimRefused)),
            // One name each on both phones (the `link-seal` contract, §9).
            "linksSealed": .int(Int64(await mesh.linksSealed)),
            "linkSealFailed": .int(Int64(await mesh.linkSealFailed)),
            "linkSealRefused": .int(Int64(await mesh.linkSealRefused)),
        ]
    }
}
