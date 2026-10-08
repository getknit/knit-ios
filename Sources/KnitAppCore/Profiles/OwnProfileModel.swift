public import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
public import Observation

/// The user's own profile's view model: the photo, name, status and open-to-chat flag peers read, and this device's
/// node id and alias.
///
/// A new photo waits for Save with the rest. Android saves a photo the moment its crop is confirmed, and then has to
/// say so, because its Save button stays dimmed (knit-next #26); here Save lights up instead. Save then publishes the
/// photo and the fields apart, each only when it changed, as Android does.
@preconcurrency
@MainActor
@Observable
public final class OwnProfileModel {
    /// How near its limit the name field starts saying what is left.
    public static let nameWarnWithin = 8
    /// How near its limit the status field starts saying what is left.
    public static let statusWarnWithin = 20

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let codec: (any ImageCodec)?
    @ObservationIgnored private let screening: PhotoScreening?
    private var nameText: String
    private var statusText: String
    /// Whether to invite DMs from people not met yet.
    public var openToChat: Bool
    private var photoEdit = PhotoEdit.kept
    private var saved: Saved
    /// Whether the cropper is up. The screen closing it, by Cancel or otherwise, keeps the photo as it was.
    public var isCropping = false
    /// The picked image the cropper shows. It stays after the cropper closes, so the cropper still has it to draw
    /// as it goes.
    public private(set) var cropSource: (any PreparedImage)?
    /// Whether the last photo picked could not be read or cropped, which the screen says until it is dismissed.
    public var photoFailed = false
    /// Whether the last photo cropped looked explicit, so the profile keeps the photo it had; the screen says so until
    /// the next pick (ADR 2026-10.spcy).
    public private(set) var photoRefused = false

    private struct Saved: Equatable {
        var name: String
        var status: String
        var openToChat: Bool
        var photo: BlobHash?
    }

    /// The photo as edited.
    private enum PhotoEdit: Equatable {
        /// As published.
        case kept
        /// A new photo's JPEG and its hash, not yet published.
        case replaced([UInt8], BlobHash)
        /// Removed, not yet published.
        case removed
    }

    /// The profile over `session`, loaded from what it last published, reading and cropping photos through `codec` and
    /// checking them with `screening`.
    public init(session: AppSession, codec: (any ImageCodec)? = nil, screening: PhotoScreening? = nil) {
        self.session = session
        self.codec = codec
        self.screening = screening
        let own = session.stores.ownProfile.load()
        nameText = own.name
        statusText = own.status
        openToChat = own.openToChat
        saved = Saved(name: own.name, status: own.status, openToChat: own.openToChat, photo: own.avatarHash)
    }

    /// The display name as typed, cut at ``TextLimits/displayName`` UTF-16 units.
    public var name: String {
        get { nameText }
        set { nameText = TextLimits.truncated(newValue, toUTF16: TextLimits.displayName) }
    }

    /// The status as typed, cut at ``TextLimits/status`` UTF-16 units.
    public var status: String {
        get { statusText }
        set { statusText = TextLimits.truncated(newValue, toUTF16: TextLimits.status) }
    }

    /// The name field's placeholder: the alias people see while the name is blank.
    public var alias: String {
        session.identity.alias
    }

    /// This device's node id.
    public var nodeId: String {
        session.identity.nodeId.string
    }

    /// Our face as edited: the photo, or the initial of the name as typed, or of the alias while it is blank. Peers draw
    /// the same face from what Save publishes.
    public var face: Face {
        .person(nodeId, name: Alias.displayName(stored: edited.name, nodeId: nodeId), photo: edited.photo)
    }

    /// The JPEG of a photo picked and not yet saved, which the blob store does not hold yet, so the screen draws it
    /// from these bytes.
    public var unsavedPhoto: [UInt8]? {
        if case .replaced(let jpeg, _) = photoEdit {
            return jpeg
        }
        return nil
    }

    /// Whether the profile shows a photo, so Remove photo has something to remove.
    public var hasPhoto: Bool {
        edited.photo != nil
    }

    /// Room left in the name, once it nears the limit.
    public var nameRemaining: Int? {
        Self.remaining(nameText, limit: TextLimits.displayName, within: Self.nameWarnWithin)
    }

    /// Room left in the status, once it nears the limit.
    public var statusRemaining: Int? {
        Self.remaining(statusText, limit: TextLimits.status, within: Self.statusWarnWithin)
    }

    /// Whether anything differs from what was last published.
    public var hasChanges: Bool {
        edited != saved
    }

    /// Decodes a picked photo for the cropper (`AvatarStore.loadForCrop`). One the picker could not hand over, or the
    /// codec cannot read, says so.
    public func choosePhoto(_ data: Data?) async {
        guard let data, let codec, let source = await codec.prepare(data) else {
            photoFailed = true
            return
        }
        photoRefused = false
        cropSource = source
        isCropping = true
    }

    /// Closes the cropper and keeps the photo as it was.
    public func cancelCrop() {
        isCropping = false
    }

    /// Crops the picked photo as `framing` places it, into the photo Save will publish
    /// (`ProfileViewModel.confirmCrop`).
    ///
    /// A profile photo shows to everyone who sees the profile, strangers in Nearby included, so the cropped photo is
    /// checked whatever the content filter says, and one that looks explicit is refused (`AvatarStore.saveOwnAvatar`,
    /// ADR 2026-10.spcy). One the model cannot score goes.
    public func cropPhoto(_ framing: AvatarFraming) async {
        guard isCropping, let source = cropSource else {
            return
        }
        isCropping = false
        guard let jpeg = await codec?.profilePhoto(from: source, crop: framing.crop) else {
            photoFailed = true
            return
        }
        if await screening?.isExplicit(outgoing: jpeg) == true {
            photoRefused = true
            return
        }
        let hash = BlobHash(of: jpeg)
        photoEdit = hash == saved.photo ? .kept : .replaced(jpeg, hash)
    }

    /// Removes the photo, once Save publishes it.
    public func removePhoto() {
        photoEdit = saved.photo == nil ? .kept : .removed
    }

    /// Publishes what changed, normalized the way every peer reads it: the photo first, then the fields.
    public func save() async {
        let profile = edited
        switch photoEdit {
        case .kept:
            break
        case .replaced(let jpeg, _):
            await session.setAvatar(jpeg)
        case .removed:
            await session.setAvatar(nil)
        }
        if (profile.name, profile.status, profile.openToChat) != (saved.name, saved.status, saved.openToChat) {
            await session.updateProfile(name: profile.name, status: profile.status, openToChat: profile.openToChat)
        }
        nameText = profile.name
        statusText = profile.status
        photoEdit = .kept
        saved = profile
    }

    private var edited: Saved {
        let photo: BlobHash? =
            switch photoEdit {
            case .kept:
                saved.photo
            case .replaced(_, let hash):
                hash
            case .removed:
                nil
            }
        return Saved(
            name: Composer.singleLine(nameText, limit: TextLimits.displayName),
            status: Composer.singleLine(statusText, limit: TextLimits.status),
            openToChat: openToChat,
            photo: photo
        )
    }

    private static func remaining(_ text: String, limit: Int, within: Int) -> Int? {
        let left = limit - text.utf16.count
        return left <= within ? max(left, 0) : nil
    }
}
