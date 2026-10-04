public import KnitWire
public import Observation

/// The content filter for photos (ADR 2026-10.rpmq): what is checked before it is sent, and what someone else's
/// photo or face hides behind while the filter is on.
///
/// Android screens a photo as its bytes land and stores the verdict. Here a photo is screened the first time a thread
/// or a face asks for it, from the bytes the blob store holds, opened with the key a sealed photo's message carries,
/// and the verdict lives as long as the app does. So nothing runs while Knit is in the background, and nothing the
/// mesh carries, stores or serves depends on a verdict (ADR 2026-10.5wgg).
@preconcurrency
@MainActor
@Observable
public final class PhotoScreening {
    /// One photo as it is screened: its blob, and the key that opens it when it is sealed. Two messages may name one
    /// blob with different keys, and so different pictures.
    private struct Screened: Hashable {
        var hash: BlobHash
        var key: String?
    }

    /// Whether someone else's explicit photos and faces hide: the Content filtering toggle, on unless turned off, which
    /// the session keeps since it hides messages too (ADR 2026-10.e4kz). What is sent is checked either way.
    public var filtersContent: Bool {
        get { session.filtersContent }
        set { session.filtersContent = newValue }
    }

    @ObservationIgnored private let classifier: (any PhotoClassifier)?
    @ObservationIgnored private let session: AppSession
    /// What each photo screened so far looked like. Views read it through ``isHiding(_:isMine:)`` and
    /// ``isHidingFace(_:)``, so a verdict that lands redraws them.
    private var verdicts: [Screened: Bool] = [:]
    @ObservationIgnored private var screening: [Screened: Task<[Float]?, Never>] = [:]

    /// The filter over `session`'s photos, scoring them with `classifier` (none screens nothing), under the session's
    /// toggle.
    public init(classifier: (any PhotoClassifier)?, session: AppSession) {
        self.classifier = classifier
        self.session = session
    }

    /// Whether `bytes`, a photo about to be sent, look explicit. It is asked whatever the toggle says, which governs
    /// only what we are shown (`ChatViewModel.stage`), and nothing is kept: the next pick is asked afresh.
    public func isExplicit(outgoing bytes: [UInt8]) async -> Bool {
        guard let classifier, let scores = await classifier.scores(of: bytes) else {
            return false
        }
        return ExplicitPhoto.isExplicit(scores)
    }

    /// Whether a thread hides `attachment` behind a tap: the filter is on, someone else sent it, and it is a photo whose
    /// held bytes look explicit. It screens the photo first if nobody has yet, so a view asks before it draws one.
    public func hides(_ attachment: ChatAttachment, isMine: Bool) async -> Bool {
        guard filtersContent, !isMine, attachment.kind == .photo, attachment.isHeld else {
            return false
        }
        return await isExplicit(Screened(hash: attachment.hash, key: attachment.key))
    }

    /// What ``hides(_:isMine:)`` answered for `attachment`, without screening it: `false` until it has been screened.
    /// The thread's VoiceOver actions read it, to offer Show photo in place of View photo.
    public func isHiding(_ attachment: ChatAttachment, isMine: Bool) -> Bool {
        filtersContent && !isMine && attachment.kind == .photo && verdicts[Screened(hash: attachment.hash, key: attachment.key)] == true
    }

    /// Whether a face shows its initial in place of `photo`: the filter is on, the photo is someone else's, and it looks
    /// explicit. Android leaves such a photo unadopted; here it stays adopted and is drawn as if it were not there, so
    /// turning the filter off brings it back.
    public func hidesFace(_ photo: BlobHash) async -> Bool {
        guard filtersContent, photo != session.directory.myPhoto else {
            return false
        }
        return await isExplicit(Screened(hash: photo, key: nil))
    }

    /// What ``hidesFace(_:)`` answered for `photo`, without screening it: `false` until a face has drawn it. A profile
    /// reads it, so a hidden photo does not open in the viewer.
    public func isHidingFace(_ photo: BlobHash) -> Bool {
        filtersContent && photo != session.directory.myPhoto && verdicts[Screened(hash: photo, key: nil)] == true
    }

    /// The verdict on `photo`, screening it once however many ask at the same time. A photo that could not be scored is
    /// let through and asked about again next time, so a model that comes back screens it.
    private func isExplicit(_ photo: Screened) async -> Bool {
        if let known = verdicts[photo] {
            return known
        }
        guard let classifier else {
            return false
        }
        let task = screening[photo] ?? Task { [session] in await Self.scores(of: photo, with: classifier, from: session) }
        screening[photo] = task
        let scores = await task.value
        screening[photo] = nil
        guard let scores else {
            return false
        }
        let verdict = ExplicitPhoto.isExplicit(scores)
        verdicts[photo] = verdict
        return verdict
    }

    /// `photo`'s scores, read and scored off the main actor, since a GIF may weigh megabytes; `nil` when its bytes are
    /// missing or do not open, or the classifier could not score them.
    @concurrent
    nonisolated private static func scores(
        of photo: Screened, with classifier: any PhotoClassifier, from session: AppSession
    ) async -> [Float]? {
        guard let bytes = session.attachment(photo.hash, key: photo.key) else {
            return nil
        }
        return await classifier.scores(of: bytes)
    }
}
