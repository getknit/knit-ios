import KnitMesh
import KnitWire

extension ControlLines {
    /// One peer's DM ratchet state under the keys of Android's debug bridge `RATCHET` (`DebugBridgeReceiver.kt:1468-1499`),
    /// so one script reads both phones: our epochs as `"epoch@createdAt"`, the most recently minted first, and the root
    /// only as its hash.
    static func fields(of state: RatchetPeerState) -> [String: JSONValue] {
        [
            "peer": .string(state.peer.string),
            "name": .string(state.name),
            "capRatchet": .bool(state.capRatchet),
            "peerPrekeyId": state.peerPrekeyId.map { .int(Int64($0)) } ?? .null,
            "peerPrekeyPinned": .bool(state.peerPrekeyPinned),
            "hasSession": .bool(state.hasSession),
            "confirmed": .bool(state.confirmed),
            "sendEpoch": .int(Int64(state.sendEpoch)),
            "lastResetSentAt": .int(state.lastResetSentAt),
            "establishedAt": .int(state.establishedAt),
            "weAreInitiator": .bool(state.weAreInitiator),
            "highestPeAcked": .int(Int64(state.highestPeAcked)),
            "rootHash": .text(state.rootHash),
            "prevRootExpiresAt": .int(state.prevRootExpiresAt),
            "prevRootOwnInitAt": state.prevRootOwnInitAt.map { .int($0) } ?? .null,
            "hasPeerInitAnchor": .bool(state.hasPeerInitAnchor),
            "localEpochs": .array(state.localEpochs.map { .string("\($0.epoch)@\($0.createdAt)") }),
        ]
    }

    /// How our DMs and reactions were sealed, under the names of Android's metrics (`MeshMetrics.Seals`,
    /// `MeshMetrics.kt:1476-1482`), all five of them.
    static func describe(_ seals: RatchetSealCounts) -> JSONValue {
        [
            "dmSealedV2": .int(Int64(seals.dmSealedV2)),
            "dmSealedV3": .int(Int64(seals.dmSealedV3)),
            "dmSealedV1Fallback": .int(Int64(seals.dmSealedV1Fallback)),
            "reactionsSealed": .int(Int64(seals.reactionsSealed)),
            "reactionsSealedFallback": .int(Int64(seals.reactionsSealedFallback)),
        ]
    }

    /// How many inits our sealed profile answered, and how many times a session moved back onto our own init lost to a
    /// race, under the names of Android's metrics (`introsAnswered` and `ratchetSwappedBack`, in `MeshMetrics.Keys`,
    /// knit-next `MeshMetrics.kt:2209-2218` at `f018bc8ce`): the two of that group this port counts.
    static func describe(_ answers: RatchetAnswerCounts) -> JSONValue {
        [
            "introsAnswered": .int(Int64(answers.introsAnswered)),
            "ratchetSwappedBack": .int(Int64(answers.ratchetSwappedBack)),
        ]
    }

    /// How our receipts and ticks were sealed and how many room ticks rode, under the names of Android's metrics
    /// (`MeshMetrics.Receipts`, `MeshMetrics.kt:1616-1626` at knit-next `afdd37204`): the five this port counts, the re-acks
    /// the exists-gate skipped among them (ADR 2026-10.8hn6).
    static func describe(_ receipts: RatchetReceiptCounts) -> JSONValue {
        [
            "receiptsSealed": .int(Int64(receipts.receiptsSealed)),
            "receiptsSealedFallback": .int(Int64(receipts.receiptsSealedFallback)),
            "receiptsReAckSkipped": .int(Int64(receipts.receiptsReAckSkipped)),
            "receiptsCustodied": .int(Int64(receipts.receiptsCustodied)),
            "receiptsRidden": .int(Int64(receipts.receiptsRidden)),
        ]
    }

    /// How the resets our replacement floor refused went: held, dropped unrun, opened again once the floor ended, and of
    /// those adopted (knit-next ADR 2026-11.sfms; ADR 2026-10.5sk9's P9b amendment). The names are this port's, since
    /// Android's `MeshMetrics` counts only the drop (`RATCHET_RESET_FLOORED`, `MeshMetrics.kt:68-75` at `f018bc8ce`).
    static func describe(_ floored: RatchetFlooredCounts) -> JSONValue {
        [
            "flooredResetsHeld": .int(Int64(floored.flooredResetsHeld)),
            "flooredResetsDropped": .int(Int64(floored.flooredResetsDropped)),
            "flooredResetsReopened": .int(Int64(floored.flooredResetsReopened)),
            "flooredResetsAdopted": .int(Int64(floored.flooredResetsAdopted)),
        ]
    }

    /// How the group form went, under the names of Android's metrics (`MeshMetrics.Groups`, as the debug bridge reports them
    /// at `DebugBridgeReceiver.kt:1321-1329`): the seven this port counts (phase P7d). Android's `groupRootsMinted` and
    /// `groupRootsAdopted` count the `gr` root, which this port leaves out, so they are not here.
    static func describe(_ groups: RatchetGroupCounts) -> JSONValue {
        [
            "groupSealedRatchet": .int(Int64(groups.groupSealedRatchet)),
            "groupSealedV1Fallback": .int(Int64(groups.groupSealedV1Fallback)),
            "groupSeedsSent": .int(Int64(groups.groupSeedsSent)),
            "groupSeedsAdopted": .int(Int64(groups.groupSeedsAdopted)),
            "groupSeedsHeld": .int(Int64(groups.groupSeedsHeld)),
            "groupSeedsReplayed": .int(Int64(groups.groupSeedsReplayed)),
            "groupKeyRequestsSent": .int(Int64(groups.groupKeyRequestsSent)),
        ]
    }
}
