import KnitWire

/// The profile photo's ceiling on a fetch (contract `profile-door-cap` section 6, ADR 2026-10.r88m): a want made only for
/// a profile photo keeps at most ``FileIntake/maxAvatarBytes`` of any holder's copy, and a holder whose copy is larger is
/// passed over for that hash for the rest of the session.
///
/// Neither signal that a copy is too large is authenticated. A `blobhas` size is the holder's own claim, and the bytes
/// cannot be checked against the hash until the file ends. So the refusal is keyed by holder, the link's node id the ask
/// went to, as Android's is: a holder that streams past the ceiling or claims a size over it is passed over like a holder
/// that brought nothing, and never asked for that hash again this session, by the re-want or a new want included, while
/// the want goes on to the others; with no unmarked holder left it sits as any want whose holders are exhausted. No
/// holder's signal refuses the hash outright, the want's author's included: the author is only whoever advertised the
/// hash, and any peer can sign a profile naming someone else's photo. So a neighbour that lies about a photo's size, or
/// serves junk under its hash, costs one fetch from that neighbour and cannot hide the photo honest holders carry. Only
/// held bytes over the ceiling, which prove the size, refuse the hash (``refusePhoto(_:)``).
///
/// A want stays photo-only only while no other want of ours names the blob: a row's want of ours clears the flag for the
/// want's life, and the larger limit, the attachment's, wins. A neighbour's ask moves no ceiling (`BlobExchange.kt:116`
/// at knit-next `a0b52f865`): an echo nobody else wants takes the attachment's, and our photo want on it, the first want
/// of ours, makes it photo-only (`recordWant` and `mergeCeiling`, `:2211`, `:2233-2253`), so a holder passed over cannot
/// lift the ceiling by asking us for the hash.
extension BlobExchange {
    /// The most holders one photo-only want remembers passing over (``Want/passedOver``, `MAX_PASSED_OVER`,
    /// `BlobExchange.kt:3002`): far more than a phone links in a session; past it the session's own marks still filter them
    /// while they last.
    static let maxPassedOver = 64

    /// Why a want of ours names a blob, which sets the limit its bytes are kept to.
    enum WantKind: Sendable, Equatable {
        /// A message's photo, or anything else: Android's ceiling, ``FileIntake/maxFileBytes``.
        case attachment
        /// A peer's profile photo, and nothing else: ``FileIntake/maxAvatarBytes``.
        case photo
    }

    /// The blobs wanted only as a profile photo, whose bytes the links keep to the photo's ceiling.
    var photoOnlyWanted: Set<BlobHash> {
        Set(wants.values.filter(\.photoOnly).map(\.hash))
    }

    /// Whether `hash` is wanted, and only as a profile photo.
    func isPhotoOnly(_ hash: BlobHash) -> Bool {
        wants[hash]?.photoOnly == true
    }

    /// Whether `hash` is refused as a profile photo for the session: a held copy was over the ceiling
    /// (``refusePhoto(_:)``).
    func isPhotoRefused(_ hash: BlobHash) -> Bool {
        photoRefusals.isRefused(hash)
    }

    /// Refuses `hash` as a profile photo for the session, as a held copy over the ceiling is before it is let go: neither
    /// the re-want nor a new photo want asks for it again.
    mutating func refusePhoto(_ hash: BlobHash) {
        photoRefusals.refuse(hash)
    }

    /// Forgets every refusal: a new session, where the links and the store start over (at start and stop, beside the kept
    /// prefixes).
    mutating func forgetPhotoRefusals() {
        photoRefusals = PhotoRefusals()
    }

    /// `holder` streamed a copy of `hash` past the photo's ceiling, or answered a query with a size over it, and is passed
    /// over for the hash this session: it joins the cycle's failed holders, an ask standing on it ends and is withdrawn,
    /// so a copy it queued and has not begun comes off its link, and every later step leaves it out. The want's author is
    /// marked as any holder is. A copy already streaming runs to its END; the link keeps none of it. Answers the
    /// neighbours owed a `blobcancel`, or `nil` unless `hash` is wanted only as a photo: an attachment's limit is the
    /// larger, and an echo's want is its asker's. The mark is keyed by (hash, holder) alone, in ``PhotoRefusals``.
    mutating func overPhotoCeiling(_ hash: BlobHash, from holder: NodeId) -> [NodeId]? {
        guard var want = wants[hash], want.photoOnly else {
            return nil
        }
        counts.photosOverCeiling += 1
        photoRefusals.mark(hash, holder: holder)
        want.passOver(holder)
        let cancels = want.withdraw(holder) ? [holder] : []
        want.failed.insert(holder)
        if want.fetch?.peer == holder {
            want.fetch = nil
        }
        wants[hash] = want
        return cancels
    }

