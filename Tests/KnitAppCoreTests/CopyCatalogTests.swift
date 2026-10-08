import Foundation
import KnitAppCore
import KnitMesh
import Testing

/// Every string in the catalog, read: each is prose on one line, with no doubled space and no space before a
/// stop, which is what a slip in wrapping a long literal would leave behind.
@Suite struct CopyCatalogTests {
    private static var everyString: [String] {
        [
            Copy.Launch.waitingTitle,
            Copy.Launch.waitingBody,
            Copy.Launch.retry,
            Copy.Chat.roomEmpty,
            Copy.Chat.roomNotice,
            Copy.Chat.composerPlaceholder,
            Copy.Chat.send,
            Copy.Chat.sending,
            Copy.Chat.profile,
            Copy.Chat.inRange,
            Copy.Chat.outOfRange,
            Copy.Chat.scrollToNewest,
            Copy.Chat.encrypted,
            Copy.Chat.requestBody,
            Copy.Chat.accept,
            Copy.Delivery.sent,
            Copy.Delivery.delivered,
            Copy.Delivery.waitingForKey,
            Copy.Requests.title,
            Copy.Requests.explanation,
            Copy.Requests.empty,
            Copy.Requests.accept,
            Copy.Status.looking,
            Copy.Status.starting,
            Copy.Status.bluetoothOff,
            Copy.Status.notAllowed,
            Copy.Status.unsupported,
            Copy.Status.stopped,
            Copy.Status.start,
            Copy.Status.boundaryOpen,
            Copy.Status.boundaryButton,
            Copy.ChatList.title,
            Copy.ChatList.nearby,
            Copy.ChatList.noMessages,
            Copy.ChatList.requests,
            Copy.ChatList.gettingStartedTitle,
            Copy.ChatList.gettingStartedBody,
            Copy.ChatList.gettingStartedAction,
            Copy.ChatList.settings,
            Copy.ChatList.inRange,
            Copy.Diagnostics.title,
            Copy.Diagnostics.thisDevice,
            Copy.Diagnostics.bluetooth,
            Copy.Diagnostics.mesh,
            Copy.Diagnostics.running,
            Copy.Diagnostics.stopped,
            Copy.Diagnostics.noneLinked,
            Copy.Diagnostics.noneSighted,
            Copy.Diagnostics.clockInStep,
            Copy.Diagnostics.counters,
            Copy.Diagnostics.filesReceived,
            Copy.Diagnostics.filesRefused,
            Copy.Diagnostics.filesSent,
            Copy.TestIdentity.title,
            Copy.TestIdentity.footer,
            Copy.TestIdentity.above,
            Copy.TestIdentity.below,
            Copy.TestIdentity.mint,
            Copy.TestIdentity.invalidNodeId,
            Copy.TestIdentity.noRoom,
            Copy.Notifications.nearbyTitle,
            Copy.Notifications.requestTitle,
            Copy.Onboarding.welcomeTitle,
            Copy.Onboarding.welcomeTagline,
            Copy.Onboarding.hopTitle,
            Copy.Onboarding.hopBody,
            Copy.Onboarding.sealedTitle,
            Copy.Onboarding.sealedBody,
            Copy.Onboarding.carryTitle,
            Copy.Onboarding.carryBody,
            Copy.Onboarding.getStarted,
            Copy.Onboarding.nameTitle,
            Copy.Onboarding.nameNext,
            Copy.Onboarding.nameSkip,
            Copy.Onboarding.permissionsTitle,
            Copy.Onboarding.bluetoothTitle,
            Copy.Onboarding.bluetoothBody,
            Copy.Onboarding.bluetoothDenied,
            Copy.Onboarding.notificationsTitle,
            Copy.Onboarding.notificationsBody,
            Copy.Onboarding.optional,
            Copy.Onboarding.allow,
            Copy.Onboarding.allowed,
            Copy.Onboarding.unsupported,
            Copy.Onboarding.start,
            Copy.Profile.title,
            Copy.Profile.publicSection,
            Copy.Profile.deviceSection,
            Copy.Profile.nameLabel,
            Copy.Profile.statusLabel,
            Copy.Profile.nodeIdLabel,
            Copy.Profile.aliasLabel,
            Copy.Profile.aliasFooter,
            Copy.Profile.openToChat,
            Copy.Profile.openToChatFooter,
            Copy.Profile.message,
            Copy.Profile.inRange,
            Copy.Profile.outOfRange,
            Copy.Profile.encryptionSection,
            Copy.Profile.verified,
            Copy.Profile.notVerified,
            Copy.Profile.noKey,
            Copy.Profile.safetyNumber,
            Copy.Profile.markVerified,
            Copy.Profile.clearVerification,
            Copy.Settings.title,
            Copy.Settings.meshSection,
            Copy.Settings.stop,
            Copy.Settings.start,
            Copy.Settings.stopFooter,
            Copy.Settings.notifications,
            Copy.Settings.notificationsOn,
            Copy.Settings.notificationsAsk,
            Copy.Settings.notificationsOff,
            Copy.Settings.notificationsFooter,
            Copy.Settings.about,
            Copy.Settings.diagnostics,
            Copy.About.title,
            Copy.About.license,
            Copy.About.source,
            Copy.About.notices,
            Copy.About.security,
            Copy.Common.cancel,
            Copy.Common.save,
            Copy.Common.done,
            Copy.Common.openSettings,
            Copy.Common.you,
            Copy.System.bluetoothUsage,
            Copy.About.version("0.1.0", build: "1"),
            Copy.Notifications.roomBody(sender: "Sam", body: "hi"),
            Copy.Notifications.requestBody(1),
            Copy.Notifications.requestBody(2),
            Copy.TestIdentity.minted("abc"),
            Copy.Status.linked(1),
            Copy.Status.linked(2),
            Copy.ChatList.preview(speaker: "Sam", body: "hi"),
            Copy.ChatList.requestCount(1),
            Copy.ChatList.requestCount(2),
            Copy.Chat.directEmpty("Sam"),
            Copy.Chat.remaining(1),
            Copy.Chat.remaining(2),
            Copy.Chat.encryptionWho("Sam"),
            Copy.Chat.requestTitle("Sam"),
            Copy.Profile.remaining(3),
            Copy.Profile.safetyNumberCaption("Sam"),
            Copy.Onboarding.step(1, of: 2),
            Copy.Onboarding.nameBody(alias: "OptimallyArtfulFox"),
            Copy.Onboarding.allowLabel("Bluetooth"),
            Copy.Diagnostics.linked(1),
            Copy.Diagnostics.sighted(1),
            Copy.Diagnostics.known(1),
            Copy.Diagnostics.knownNewest(5),
            Copy.Diagnostics.sighting(rssi: -60, secondsAgo: 2),
            Copy.Diagnostics.link(version: 3, capabilities: "9"),
            Copy.Diagnostics.clockAhead(seconds: 5),
            Copy.Diagnostics.clockBehind(seconds: 5),
        ] + Self.groupStrings + Self.newMessageStrings + Self.verifyStrings + Self.photoStrings + Self.blockStrings + Self.deleteStrings
            + Self.moderationStrings + Self.reactionStrings + Self.reportStrings + Self.termsStrings + Self.infoStrings
    }

