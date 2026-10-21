import Foundation
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Reporting (ADR 2026-10.f6kf): a report deletes the message and blocks its author on this phone, from a message, a
/// profile or a request, and its email says who, where, when and what. Android has no report to pin it against.
@MainActor
@Suite struct ReportTests {
    private let sam = AppRig.sam
    private let stranger = AppRig.stranger

    /// 2026-10-04 at 12:00 UTC, in milliseconds.
    private static let noon: Int64 = 1_791_115_200_000

    @Test func reportingARoomPostDeletesItAndBlocksItsAuthor() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        await rig.receive("Something awful", from: sam.nodeId, id: "post", sentAt: Self.noon)
        await rig.session.send("Mine", in: Conversations.nearby)
        let room = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let post = try #require(room.state.messages.first { $0.id == "post" })
        let report = try #require(room.reporting(post))
        #expect(
            report
                == AbuseReport(
                    person: sam.nodeId, name: "Sam", place: .room, messageId: "post", words: "Something awful", sentAt: Self.noon))

        await room.report(report)
        #expect(rig.mesh.calls.deleted == ["message post"], "the post is deleted, so an unblock never brings it back")
        #expect(rig.mesh.calls.blocked == ["block \(sam.nodeId)"])
        #expect(room.state.messages.map(\.body) == ["Mine"])
    }

    @Test func ourOwnMessagesAndStatusLinesHaveNoReport() async throws {
        let rig = AppRig()
        await rig.session.send("Mine", in: Conversations.nearby)
        let room = ChatModel(conversationId: Conversations.nearby, session: rig.session)
        let mine = try #require(room.state.messages.first)
        #expect(room.reporting(mine) == nil)
        var notice = mine
        notice.isMine = false
        notice.notice = "Sam joined"
        #expect(room.reporting(notice) == nil)
        await rig.session.report(AbuseReport(person: rig.me, name: "Me", place: .profile))
        #expect(rig.mesh.calls.blocked.isEmpty, "never ourselves")
    }

    @Test func aStrangersMessageIsReportedFromTheirRequest() async throws {
        let rig = AppRig()
        await rig.receive("Hey you", from: stranger.nodeId, to: rig.me, id: "dm")
        let thread = ChatModel(conversationId: stranger.nodeId.string, session: rig.session)
        let message = try #require(thread.state.messages.first)
        #expect(try #require(thread.reporting(message)).place == .request)

        let requests = RequestsModel(session: rig.session)
        let row = try #require(requests.rows.first)
        let report = try #require(requests.reporting(row))
        #expect(report.messageId == nil && report.place == .request && report.person == stranger.nodeId)
        await requests.report(report)
        #expect(rig.mesh.calls.deleted.isEmpty)
        #expect(requests.rows.isEmpty, "the block takes the request")
        #expect(rig.notifier.withdrawn.contains(NotificationPolicy.requestsThread))
    }

    @Test func aGroupsRequestHasNobodyToReport() async {
        let rig = AppRig()
        let theirs = await rig.group([stranger, sam], createdBy: stranger)
        let requests = RequestsModel(session: rig.session)
        let row = RequestRow(id: theirs.id, title: "Group", isGroup: true, preview: nil, lastMessageAt: 0, face: .room)
        #expect(requests.reporting(row) == nil)
    }

    @Test func aProfileReportCarriesTheirStatusAndBlocks() async throws {
        let rig = AppRig()
        await rig.pin(sam, name: "Sam")
        let profile = PeerProfileModel(nodeId: sam.nodeId, session: rig.session)
        let report = try #require(profile.reporting)
        #expect(report.place == .profile && report.messageId == nil && report.name == "Sam")
        await profile.report(report)
        #expect(rig.mesh.calls.blocked == ["block \(sam.nodeId)"])
        #expect(profile.state.isBlocked)
        #expect(PeerProfileModel(nodeId: rig.me, session: rig.session).reporting == nil)
    }

    @Test func theEmailSaysWhoWhereWhenAndWhatButNeverAttachesThePhoto() throws {
        let report = AbuseReport(
            person: sam.nodeId,
            name: "Sam",
            place: .group("Hikers"),
            messageId: "m1",
            words: "Meet me & bring cash + more",
            sentAt: Self.noon,
            hadPhoto: true
        )
        let email = ReportEmail(report, version: "0.1.0 (7)", now: Date(timeIntervalSince1970: 1_791_118_800))
        #expect(email.subject == "Knit report: Sam")
        let lines = email.body.components(separatedBy: "\n")
        #expect(lines.first == "Reported from Knit 0.1.0 (7) for iPhone at 2026-10-04T13:00:00Z.")
        #expect(lines.contains("Node ID: \(sam.nodeId.string)"))
        #expect(lines.contains("Where: Group \"Hikers\""))
        #expect(lines.contains("Sent: 2026-10-04T12:00:00Z"))
        #expect(lines.contains("Meet me & bring cash + more"))
        #expect(lines.contains(Copy.Report.emailPhoto))

        let url = try #require(email.mailto)
        let link = url.absoluteString
        #expect(link.hasPrefix("mailto:\(AbuseReport.address)?subject=Knit%20report%3A%20Sam&body="))
        #expect(link.contains("%26%20bring%20cash%20%2B%20more"), "& and + would end the field and read as a space")
        #expect(link.components(separatedBy: "&").count == 2, "one & between subject and body")
    }

    @Test func aPersonsEmailHasNoMessage() {
        let report = AbuseReport(person: sam.nodeId, name: "Sam", place: .profile, status: "Ask me anything")
        let body = ReportEmail(report, version: "0.1.0 (7)", now: Date(timeIntervalSince1970: 0)).body
        #expect(body.contains("Status: Ask me anything") && body.contains("Where: Profile"))
        #expect(!body.contains(Copy.Report.emailMessage))
    }
}

