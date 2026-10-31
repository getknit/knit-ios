import KnitWire

/// The most a link's incoming file may hold, read once at its header, and whether passing it passes the link's peer over
/// for the hash (`Ceiling` and `ceilingOf`, knit-next `FileIntake.kt:344-363` at `a0b52f865`, contract
/// `ios-avatar-push-mark`). Only an ATTACHMENT kept under a photo-only want's ceiling marks: its stream answers our
/// want, so passing the ceiling is evidence about that holder. A pushed AVATAR answers nothing and marks nobody, even
/// with a photo-only want of the same hash standing (trial run 20261031-021140), and an attachment under Android's
/// ceiling is the link's business alone. Decided at the header so a want made photo-only mid-stream, or widened, never
/// changes what a stream already begun means.
internal struct IntakeCeiling: Equatable {
    var bytes: Int
    var marks: Bool
}

extension LinkManager {
    /// The ceiling a file of `kind` and `key` is kept under (`ceilingOf`, knit-next `FileIntake.kt:344-363` at
    /// `a0b52f865`), `nil` for an attachment nobody asked for. A pushed AVATAR's is the photo's and never marks; a photo-only
    /// want's ATTACHMENT's is the photo's and marks while it is below Android's ceiling; any other attachment's is
    /// Android's ceiling, which marks nobody.
    static func ceiling(
        of kind: FileHeader.Kind, _ key: BlobHash, accepted: Set<BlobHash>, photoOnly: Set<BlobHash>, avatarLimit: Int
    ) -> IntakeCeiling? {
        let photo = min(avatarLimit, FileIntake.maxFileBytes)
        switch kind {
        case .avatar:
            return IntakeCeiling(bytes: photo, marks: false)
        case .attachment:
            guard accepted.contains(key) else {
                return nil
            }
            guard photoOnly.contains(key), photo < FileIntake.maxFileBytes else {
                return IntakeCeiling(bytes: FileIntake.maxFileBytes, marks: false)
            }
            return IntakeCeiling(bytes: photo, marks: true)
        }
    }

    /// Why a file was dropped past its limit, after the abandon's words: `over its limit`, frozen so a grep for it
    /// still finds the line, then Android's facts (`overCeiling`, knit-next `FileIntake.kt:372-386` at `a0b52f865`), the
    /// ceiling, the kind, the declared size or `?`, where a resumed stream starts, and the peer.
    static func overLimit(_ header: FileHeader, _ ceiling: IntakeCeiling?, from peer: NodeId) -> String {
        let offset = header.offset ?? 0
        let from = offset > 0 ? " from \(offset)" : ""
        return "over its limit of \(known(ceiling?.bytes))B, \(header.kind.rawValue) \(known(header.size))B\(from) from \(peer)"
    }

    /// A count for the log, or `?` where none is known, as Android's `${size ?: "?"}`.
    private static func known(_ count: Int?) -> String {
        count.map(String.init) ?? "?"
    }
}
