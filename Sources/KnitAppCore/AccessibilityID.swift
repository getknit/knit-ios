/// The identifiers UI tests find views by. Each is Android's test tag for the same view, so one checklist drives both
/// apps (`testTag` in knit-next's `ui/`). The few Android has no tag for say so; the iPhone's device tests read them.
public enum AccessibilityID {
    /// The onboarding flow.
    public static let onboardingScreen = "screen_onboarding"
    /// The welcome page.
    public static let onboardingWelcome = "onboarding_page_welcome"
    /// The name page.
    public static let onboardingNamePage = "onboarding_page_name"
    /// The permissions page.
    public static let onboardingPermissions = "onboarding_page_permissions"
    /// The name field.
    public static let onboardingName = "onboarding_name"
    /// The button that moves to the next page.
    public static let onboardingNext = "onboarding_next"
    /// The button that finishes onboarding.
    public static let onboardingStart = "onboarding_start"
    /// The permissions page's Allow for Bluetooth. Android has no tag here.
    public static let onboardingAllowBluetooth = "onboarding_allow_bluetooth"
    /// The permissions page's Allow for notifications. Android has no tag here.
    public static let onboardingAllowNotifications = "onboarding_allow_notifications"

    /// The chat list's status line: how many peers are linked, or why none can be.
    public static let chatListStatus = "chat_list_status"
    /// The status line's words, `chat_list_status_<state>`: the identifier names the state, so a test reads it without
    /// reading the words. Android has no tag here, nor for the line's two buttons below.
    public static func chatListStatus(_ state: StatusState) -> String {
        "chat_list_status_\(state.rawValue)"
    }

    /// The status line's Start, offered while the mesh is stopped.
    public static let chatListStatusStart = "chat_list_status_start"
    /// The status line's way to Knit's page in the Settings app, offered while Bluetooth is refused.
    public static let chatListStatusSettings = "chat_list_status_settings"
    /// The status line's info button, offered while the mesh runs, which shows the radio's boundary.
    public static let chatListStatusAbout = "chat_list_status_about"
    /// The note that button shows under the line.
    public static let chatListBoundary = "chat_list_boundary"
    /// The chat list's way to Settings.
    public static let chatListSettings = "chat_list_settings"
    /// The chat list's way to the message requests.
    public static let chatListRequests = "chat_list_requests"

    /// The chat list's rows, each `contact_<conversation id>` as on Android.
    public static func chatRow(_ conversationId: String) -> String {
        "contact_\(conversationId)"
    }

    /// The thread's message list.
    public static let chatThread = "chat_thread"
    /// The composer.
    public static let chatInput = "chat_input"
    /// The send button.
    public static let chatSend = "chat_send"
    /// A message's tick, `chat_tick_<message id>`.
    public static func chatTick(_ messageId: String) -> String {
        "chat_tick_\(messageId)"
    }

    /// A verified DM's shield.
    public static let chatVerified = "chat_verified_shield"
    /// A DM's way to the other person's profile.
    public static let chatProfile = "chat_profile"
    /// A thread's encryption sheet, for a group, whose lock is not a verified DM's shield. Android has no tag here.
    public static let chatEncryption = "chat_encryption"
    /// A group thread's way to group info (Android's overflow "Settings").
    public static let chatGroupInfo = "chat_group_settings"
    /// A status line in a thread, `chat_notice_<row id>`. Android has no tag here.
    public static func chatNotice(_ id: String) -> String {
        "chat_notice_\(id)"
    }

    /// The chat list's New message, Android's floating button.
    public static let chatListNewMessage = "chatlist_fab"
    /// The New message picker. Android has no tag here.
    public static let newMessageScreen = "screen_new_message"
    /// One person in the picker, `new_message_contact_<node id>`. Android tags them `contact_<node id>`, which here is
    /// already a chat row's, and a DM's row carries the same node id.
    public static func newMessageContact(_ nodeId: String) -> String {
        "new_message_contact_\(nodeId)"
    }

    /// The picker's Start chat (Android's "Start chat" check).
    public static let newMessageStart = "contacts_start_chat"

    /// Group info.
    public static let groupInfoScreen = "screen_group_details"
    /// Group info's Rename group.
    public static let groupRename = "group_rename"
    /// Group info's Leave group.
    public static let groupLeave = "group_leave"
    /// A member in group info, `group_member_<node id>`.
    public static func groupMember(_ nodeId: String) -> String {
        "group_member_\(nodeId)"
    }

    /// A request's row, `request_row_<conversation id>`.
    public static func requestRow(_ conversationId: String) -> String {
        "request_row_\(conversationId)"
    }