    private static var photoStrings: [String] {
        [
            Copy.Profile.choosePhoto,
            Copy.Profile.changePhoto,
            Copy.Profile.removePhoto,
            Copy.Profile.photoFooter,
            Copy.Profile.viewPhoto,
            Copy.Photo.cropHint,
            Copy.Photo.cropChoose,
            Copy.Photo.zoom,
            Copy.Photo.unreadable,
            Copy.Photo.profilePhoto,
        ] + Self.attachmentStrings
    }

    private static var verifyStrings: [String] {
        [
            Copy.Profile.codeCaption("Sam"),
            Copy.Profile.scan,
            Copy.Scan.hint,
            Copy.Scan.denied,
            Copy.Scan.unsupported,
            Copy.Scan.unavailable,
            Copy.System.cameraUsage,
        ] + VerifyScanOutcome.allCases.map { Copy.Profile.scanOutcome($0, name: "Sam") }
    }

    private static var groupStrings: [String] {
        [
            Copy.Groups.unnamed,
            Copy.Groups.names(["Sam", "Priya", "Theo"]) ?? "",
            Copy.Groups.memberCount(1),
            Copy.Groups.memberCount(3),
            Copy.Groups.info,
            Copy.Groups.members,
            Copy.Groups.rename,
            Copy.Groups.nameLabel,
            Copy.Groups.renameAction,
            Copy.Groups.leave,
            Copy.Groups.leaveTitle,
            Copy.Groups.leaveBody,
            Copy.Groups.leaveAction,
            Copy.Groups.encryptionWho,
            Copy.Groups.nobodyLeft,
            Copy.Groups.waitingForKeys,
            Copy.Groups.requestTitle("Sam"),
            Copy.Groups.requestBody,
            Copy.Groups.created(by: "Sam"),
            Copy.Groups.createdByYou,
            Copy.Groups.left("Sam"),
            Copy.Groups.rejoined("Sam"),
            Copy.Groups.renamed(by: "Sam", to: "Hikers"),
        ]
    }

