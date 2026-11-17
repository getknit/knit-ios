import KnitWire

/// A round's pushes (`pushMissing`, `ScopeSync.kt:2122-2153`, `:2236-2251`), one at a time, within the connection's send
/// queue and the hour's upload budget (P4b1).
extension ScopeHeal {
    /// The frames this spool lacks and will take (`pushMissing`, `:2122-2153`), in custody's order. A retiring scope takes
    /// none (C-3.1-3).
    mutating func beginPushes(_ session: inout SpoolSession, now: SpoolNow) {
        // Every caller holds a step.
        if var current = step, let state = states[current.scope.id] {
            if !current.scope.retiring {
                current.pushes = current.held.filter { held in
                    !current.listedSet.contains(held.id) && !state.invalid.contains(held.id) && !state.unpushable.contains(held.id)
                        && !upload.storedRecently(held.id, now: now.monotonic) && pushable(held, current, session: session, now: now)
                }
            }
            step = current
            nextPush(&session, now: now)
        }
    }

    /// Pushes the next frame, one at a time. A push the session cannot send while it is ready and the scope subscribed
    /// did not fit the spool's `maxRecord`, so that frame is unpushable here, or the scope would list every tick.
    ///
    /// Two bounds of this port's own (P4b1): while the connection's send queue is at its cap (``outboundFull``) the pushes
    /// wait for it to drain, and a push that the hour's upload budget (``SpoolUpload``) cannot carry ends the scope's
    /// pushes for this round, counted, the frame left for a later hour.
    mutating func nextPush(_ session: inout SpoolSession, now: SpoolNow) {
        // Every caller holds a step.
        if var current = step {
            let scope = current.scope.id
            while let held = current.pushes.first {
                if outboundFull, session.isReady {
                    counts.outboundHeld += 1
                    current.phase = .held
                    step = current
                    return
                }
                guard upload.fits(held.sealed.blob.count, now: now.monotonic) else {
                    counts.pushBudgetDeferred += current.pushes.count
                    current.pushes.removeAll()
                    break
                }
                current.pushes.removeFirst()
                let stamp: PowStamp?
                switch stampNeed(scope, session: session, now: now) {
                case .unasked:
                    stamp = nil
                case .stamp(let ready):
                    stamp = ready
                case .waiting:
                    demandStamp(scope, session: session, now: now)
                    current.pushes.removeAll()
                    continue
                }
                if let request = session.push(scope, blobId: held.id, data: held.sealed.blob, pow: stamp, now: now.monotonic) {
                    upload.charge(session.lastSentCount, now: now.monotonic)
                    current.phase = .pushing(request: request, blob: held, stamped: stamp != nil)
                    step = current
                    return
                }
                guard session.isReady, session.isSubscribed(scope) else {
                    current.pushes.removeAll()
                    break
                }
                if states[scope]?.unpushable.insert(held.id) == true {
                    counts.unpushable += 1
                    current.learnt = true
                }
                states[scope]?.stickyUnpushable.insert(held.id)
            }
            step = current
            finishStep(&session)
        }
    }

    /// A push's answer (`pushMissing` and `survivable`, `:2139-2151`, `:2236-2251`): a stored blob folds into the anchor; a
    /// refusal of the blob (`tombstoned`, `too_large`, `bad_id`) makes it unpushable and the round steps over it; `rate`
    /// waits at most 5 s and goes on to the next; `pow` without a stamp asks one mined; anything else ends the scope's
    /// pushes. A push refusal parks nothing: a park is a scope refusal's (`handleScopeError`).
    mutating func pushAnswered(_ held: HeldBlob, stamped: Bool, _ reply: SpoolReply, session: inout SpoolSession, now: SpoolNow) {
        // Every caller holds a step.
        if var current = step {
            let scope = current.scope.id
            switch reply {
            case .stored:
                session.foldPushed(scope, blobId: held.id)
                upload.stored(held.id, in: scope, now: now.monotonic)
                current.pushed.append(held.id)
                counts.pushed += 1
                step = current
                nextPush(&session, now: now)
            case .refused(let refusal) where Self.refusesTheBlob(refusal):
                if states[scope]?.unpushable.insert(held.id) == true {
                    counts.unpushable += 1
                }
                // A tombstone lapses and a listing says so; a blob the spool called too large or misaddressed stays refused.
                if !refusal.code.is(SpoolErrorCode.tombstoned) {
                    states[scope]?.stickyUnpushable.insert(held.id)
                }
                current.learnt = true
                step = current
                nextPush(&session, now: now)
            case .refused(let refusal) where refusal.code.is(SpoolErrorCode.rate):
                current.phase = .rateWait(until: SpoolSession.later(now.monotonic, by: refusal.rateWaitMilliseconds))
                step = current
            case .refused(let refusal) where refusal.code.is(SpoolErrorCode.pow):
                // `stampDemand` (`:3271-3283`): a demand for a stamp we did not send is met next time. A refused stamp on a push
                // parks the scope, as on a `sub`.
                if stamped {
                    states[scope]?.stamp = nil
                    park(scope, for: refusal.parkMilliseconds, now: now)
                } else {
                    demandStamp(scope, session: session, now: now)
                }
                current.pushes.removeAll()
                step = current
                finishStep(&session)
            default:
                current.pushes.removeAll()
                step = current
                finishStep(&session)
            }
        }
    }

    static func refusesTheBlob(_ refusal: SpoolRefusal) -> Bool {
        refusal.code.is(SpoolErrorCode.tombstoned) || refusal.code.is(SpoolErrorCode.tooLarge) || refusal.code.is(SpoolErrorCode.badId)
    }

    /// The connection's send queue drained below its cap: pushes held for it go on.
    mutating func outboundDrained(_ session: inout SpoolSession, now: SpoolNow) {
        guard case .held? = step?.phase else {
            return
        }
        nextPush(&session, now: now)
        advance(&session, now: now)
    }
}