extension CopyCatalogTests {
    /// Reporting's strings (ADR 2026-10.f6kf), apart so the suite stays under the lint's length.
    static var reportStrings: [String] {
        let places: [AbuseReport.Place] = [.room, .direct, .group("Hikers"), .request, .profile]
        return [
            Copy.Report.report,
            Copy.Report.reportPerson("Sam"),
            Copy.Report.confirmTitle("Sam"),
            Copy.Report.confirmMessage("Sam"),
            Copy.Report.confirmPerson("Sam"),
            Copy.Report.reportAndEmail,
            Copy.Report.noMailTitle,
            Copy.Report.noMailBody(AbuseReport.address),
            Copy.Report.copyAddress,
            Copy.Report.emailSubject("Sam"),
            Copy.Report.emailIntro(version: "0.1.0 (7)", at: "2026-10-04T13:00:00Z"),
            Copy.Report.emailPerson("Sam"),
            Copy.Report.emailNodeId("abc"),
            Copy.Report.emailSent("2026-10-04T12:00:00Z"),
            Copy.Report.emailStatus("Hi"),
            Copy.Report.emailMessage,
            Copy.Report.emailNoWords,
            Copy.Report.emailPhoto,
            Copy.Report.emailAddMore,
            Copy.About.contact,
            Copy.Settings.reportProblem,
            Copy.Settings.safetyFooter(AbuseReport.address),
        ] + places.map(Copy.Report.emailPlace)
    }
}

extension AccessibilityIDTests {
    /// Reporting's identifiers (ADR 2026-10.f6kf), the iPhone's own: Android has no report.
    @Test func eachReportNamesWhatItReports() {
        #expect(AccessibilityID.requestReport("abc") == "request_report_abc")
        #expect(AccessibilityID.requestReport("abc") != AccessibilityID.requestBlock("abc"))
        #expect(AccessibilityID.chatMessageReport == "chat_message_report")
        #expect(AccessibilityID.profileDetailsReport == "profile_details_report")
    }
}