    private static var newMessageStrings: [String] {
        [
            Copy.NewMessage.title,
            Copy.NewMessage.explanation,
            Copy.NewMessage.emptyTitle,
            Copy.NewMessage.emptyBody,
            Copy.NewMessage.full(8),
            Copy.NewMessage.start,
        ]
    }

    /// An unnamed group's title joins its members' names as Android's `joinNames` does.
    @Test func anUnnamedGroupsTitleJoinsItsMembersNames() {
        #expect(Copy.Groups.names([]) == nil)
        #expect(Copy.Groups.names(["Sam"]) == "Sam")
        #expect(Copy.Groups.names(["Sam", "Priya"]) == "Sam & Priya")
        #expect(Copy.Groups.names(["Dani", "Sam", "Priya", "Theo"]) == "Dani, Sam, Priya & Theo")
        #expect(Copy.Groups.memberCount(1) == "1 member" && Copy.Groups.memberCount(3) == "3 members")
        #expect(Copy.NewMessage.full(8).contains("8"))
    }

    @Test func everyStringIsCleanProseOnOneLine() {
        let strings =
            Self.everyString + [nil, .on, .off, .unauthorized, .unsupported].map(Copy.Diagnostics.radio)
            + DropReason.allCases.map(Copy.Drops.reason)
        #expect(strings.count > 150)
        for text in strings {
            #expect(!text.isEmpty)
            #expect(!text.contains("\n"), "\(text)")
            #expect(!text.contains("  "), "\(text)")
            #expect(!text.contains(" ."), "\(text)")
            #expect(!text.contains(" ,"), "\(text)")
            #expect(text == text.trimmingCharacters(in: .whitespaces), "\(text)")
            #expect(!text.contains("%"), "a placeholder left unfilled: \(text)")
        }
    }
}

/// The identifiers UI tests find views by, which are Android's test tags.
@Suite struct AccessibilityIDTests {
    @Test func aRowsIdentifierNamesItsThreadAsAndroidsTagDoes() {
        #expect(AccessibilityID.chatRow("nearby") == "contact_nearby")
        #expect(AccessibilityID.chatTick("m1") == "chat_tick_m1")
        #expect(AccessibilityID.requestRow("abc") == "request_row_abc")
        #expect(AccessibilityID.requestAccept("abc") == "request_accept_abc")
        #expect(AccessibilityID.chatInput == "chat_input" && AccessibilityID.chatSend == "chat_send")
    }

    /// The group screens' identifiers: Android's tags where it has them (`chat_group_settings`, `group_rename`,
    /// `group_leave`, `group_member_<id>`), and the iPhone's own otherwise.
    @Test func theGroupScreensIdentifiersAreAndroidsWhereItHasThem() {
        #expect(AccessibilityID.chatGroupInfo == "chat_group_settings")
        #expect(AccessibilityID.groupRename == "group_rename" && AccessibilityID.groupLeave == "group_leave")
        #expect(AccessibilityID.groupMember("abc") == "group_member_abc")
        #expect(AccessibilityID.chatNotice("created:g-1") == "chat_notice_created:g-1")
        #expect(AccessibilityID.groupInfoScreen == "screen_group_details")
        #expect(AccessibilityID.chatEncryption == "chat_encryption")
    }

    /// New message's identifiers: Android's tags for its button (`chatlist_fab`) and its check (`contacts_start_chat`),
    /// and the iPhone's own for the screen and its people, whose Android tag a chat row already has.
    @Test func newMessagesIdentifiersAreAndroidsWhereTheyCanBe() {
        #expect(AccessibilityID.chatListNewMessage == "chatlist_fab" && AccessibilityID.newMessageStart == "contacts_start_chat")
        #expect(AccessibilityID.newMessageScreen == "screen_new_message")
        #expect(AccessibilityID.newMessageContact("abc") == "new_message_contact_abc")
        #expect(AccessibilityID.newMessageContact("abc") != AccessibilityID.chatRow("abc"))
    }

