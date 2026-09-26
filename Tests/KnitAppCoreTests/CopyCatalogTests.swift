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
            Copy.Chat.profile,
            Copy.Chat.inRange,
            Copy.Chat.outOfRange,
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
            Copy.Status.boundary,
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
            Copy.Diagnostics.discardedFiles,
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
            Copy.Chat.encryptionBody("Sam"),
            Copy.Chat.requestTitle("Sam"),
            Copy.Profile.remaining(3),
            Copy.Profile.safetyNumberCaption("Sam"),
            Copy.Onboarding.step(1, of: 2),
            Copy.Onboarding.nameBody(alias: "OptimallyArtfulFox"),
            Copy.Onboarding.allowLabel("Bluetooth"),
            Copy.Diagnostics.linked(1),
            Copy.Diagnostics.sighted(1),
            Copy.Diagnostics.known(1),
            Copy.Diagnostics.sighting(rssi: -60, secondsAgo: 2),
            Copy.Diagnostics.link(version: 3, capabilities: "9"),
            Copy.Diagnostics.clockAhead(seconds: 5),
            Copy.Diagnostics.clockBehind(seconds: 5),
        ]
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

    @Test func everyStatusHasItsWords() {
        #expect(
            [DeliveryStatus.waitingForKey, .sent, .delivered].map(\.label) == [
                Copy.Delivery.waitingForKey, Copy.Delivery.sent, Copy.Delivery.delivered,
            ])
    }
}
