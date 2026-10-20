public import KnitCrypto
import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// The person a contact link names, shown before anything is written (`ContactImporter.preview` in knit-next).
public struct AddContactPreview: Sendable, Equatable, Identifiable {
    /// The person.
    public let nodeId: NodeId
    /// Their label: the name Knit holds for them, else the link's, discriminated when someone else shares it.
    public let title: String
    /// Their alias, grown as far as their label needed.
    public let alias: String
    /// Their face.
    public let face: Face
    /// The safety number both phones should read, in two lines of four groups.
    public let safetyNumber: [String]
    /// Whether they are already a contact: verified, or their conversation accepted (`ContactImporter.kt:84`).
    public let isContact: Bool
    /// Whether the user blocked them, so adding unblocks them too.
    public let isBlocked: Bool
    /// The card the link carried.
    let card: ContactCard.Card

    /// The person, one preview each.
    public var id: NodeId { nodeId }
}

/// Add contact's view model (`AddContactViewModel` in knit-next, ADR 2026-10.tpr5): our code and link, a scanned code,
/// and a link someone sent, previewed before it is added.
@preconcurrency
@MainActor
@Observable
public final class AddContactModel {
    @ObservationIgnored private let session: AppSession
    /// The text in the link field.
    public var input = ""
    /// The person the last link names, until the user adds them or closes the preview.
    public var preview: AddContactPreview?
    /// Why the last link added nobody, until the user has read it.
    public var problem: AddContactProblem?
    /// Our contact link, once signed.
    public private(set) var link: ContactCard.Links?
    /// Why the previewed person was not added, said once the preview has gone.
    @ObservationIgnored private var heldProblem: AddContactProblem?

    /// Add contact over `session`.
    public init(session: AppSession) {
        self.session = session
    }

    /// Whether `text` reads as a contact link, which Add contact takes instead of a browser or a chat
    /// (`ContactCard.looksLikeCard`).
    nonisolated public static func isContactLink(_ text: String) -> Bool {
        ContactCard.looksLikeCard(text)
    }

    /// Our code for the other person to scan: the `knit-id` code, which every Knit scanner reads, as Android draws it
    /// (`AddContactViewModel.myQrPayload`).
    public var ownCode: String {
        VerifyPayload.encode(session.identity.bundle)
    }

    /// The message our link is shared in, once it is signed.
    public var shareText: String? {
        link.map { Copy.AddContact.shareText($0.url) }
    }

    /// Our link alone, as Copy link puts it on the pasteboard, once it is signed.
    public var linkURL: String? {
        link?.url
    }

    /// Signs our link, with the name and the time it is signed at, unless it is already signed.
    public func signLink() async {
        if link == nil {
            link = await session.ownContactLink()
        }
    }

    /// Reads `text` as a link: the person it names to preview, or why it names nobody (`AddContactViewModel.lookup`).
    public func lookup(_ text: String) {
        input = text
        lookup()
    }

    /// Reads the link field: the person it names to preview, or why it names nobody.
    public func lookup() {
        preview = nil
        guard case .card(let card) = ContactCard.parse(input) else {
            problem = .notALink
            return
        }
        guard card.nodeId != session.identity.nodeId else {
            problem = .ownLink
            return
        }
        let directory = session.directory
        let stored = directory.peers[card.nodeId]
        let label = directory.labels.label(for: card.nodeId.string, storedName: Self.nonBlank(stored?.name) ?? card.name)
        // The pinned text, compared by its bytes, as Kotlin compares it (ADR 2026-09.jc2x).
        if let pinned = stored?.publicKey, !pinned.utf8.elementsEqual(card.bundle.utf8) {
            problem = .mismatch(name: label.text)
            return
        }
        guard let theirs = PublicKeyBundle(encoded: card.bundle) else {
            problem = .notALink
            return
        }
        let accepted = session.stores.conversations.acceptedConversations()
        preview = AddContactPreview(
            nodeId: card.nodeId,
            title: label.text,
            alias: label.alias,
            face: .person(card.nodeId.string, name: label.name, photo: stored?.avatarHash),
            safetyNumber: PeerProfileModel.lines(SafetyNumber.compute(mine: session.identity.bundle, theirs: theirs)),
            isContact: directory.verified.contains(card.nodeId) || accepted.contains(card.nodeId.string),
            isBlocked: directory.blocked.contains(card.nodeId),
            card: card
        )
    }

    /// Adds the person previewed, unblocking them if they are blocked (`AddContactViewModel.confirm`), and closes the
    /// preview. Answers whom to open, or `nil` when nobody was added: ``previewClosed()`` then says why.
    public func confirm() async -> NodeId? {
        guard let preview else {
            return nil
        }
        let added = await session.addContact(preview.card, from: .link, unblock: preview.isBlocked)
        self.preview = nil
        switch added {
        case .added(let nodeId):
            input = ""
            return nodeId
        case .ownCode:
            heldProblem = .ownLink
        case .mismatch:
            heldProblem = .mismatch(name: preview.title)
        case .failed:
            heldProblem = .failed
        }
        return nil
    }

    /// The preview has gone: why the person in it was not added, if they were not, is said now, since an alert raised
    /// while a sheet is going is dropped.
    public func previewClosed() {
        problem = heldProblem
        heldProblem = nil
    }

    /// Adds the person whose code was scanned, verified (`AddContactViewModel.onScanned`): their key pins from the code
    /// when none has, and a key other than the pinned one changes nothing.
    public func scanned(_ text: String) async -> AddContactScanOutcome {
        guard case .card(let card) = ContactCard.parse(text) else {
            return .notACode
        }
        guard card.nodeId != session.identity.nodeId else {
            return .ownCode
        }
        switch await session.addContact(card, from: .scan, unblock: false) {
        case .added:
            return .added
        case .ownCode:
            return .ownCode
        case .mismatch:
            return .mismatch
        case .failed:
            return .failed
        }
    }

    private static func nonBlank(_ name: String?) -> String? {
        guard let name, !TextLimits.isBlank(name) else {
            return nil
        }
        return name
    }
}