    /// The ids only the iPhone has, which the device tests read: the status line's state and its buttons, and
    /// onboarding's Allow buttons.
    @Test func theStatusLinesIdentifierNamesItsState() {
        #expect(AccessibilityID.chatListStatus(.bluetoothOff) == "chat_list_status_bluetooth_off")
        #expect(AccessibilityID.chatListStatus(.notAllowed) == "chat_list_status_not_allowed")
        #expect(Set(AccessibilityID.StatusState.allCases.map(AccessibilityID.chatListStatus)).count == 7)
        #expect(AccessibilityID.chatListStatusStart == "chat_list_status_start")
        #expect(AccessibilityID.chatListStatusSettings == "chat_list_status_settings")
        #expect(AccessibilityID.chatListStatusAbout == "chat_list_status_about")
        #expect(AccessibilityID.onboardingAllowBluetooth == "onboarding_allow_bluetooth")
    }

    /// The verify code's identifiers: Android's tag for the scanner (`screen_scan`), and the iPhone's own for the
    /// profile's code and button and the scanner's state, which the device tests read.
    @Test func theScannersIdentifiersNameItsState() {
        #expect(AccessibilityID.scanScreen == "screen_scan")
        #expect(AccessibilityID.scanState(.notAllowed) == "scan_state_not_allowed")
        #expect(Set(AccessibilityID.ScanState.allCases.map(AccessibilityID.scanState)).count == 5)
        #expect(AccessibilityID.profileDetailsCode == "profile_details_code")
        #expect(AccessibilityID.profileDetailsScan == "profile_details_scan")
    }

    @Test func everyStatusHasItsWords() {
        #expect(
            [DeliveryStatus.waitingForKey, .sent, .delivered].map(\.label) == [
                Copy.Delivery.waitingForKey, Copy.Delivery.sent, Copy.Delivery.delivered,
            ])
    }
}

extension CopyCatalogTests {
    /// Photos in chats: the lines that name what a message carries, the thread's and the composer's words, and Save.
    private static var attachmentStrings: [String] {
        [
            Copy.Attachments.photoPreview,
            Copy.Attachments.gifPreview,
            Copy.Attachments.voicePreview,
            Copy.Attachments.filePreview("map.pdf"),
            Copy.Attachments.linkPreview,
            Copy.Attachments.photo,
            Copy.Attachments.voiceMessage,
            Copy.Attachments.file,
            Copy.Attachments.photoWaiting,
            Copy.Attachments.photoUnreadable,
            Copy.Attachments.voiceUnsupported,
            Copy.Attachments.fileUnsupported,
            Copy.Attachments.viewPhoto,
            Copy.Attachments.addPhoto,
            Copy.Attachments.stagedPhoto,
            Copy.Attachments.removePhoto,
            Copy.Attachments.save,
            Copy.Attachments.saved,
            Copy.Attachments.saveFailed,
            Copy.Attachments.saveDenied,
            Copy.System.photoLibraryAddUsage,
        ]
    }
}

extension CopyCatalogTests {
    /// Blocking's strings (ADR 2026-10.5wgg), apart so the suite stays under the lint's length.
    static var blockStrings: [String] {
        [
            Copy.Block.block,
            Copy.Block.unblock,
            Copy.Block.blockPerson("Sam"),
            Copy.Block.unblockPerson("Sam"),
            Copy.Block.badge,
            Copy.Block.confirmTitle("Sam"),
            Copy.Block.confirmBody,
            Copy.Block.barTitle("Sam"),
            Copy.Block.barBody,
            Copy.Block.listTitle,
            Copy.Block.empty,
            Copy.Block.listFooter,
        ]
    }
}

extension CopyCatalogTests {
    /// The content filter's strings (ADR 2026-10.rpmq, ADR 2026-10.e4kz), apart so the suite stays under the lint's
    /// length.
    static var moderationStrings: [String] {
        [
            Copy.Moderation.filter,
            Copy.Moderation.filterFooter,
            Copy.Moderation.hiddenPhoto,
            Copy.Moderation.hiddenPhotoValue,
            Copy.Moderation.showPhoto,
            Copy.Moderation.explicitTitle,
            Copy.Moderation.profileRefusal,
            Copy.Moderation.roomRefusal,
            Copy.Moderation.hiddenWords,
            Copy.Moderation.hiddenMessage,
            Copy.Moderation.showMessage,
            Copy.Moderation.checkingMessage,
            Copy.Moderation.wordsRefusedTitle,
            Copy.Moderation.wordsRefusedInRoom,
        ]
    }
}
