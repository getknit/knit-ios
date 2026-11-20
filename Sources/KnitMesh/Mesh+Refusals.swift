extension Mesh {
    /// Group frames custody refused because their roster is not their own (``MeshEngine/groupCustodyRefused``).
    public var groupCustodyRefused: Int { engine.groupCustodyRefused }

    /// Frames custody refused because their `signed` is longer than its byte cap (``MeshEngine/custodyOversizeRefused``),
    /// the counterpart of ``groupCustodyRefused``.
    public var custodyOversizeRefused: Int { engine.custodyOversizeRefused }

    /// Profiles refused because their `signed` is longer than custody's profile cap, at the engine's door or by custody
    /// (``MeshEngine/profileOversizeRefused``), each counted once.
    public var profileOversizeRefused: Int { engine.profileOversizeRefused }

    /// What the paced custody answers, the not-kept memo and the re-offer back-off did (``MeshEngine/custodyRoundCounts``,
    /// the `custody-carry-policy` contract, §8).
    public var custodyRoundCounts: CustodyRoundCounts { engine.custodyRoundCounts }
}
