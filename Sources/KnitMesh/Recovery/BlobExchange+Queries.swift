import KnitWire

/// Holder queries out and their answers in (`queue`, `flushQueries` and `recordAnswers`, `BlobExchange.kt:712-829`,
/// knit-next ADR 2026-10.6e5t), the waits each neighbour's round trip sizes (knit-next #140), and the log's words.
extension BlobExchange {
    /// Queues `hash` for each of `peers`, behind what each is already owed (`queue`).
    mutating func queue(_ hash: BlobHash, for peers: [NodeId]) {
        for peer in peers {
            if let index = outbox.firstIndex(where: { $0.peer == peer }) {
                if !outbox[index].hashes.contains(hash) {
                    outbox[index].hashes.append(hash)
                }
            } else {
                outbox.append((peer, [hash]))
            }
        }
    }

    /// The queries the steps since the last flush owe (`flushQueries`): one frame per neighbour, at most
    /// ``maxQueryHashes`` hashes each, so wants stepped together query together. The engine gives each its id and sends
    /// it, and records it with ``noteQuerySent(_:to:hashes:now:)``.
    mutating func takeQueries() -> [(peer: NodeId, hashes: [BlobHash])] {
        defer { outbox.removeAll() }
        return outbox.flatMap { entry in
            stride(from: 0, to: entry.hashes.count, by: Self.maxQueryHashes).map { start in
                (entry.peer, Array(entry.hashes[start..<min(start + Self.maxQueryHashes, entry.hashes.count)]))
            }
        }
    }

    /// A query went to `peer` under envelope id `id`, so an answer naming it is matched to it. Queries a cycle old are
    /// forgotten, and at most ``maxSentQueries`` are kept, the oldest dropped first.
    mutating func noteQuerySent(_ id: String, to peer: NodeId, hashes: [BlobHash], now: Int64) {
        for key in sentQueries.filter({ now - $0.value.at >= Self.cycleMilliseconds }).keys {
            sentQueries[key] = nil
        }
        sentOrder.removeAll { sentQueries[$0] == nil }
        let key = ExactKey(id)
        if sentQueries.updateValue(SentQuery(peer: peer, at: now, hashes: Set(hashes)), forKey: key) == nil {
            sentOrder.append(key)
        }
        if sentOrder.count > Self.maxSentQueries {
            for dropped in sentOrder.prefix(sentOrder.count - Self.maxSentQueries) {
                sentQueries[dropped] = nil
            }
            sentOrder.removeFirst(sentOrder.count - Self.maxSentQueries)
        }
        counts.queriesSent += 1
    }

    /// `peer` answered a query of ours (`onHaveAnswer` and `recordAnswers`). Only a hash we still want, from a neighbour
    /// queried for it this cycle, counts; when the answer names a query we remember, the hash must be one that query
    /// named, and that query no older than the latest one queued to that neighbour for it. An answer naming no query we
    /// remember is still taken from a neighbour queried this cycle, as Android takes it. Only the first
    /// ``maxQueryHashes`` items are read. Answers the items that counted, and how long their query took, which is kept
    /// as that neighbour's round trip (knit-next #140) whatever the items say.
    mutating func recordAnswers(_ content: BlobHasContent, from peer: NodeId, now: Int64) -> (touched: [BlobHasItem], latency: Int64?) {
        let sent = content.re.flatMap { sentQueries[ExactKey($0)] }.flatMap { $0.peer == peer ? $0 : nil }
        if let sent {
            roundTrips.record(peer, now - sent.at)
        }
        var touched: [BlobHasItem] = []
        for item in content.items.prefix(Self.maxQueryHashes) {
            guard let hash = BlobHash(item.hash), var want = wants[hash], let queriedAt = want.queried[peer] else {
                continue
            }
            if let sent, !sent.hashes.contains(hash) || sent.at < queriedAt {
                continue
            }
            want.answers[peer] = Answer(
                state: item.state,
                load: max(0, content.load ?? 0),
                querySentAt: sent?.at ?? queriedAt
            )
            if item.state.isHeld || item.state == .fetching {
                want.sawLead(at: now)
            }
            wants[hash] = want
            touched.append(item)
        }
        if touched.isEmpty {
            counts.answersIgnored += 1
        } else {
            counts.answersTaken += 1
        }
        return (touched, sent.map { now - $0.at })
    }

    // MARK: Waits sized by the round trip

    /// How long an answer from `peer` may take before it reads as silence (`queryWaitFor`, knit-next #140):
    /// ``queryWaitMilliseconds``, or the round trip its last answer took plus that wait when longer, at most
    /// ``queryWaitCapMilliseconds``. An asker whose own frames are queued on a link would otherwise read its lag as the
    /// neighbour's silence.
    func queryWait(for peer: NodeId) -> Int64 {
        guard let trip = roundTrips[peer] else {
            return Self.queryWaitMilliseconds
        }
        return max(Self.queryWaitMilliseconds, min(trip + Self.queryWaitMilliseconds, Self.queryWaitCapMilliseconds))
    }

    /// An ask's grace (`graceFor`): ``firstAskGraceMilliseconds`` plus the round trip `peer`'s link last took, at most
    /// ``queryWaitCapMilliseconds`` of it (`rttOf`). Android adds its Wi-Fi Aware link's wait too; one radio has none.
    func grace(for peer: NodeId) -> Int64 {
        Self.firstAskGraceMilliseconds + min(roundTrips[peer] ?? 0, Self.queryWaitCapMilliseconds)
    }

    // MARK: The log's words

    /// A state as the log names it (`stateLabel`).
    static func label(_ state: BlobHolding) -> String {
        switch state {
        case .notHeld:
            "NONE"
        case .have:
            "HAVE"
        case .sending:
            "SENDING"
        case .fetching:
            "FETCHING"
        default:
            "state \(state.rawValue)"
        }
    }

    /// One answer as the log shows it (`itemLabel`): its hash's first characters, its state and its size.
    static func label(_ item: BlobHasItem) -> String {
        "\(item.hash.prefix(shownHashCharacters)) \(label(item.state))\(item.size.map { " \($0)B" } ?? "")"
    }

    /// The log line for a step's asks of `hash` (`askLine`), told as `line`, the first ask's. knit-next ADR 2026-10.f7gg's
    /// two lines are kept word for word for the blind round, so one grep reads an iPhone's log and an Android phone's.
    static func askLine(_ hash: BlobHash, _ plan: Plan, _ line: Ask.Line) -> String {
        let shown = "\(hash.string.prefix(shownHashCharacters))…"
        let to = plan.asks.map(\.to.string).joined(separator: ", ")
        let wake = plan.wake ?? 0
        switch line {
        case .first:
            return "blob ask \(shown) → \(to) first (\(plan.why)), widen in \(wake) ms"
        case .widened:
            return "blob ask \(shown) → \(to) widened"
        case .pull:
            return "blob pull \(shown) → \(to) (\(plan.why))"
        case .fetch:
            return "blob fetch \(shown) → \(to) (\(plan.why)), grace \(wake) ms"
        }
    }
}
