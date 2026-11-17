import KnitCrypto
import KnitWire

/// What the spool sent (`SpoolConnection.onMessage` and its handlers). A client never closes on a record it cannot use:
/// it drops it, says why in a ``SpoolSessionEvent/dropped(_:)``, and keeps the connection.
extension SpoolSession {
    /// Reads one record the spool sent.
    mutating func receive(_ bytes: [UInt8]) {
        guard phase != .closed else {
            return
        }
        guard let record = SpoolRecord(decoding: bytes) else {
            // A hello kotlinx cannot read closes 4002 in `onHello`; any other unreadable record is dropped.
            if phase == .awaitingHello, Self.namesHello(bytes) {
                end(.version, code: SpoolCloseCode.version)
            } else {
                emit(.dropped(.undecodable))
            }
            return
        }
        if case .hello(let hello) = record {
            onHello(hello)
        } else if phase == .awaitingHello {
            emit(.dropped(.beforeHello))
        } else {
            onRecord(record)
        }
    }

    private mutating func onRecord(_ record: SpoolRecord) {
        switch record {
        case .digest(let digest):
            onDigest(digest)
        case .event(let event):
            onEvent(event)
        case .blob(let blob):
            onBlob(blob)
        case .list(let listing):
            onListing(listing)
        case .ok(let ok):
            onOk(ok)
        case .err(let err):
            onErr(err)
        case .other(let type):
            emit(.dropped(.unknown(SpoolText(type))))
        default:
            // `sub`, `pull` and `push` are ours to send, never the spool's (and `hello` was read before).
            emit(.dropped(.unmatched))
        }
    }

    /// The spool's hello (`onHello`): one overlap check, the clamps, then our reply. Only the first is read.
    private mutating func onHello(_ hello: SpoolHello) {
        guard phase == .awaitingHello else {
            emit(.dropped(.lateHello))
            return
        }
        // `min` greater than `v` is an empty range, which a Swift `ClosedRange` would trap on: two comparisons instead.
        guard (hello.minimum ?? hello.version) <= SpoolRecordLayer.version, SpoolRecordLayer.version <= hello.version else {
            end(.version, code: SpoolCloseCode.version)
            return
        }
        negotiated(limits: hello.limits?.clamped(), powBits: min(max(hello.powBits ?? 0, 0), SpoolPow.maxBits))
        // Below our 12-byte reply the spool's `maxRecord` could carry nothing: the handshake fails as Kotlin's does.
        guard send(SpoolHello.client.encoded) else {
            end(.noHello)
            return
        }
        emit(.connected)
    }

    /// A scope's anti-entropy cue: the anchor and count move, and a change is the cue to heal (`handleDigest`). Its `count`
    /// is an echo kept for a status line and its `bounds` are not kept; neither is ever read as a size.
    private mutating func onDigest(_ record: SpoolDigest) {
        guard case (let scope, _)? = subscribedScope(record.scope) else {
            return
        }
        guard let digest = ScopeCrypto.digestValue(record.digest) else {
            emit(.dropped(.malformed))
            return
        }
        let anchor = SpoolAnchor(digest: digest, count: record.count, full: record.full)
        let previous = anchors.updateValue(anchor, forKey: scope)
        subAnswered(scope)
        if previous?.digest != anchor.digest || previous?.count != anchor.count {
            emit(.digest(scope))
        }
    }

    /// A live blob another subscriber pushed (`handleEvent`). Unsolicited by design, so the `maxBlob` this side declared
    /// is the one bound left.
    private mutating func onEvent(_ record: SpoolEvent) {
        guard case (let scope, let bounds)? = subscribedScope(record.scope), let blobId = id(record.blobId) else {
            return
        }
        guard record.data.count <= bounds.maxBlob else {
            emit(.dropped(.oversize))
            return
        }
        emit(.live(SpoolArrival(scope: scope, blobId: blobId, data: record.data)))
    }

    /// A pulled blob (`onBlob`): taken for the oldest outstanding pull of its scope that named the id and has not been
    /// served it, once, and over the declared `maxBlob` only as an id to quarantine (§9.3).
    private mutating func onBlob(_ record: SpoolBlob) {
        guard case (let scope, let bounds)? = subscribedScope(record.scope), let blobId = id(record.blobId) else {
            return
        }
        let owner = pending.keys.sorted().first { request in
            pending[request]?.scope == scope && pending[request]?.unserved.contains(blobId) == true
        }
        guard let owner else {
            emit(.dropped(.unsolicited))
            return
        }
        pending[owner]?.unserved.remove(blobId)
        // Over the `maxBlob` this side declared, it is no answer to what we asked (`inboundCap`): what we will not send we
        // will not take, and unlike the hello's, the spool did not choose it. The id goes back in `oversize` for the heal
        // loop to quarantine in its invalid set (§9.3, `PullOutcome.oversize`).
        if record.data.count > bounds.maxBlob {
            pending[owner]?.oversize.append(blobId)
        } else {
            emit(.pulled(request: owner, SpoolArrival(scope: scope, blobId: blobId, data: record.data)))
        }
    }