    /// Copies the session's marks for `want`'s hash into its own ``Want/passedOver`` when it is photo-only, as Kotlin's
    /// `passOver` does on every step (`BlobExchange.kt:491-521`, the filter at `:503-505`), so a mark the bounded set
    /// drops later still leaves the holder out, whoever asks for the hash later: in the order they were marked, so the
    /// bound keeps the same holders every run. Answers the holders it newly passes over that are owed a `blobcancel` for
    /// an ask standing on them, as Kotlin withdraws them (`:506-510`): an echo our photo want made photo-only may have
    /// asked a holder an earlier want marked. Neither counted nor logged again: ``overPhotoCeiling(_:from:)`` did both
    /// when the mark was made. A want that is not photo-only passes over nobody (`:502`).
    func passOver(_ want: inout Want) -> [NodeId] {
        guard want.photoOnly else {
            return []
        }
        var cancels: [NodeId] = []
        for holder in photoRefusals.markedHolders(want.hash) where !want.passedOver.contains(holder) {
            want.passOver(holder)
            // Withdrawn whatever it answered (`:506-510`), unlike ``Want/withdraw(_:)``: its copy is unwanted.
            if want.passedOver.contains(holder), let asked = want.askedAt[holder], want.withdrawnAt[holder] != asked {
                want.withdrawnAt[holder] = asked
                cancels.append(holder)
            }
        }
        return cancels
    }

    /// `linked` as `want` may ask them: all of them, unless it is photo-only, when the holders passed over for its hash
    /// this session, by the session's marks or the want's own (``Want/passedOver``), are left out of every query, ask and
    /// pull.
    func askable(_ linked: [Candidate], for want: Want) -> [Candidate] {
        guard want.photoOnly else {
            return linked
        }
        return linked.filter { !photoRefusals.isMarked(want.hash, holder: $0.id) && !want.passedOver.contains($0.id) }
    }
}

extension BlobExchange.Want {
    /// Remembers `holder` as passed over for this want's photo, while fewer than ``BlobExchange/maxPassedOver`` are: the
    /// count alone bounds it, so two runs of the same calls keep the same set.
    mutating func passOver(_ holder: NodeId) {
        if passedOver.count < BlobExchange.maxPassedOver {
            passedOver.insert(holder)
        }
    }
}

/// The session's profile photo refusals: the (hash, holder) pairs passed over (``BlobExchange/overPhotoCeiling(_:from:)``),
/// and the hashes a held copy over the ceiling refused (``BlobExchange/refusePhoto(_:)``). A neighbour's unsigned frames
/// and its own link name the first, and any profile can name a hash for the second, so each holds at most
/// ``maxEntries``, the oldest dropped first: one dropped is fetched once more from that holder, which marks it again.
/// Insertion order alone decides which goes, so two runs of the same calls keep the same set.
internal struct PhotoRefusals: Sendable {
    /// The most pairs, and the most hashes, remembered.
    static let maxEntries = 1024

    /// One holder passed over for one hash.
    private struct Pair: Hashable, Sendable {
        var hash: BlobHash
        var holder: NodeId
    }

    private var marked: Set<Pair> = []
    private var markedOrder: [Pair] = []
    private var refused: Set<BlobHash> = []
    private var refusedOrder: [BlobHash] = []

    func isMarked(_ hash: BlobHash, holder: NodeId) -> Bool {
        marked.contains(Pair(hash: hash, holder: holder))
    }

    /// The holders marked for `hash`, oldest mark first (`markedHolders`).
    func markedHolders(_ hash: BlobHash) -> [NodeId] {
        markedOrder.filter { $0.hash == hash }.map(\.holder)
    }

    func isRefused(_ hash: BlobHash) -> Bool {
        refused.contains(hash)
    }

    mutating func mark(_ hash: BlobHash, holder: NodeId) {
        let pair = Pair(hash: hash, holder: holder)
        guard marked.insert(pair).inserted else {
            return
        }
        markedOrder.append(pair)
        if markedOrder.count > Self.maxEntries {
            marked.remove(markedOrder.removeFirst())
        }
    }

    mutating func refuse(_ hash: BlobHash) {
        guard refused.insert(hash).inserted else {
            return
        }
        refusedOrder.append(hash)
        if refusedOrder.count > Self.maxEntries {
            refused.remove(refusedOrder.removeFirst())
        }
    }
}
