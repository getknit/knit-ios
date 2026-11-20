import KnitMesh

extension ControlLines {
    /// The `custody-carry-policy` contract's counters (§8), each a top-level `status` key under the name Android's
    /// `metricsJson` reports, so a harness reads one name on both phones.
    static func fields(of counts: CustodyRoundCounts) -> [String: JSONValue] {
        [
            "custodyRoundsCut": .int(Int64(counts.custodyRoundsCut)),
            "custodyAnswersCutShort": .int(Int64(counts.custodyAnswersCutShort)),
            "custodyNotKept": .int(Int64(counts.custodyNotKept)),
            "custodyReoffersHeld": .int(Int64(counts.custodyReoffersHeld)),
        ]
    }
}