    /// A listing (`onListing`): it answers a `list` of ours about the same scope, or nothing. A listing for another scope
    /// would re-anchor us on a set we never asked about.
    private mutating func onListing(_ record: SpoolList) {
        guard let scope = id(record.scope) else {
            return
        }
        guard let entry = pending[record.request], entry.kind == .list, entry.scope == scope else {
            emit(.dropped(.unmatched))
            return
        }
        pending[record.request] = nil
        replied()
        let live = (record.blobIds ?? []).compactMap(SpoolID.init)
        let tombstones = (record.tombstones ?? []).compactMap(SpoolID.init)
        emit(.answered(request: record.request, .listing(live: live, tombstones: tombstones)))
    }

    /// A success (`onOk`). An `ok` for a `q` never issued, or already answered, is no reply and resets nothing.
    private mutating func onOk(_ record: SpoolOk) {
        guard let entry = pending.removeValue(forKey: record.request) else {
            emit(.dropped(.unmatched))
            return
        }
        replied()
        let reply: SpoolReply
        switch entry.kind {
        case .list:
            reply = .unanswered
        case .pull:
            // `missing` answers this pull: ids it never named, or named and was served, are not ours to act on.
            var unserved = entry.unserved
            let missing = (record.missing ?? []).compactMap(SpoolID.init).filter { unserved.remove($0) != nil }
            reply = .pulled(missing: missing, oversize: entry.oversize)
        case .push:
            reply = .stored
        }
        emit(.answered(request: record.request, reply))
    }

    /// A failure (`onErr`), read by its `q` first:
    /// - an outstanding request's `q` answers it, unless its `scope` names another scope, which answers nothing;
    /// - a waiting `sub`'s `q` with a scope it named refuses that scope, and with no scope refuses the batch
    ///   (`SpoolSession+Subscriptions`);
    /// - any other `q` this connection issued is late, its request timed out or its `sub` settled, and moves nothing:
    ///   a late `rate` must not cost a subscription its anchor.
    ///
    /// With no `q`, or one never issued, a subscribed scope is refused and no scope is the connection's error. A `ticket`
    /// code answers no `sub` (B-7.2-8), so it never drops a scope.
    private mutating func onErr(_ record: SpoolErr) {
        var scope: SpoolID?
        if let bytes = record.scope {
            guard let named = id(bytes) else {
                return
            }
            scope = named
        }
        let refusal = SpoolRefusal(record)
        if let request = record.request, settledByRequest(request, scope, refusal) {
            return
        }
        guard let scope else {
            emit(.spoolError(refusal))
            return
        }
        guard isSubscribed(scope), !refusal.code.is(SpoolErrorCode.ticket) else {
            emit(.dropped(isSubscribed(scope) ? .unmatched : .unsubscribed))
            return
        }
        forget(scope)
        emit(.scopeRefused(scope, refusal))
    }

    /// Reads an `err` by its `q` (`onErr`'s first three cases). Answers whether that settled it; `false` leaves it to be
    /// read by its scope, as one whose `q` was never issued here, or a waiting `sub`'s refusal of a scope it named.
    private mutating func settledByRequest(_ request: Int64, _ scope: SpoolID?, _ refusal: SpoolRefusal) -> Bool {
        if let entry = pending[request] {
            if scope == nil || scope == entry.scope {
                pending[request] = nil
                replied()
                emit(.answered(request: request, .refused(refusal)))
            } else {
                emit(.dropped(.unmatched))
            }
            return true
        }
        if subsInFlight[request] != nil {
            guard let scope else {
                // A `ticket` answers no `sub` (B-7.2-8): it refuses nothing, and the batch's 30 s lapse settles it.
                if refusal.code.is(SpoolErrorCode.ticket) {
                    emit(.dropped(.unmatched))
                } else {
                    subRefused(request, refusal)
                }
                return true
            }
            guard subWaits(request, on: scope) else {
                emit(.dropped(.unmatched))
                return true
            }
            return false
        }
        guard (1..<nextRequest).contains(request) else {
            return false
        }
        emit(.dropped(.unmatched))
        return true
    }

    /// The scope a scoped record names and the bounds this side declared for it, once it is 32 bytes and subscribed here;
    /// the drop said otherwise.
    private mutating func subscribedScope(_ bytes: [UInt8]) -> (SpoolID, ScopeBounds)? {
        guard let scope = id(bytes) else {
            return nil
        }
        guard let bounds = subscriptions[scope] else {
            emit(.dropped(.unsubscribed))
            return nil
        }
        return (scope, bounds)
    }

    /// `bytes` as an id, or a ``SpoolDrop/malformed`` drop.
    private mutating func id(_ bytes: [UInt8]) -> SpoolID? {
        guard let id = SpoolID(bytes) else {
            emit(.dropped(.malformed))
            return nil
        }
        return id
    }

    /// Whether unreadable bytes still name `hello` (`SpoolCodec.peekType`), which `onHello` answers with 4002.
    private static func namesHello(_ bytes: [UInt8]) -> Bool {
        guard bytes.count <= SpoolRecordLayer.maxInboundRecord, case .map(let entries)? = try? CBOR.decode(bytes) else {
            return false
        }
        return entries.contains { entry in
            guard case .text(let key) = entry.key, case .text(let value) = entry.value else {
                return false
            }
            return key.utf8.elementsEqual("t".utf8) && value.utf8.elementsEqual(SpoolRecordType.hello.utf8)
        }
    }
}
