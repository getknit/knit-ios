import KnitMesh

// The blinded advert's reply fields (ADR 2026-11.prsp, "The bridge and the harness"), under Android's `AdvertStatus` names
// where it has one (`AdvertDiag.kt` at knit-next `cad69c77b`). Never a key, a tag, its hex or a prefix past `zzzz`: the
// status carries none to print.
extension ControlLines {
    /// `advert`'s fields from the link manager's status.
    static func fields(of status: AdvertStatus) -> [String: JSONValue] {
        let install = status.install
        return [
            "blindsAdvert": .bool(status.gate),
            "switchOn": .bool(status.switchOn),
            "blinding": .bool(status.blinding),
            "keyHeld": .bool(status.keyGeneration != nil),
            "keyGeneration": number(status.keyGeneration),
            "radioUp": .bool(status.radioUp),
            "pending": .bool(status.pending),
            "form": .text(status.form?.name),
            "epoch": .int(Int64(status.epoch)),
            "rotatedAtMs": number(install?.at),
            "airedGeneration": number(status.airedGeneration),
            "lastCause": .text(install?.cause),
            "source": .text(install?.tag?.source),
            "resolvable": flag(install?.tag, \.resolvable),
            "stale": flag(install?.tag, \.stale),
            "nextEdgeAtMs": number(status.nextEdgeAt),
            "announced": .bool(status.announced),
            "psm": number(status.psm),
            "restartsLeft": number(status.restartsLeft),
            "bringUpsInSlot": .int(Int64(status.bringUpsInSlot)),
            "counters": describe(status.counters),
            "peers": .array(status.peers.map(describe)),
            "links": .array(status.links.map(describe)),
        ]
    }

    /// The writer's counts.
    static func describe(_ counted: LinkManager.WriterCounters) -> JSONValue {
        let counts: [String: Int] = [
            "rotationsBySlot": counted.rotationsBySlot,
            "rotationsByBringUp": counted.rotationsByBringUp,
            "rotationsByKeyChange": counted.rotationsByKeyChange,
            "rotationsByFlip": counted.rotationsByFlip,
            "rotationsForced": counted.rotationsForced,
            "unannounced": counted.unannounced,
            "randomNoKey": counted.randomNoKey,
            "randomKeyMoved": counted.randomKeyMoved,
            "randomMarkFailed": counted.randomMarkFailed,
            "randomScheduled": counted.randomScheduled,
            "resolvable": counted.resolvable,
            "stale": counted.stale,
            "staleMarkPasses": counted.staleMarkPasses,
            "tagNextAnnounced": counted.tagNextAnnounced,
            "tagNextCurrent": counted.tagNextCurrent,
            "tagNextResent": counted.tagNextResent,
            "tagNextNoKey": counted.tagNextNoKey,
            "tagNextIneligible": counted.tagNextIneligible,
            "tagNextThrottled": counted.tagNextThrottled,
            "tagNextBeforeAnnounce": counted.tagNextBeforeAnnounce,
            "tagNextBehindQueue": counted.tagNextBehindQueue,
            "refusedLegacy": counted.refusedLegacy,
            "refusedHeld": counted.refusedHeld,
            "droppedPayloads": counted.droppedPayloads,
            "linkFormsApplied": counted.linkFormsApplied,
        ]
        return .object(counts.mapValues { .int(Int64($0)) })
    }

    /// One sighting: its id or handle, never a tag.
    static func describe(_ peer: AdvertStatus.Peer) -> JSONValue {
        [
            "peer": .string(peer.peer),
            "resolved": .bool(peer.resolved),
            "blinded": .bool(peer.blinded),
            "iDial": .bool(peer.iDial),
            "linked": .bool(peer.linkedAs != nil),
            "linkedAs": .text(peer.linkedAs),
        ]
    }

    /// One live link, and the kind of the form its peer is known by.
    static func describe(_ link: AdvertStatus.Link) -> JSONValue {
        [
            "nodeId": .string(link.nodeId),
            "proven": .bool(link.proven),
            "dialedByMe": .bool(link.dialedByMe),
            "tagAware": .bool(link.tagAware),
            // Android's name: whether the form its peer is known by is a tag, `null` when none is known.
            "blinded": tagged(link.knownBy),
        ]
    }

    /// The iPhone's GATT server (``GattServingReport``): serials and flags, never a value.
    static func describe(_ report: GattServingReport) -> JSONValue {
        let layout: JSONValue =
            switch report.layout {
            case .combined:
                "combined"
            case .split:
                "split"
            case nil:
                .null
            }
        return [
            "layout": layout,
            "doorbell": number(report.doorbellSerial),
            "payload": number(report.payloadSerial),
            "combined": number(report.combinedSerial),
            "combinedUp": .bool(report.combinedUp),
            "pendingAdd": number(report.pendingSerial),
            "advertising": .bool(report.advertising),
            "retryAtMs": number(report.retryAt),
            "cleared": .bool(report.cleared),
            "doorbellFailed": .bool(report.doorbellFailed),
            "wanted": .text(report.wanted?.name),
            "servesWanted": .bool(report.servesWanted),
            "listenerPsm": number(report.listenerPSM),
            "wantedPsm": number(report.wantedPSM),
            "expectsBlinding": .bool(report.expectsBlinding),
            "restoredServices": number(report.restoredServices),
            "matchedByOrder": .int(Int64(report.matchedByOrder)),
            "poweredOn": .bool(report.poweredOn),
            "appliedTag": .bool(report.applied(blinded: true)),
            "appliedClear": .bool(report.applied(blinded: false)),
        ]
    }

    /// A number, or `null` without one. Serials count up from 1 in the process, so none passes `Int64`'s range.
    private static func number(_ value: (some BinaryInteger)?) -> JSONValue {
        guard let value else {
            return .null
        }
        return .int(Int64(clamping: value))
    }

    /// A tag's fact, or `null` for a clear install.
    private static func flag(_ tag: AdvertStatus.TagFacts?, _ fact: KeyPath<AdvertStatus.TagFacts, Bool>) -> JSONValue {
        guard let tag else {
            return .null
        }
        return .bool(tag[keyPath: fact])
    }

    /// Whether a form is a tag, Android's `blinded`, or `null` when no form is known.
    private static func tagged(_ kind: AdvertStatus.Kind?) -> JSONValue {
        guard let kind else {
            return .null
        }
        return .bool(kind == .tag)
    }
}