    /// A request's accept button, `request_accept_<conversation id>`.
    public static func requestAccept(_ conversationId: String) -> String {
        "request_accept_\(conversationId)"
    }

    /// Another person's profile.
    public static let profileDetailsScreen = "screen_profile_details"
    /// Its Message button.
    public static let profileDetailsMessage = "profile_details_message"
    /// Its node id row.
    public static let profileDetailsNodeId = "profile_details_node_id"
    /// Its alias row.
    public static let profileDetailsAlias = "profile_details_alias"
    /// Its presence line.
    public static let profileDetailsPresence = "profile_details_presence"
    /// Its verification row.
    public static let profileDetailsVerified = "profile_details_verified"
    /// Our own verify code, for them to scan. Android has no tag here.
    public static let profileDetailsCode = "profile_details_code"
    /// The button that opens the scanner. Android has no tag here.
    public static let profileDetailsScan = "profile_details_scan"
    /// Their photo, which opens the viewer. Android has no tag here, nor for the photo controls and screens below.
    public static let profileDetailsPhoto = "profile_details_photo"

    /// The scanner, as Android tags it.
    public static let scanScreen = "screen_scan"
    /// The scanner's state, `scan_state_<state>`, which the device tests read. Android has no tag here.
    public static func scanState(_ state: ScanState) -> String {
        "scan_state_\(state.rawValue)"
    }

    /// The own profile.
    public static let profileScreen = "screen_profile"
    /// Its name field.
    public static let profileName = "profile_name"
    /// Its status field.
    public static let profileStatus = "profile_status"
    /// Its open-to-chat switch.
    public static let profileOpenToChat = "profile_open_to_chat"
    /// Its node id row.
    public static let profileNodeId = "profile_node_id"
    /// Its alias row.
    public static let profileAlias = "profile_alias"
    /// Its save button.
    public static let profileSave = "profile_save"
    /// Its Choose photo, or Change photo.
    public static let profileChoosePhoto = "profile_choose_photo"
    /// Its Remove photo.
    public static let profileRemovePhoto = "profile_remove_photo"

    /// The photo cropper.
    public static let photoCropScreen = "screen_photo_crop"
    /// The cropper's Choose.
    public static let photoCropChoose = "photo_crop_choose"
    /// The photo viewer.
    public static let photoViewerScreen = "screen_photo_viewer"

    /// Settings.
    public static let settingsScreen = "screen_settings"
    /// Settings' profile row.
    public static let settingsProfileRow = "settings_profile_row"
    /// Settings' Stop or Start button.
    public static let settingsMesh = "settings_mesh"
    /// Settings' way to About, Android's `settings_menu_about`.
    public static let settingsAbout = "settings_menu_about"
    /// Settings' way to Diagnostics.
    public static let settingsDiagnostics = "settings_diagnostics"
    /// About.
    public static let aboutScreen = "screen_about"
    /// About's licence notice.
    public static let aboutLicense = "about_license"
    /// About's source link.
    public static let aboutSource = "about_source"
    /// About's version line.
    public static let aboutVersion = "about_version"
    /// Diagnostics.
    public static let diagnosticsScreen = "screen_diagnostics"

    /// What the chat list's status line says, as ``chatListStatus(_:)`` names it. Kept here rather than taken from
    /// `ConnectionStatus`, because the UI test bundles compile this file without the rest of KnitAppCore.
    public enum StatusState: String, CaseIterable, Sendable {
        /// Running, with peers linked.
        case linked = "linked"
        /// Running, with no peer linked yet.
        case looking = "looking"
        /// Running, before the radio has said anything.
        case starting = "starting"
        /// Stopped in Settings.
        case stopped = "stopped"
        /// Bluetooth is switched off.
        case bluetoothOff = "bluetooth_off"
        /// Knit may not use Bluetooth.
        case notAllowed = "not_allowed"
        /// No Bluetooth LE here.
        case unsupported = "unsupported"
    }

    /// What the scanner shows, as ``scanState(_:)`` names it. Kept here for the same reason as ``StatusState``.
    public enum ScanState: String, CaseIterable, Sendable {
        /// Asking whether it can scan.
        case checking = "checking"
        /// The camera is up.
        case scanning = "scanning"
        /// Knit may not use the camera, named as the status line names a Bluetooth refusal.
        case notAllowed = "not_allowed"
        /// This device cannot scan.
        case unsupported = "unsupported"
        /// The camera failed to start.
        case unavailable = "unavailable"
    }
}
