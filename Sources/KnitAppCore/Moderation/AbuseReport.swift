public import Foundation
public import KnitWire

/// A report of someone (ADR 2026-10.f6kf), from a message's menu, their profile or their request. Filing it acts on this
/// iPhone at once: the reported message is deleted (ADR 2026-10.u7cq) and the person is blocked (ADR 2026-10.5wgg),
/// which is all a phone with no server behind it can take down. The user may also email it to Knit, as ``ReportEmail``.
public struct AbuseReport: Sendable, Equatable, Identifiable {
    /// Where an emailed report goes.
    public static let address = "iosreports@getknit.app"

    /// Where the user met what they report.
    public enum Place: Sendable, Equatable {
        /// The Nearby room.
        case room
        /// A DM.
        case direct
        /// A group, by its title.
        case group(String)
        /// A message request.
        case request
        /// Their profile.
        case profile
    }

    /// The person reported.
    public var person: NodeId
    /// Their label, as the user saw it.
    public var name: String
    /// Where the user met it.
    public var place: Place
    /// The reported message, deleted from this iPhone with the report, or `nil` when the person is reported.
    public var messageId: String?
    /// The message's words, which go in the email whatever the content filter hid.
    public var words: String
    /// When the message was sent, by its author's clock, in milliseconds.
    public var sentAt: Int64?
    /// Whether the message carried a photo, which the email never attaches.
    public var hadPhoto: Bool
    /// Their status line, for a report from their profile.
    public var status: String
    /// What the message quoted, when it was a reply (ADR 2026-10.mn29): a quote can be what was abusive.
    public var quote: Quote?

    /// What a reported reply quoted: whom, as the thread named them, and the words the reply carried, whatever this
    /// iPhone hid of them.
    public struct Quote: Sendable, Equatable {
        /// Who wrote the quoted message.
        public var author: String
        /// The quoted words, or what stands in for them.
        public var words: String

        /// A quote.
        public init(author: String, words: String) {
            self.author = author
            self.words = words
        }
    }

    /// A report of `person` itself, or of one message of theirs when `messageId` is set.
    public init(
        person: NodeId,
        name: String,
        place: Place,
        messageId: String? = nil,
        words: String = "",
        sentAt: Int64? = nil,
        hadPhoto: Bool = false,
        status: String = "",
        quote: Quote? = nil
    ) {
        self.person = person
        self.name = name
        self.place = place
        self.messageId = messageId
        self.words = words
        self.sentAt = sentAt
        self.hadPhoto = hadPhoto
        self.status = status
        self.quote = quote
    }

    /// The message's id, or the person's.
    public var id: String { messageId ?? person.string }
}

/// A report as the email the user may send to Knit (ADR 2026-10.f6kf): who, where, when and what, in words the user
/// reads before sending, and never a photo. The user sends it, from their own mail, or does not.
public struct ReportEmail: Sendable, Equatable, Identifiable {
    /// The email's subject.
    public var subject: String
    /// The email's text.
    public var body: String
    /// The report it carries.
    public var id: String

    /// `report` as an email, from Knit `version`, at `now`.
    public init(_ report: AbuseReport, version: String, now: Date) {
        id = report.id
        subject = Copy.Report.emailSubject(report.name)
        var lines = [
            Copy.Report.emailIntro(version: version, at: Self.stamp(now)),
            "",
            Copy.Report.emailPerson(report.name),
            Copy.Report.emailNodeId(report.person.string),
            Copy.Report.emailPlace(report.place),
        ]
        if let sentAt = report.sentAt {
            lines.append(Copy.Report.emailSent(Self.stamp(Date(milliseconds: sentAt))))
        }
        if !report.status.isEmpty {
            lines.append(Copy.Report.emailStatus(report.status))
        }
        if report.messageId != nil {
            lines += ["", Copy.Report.emailMessage, report.words.isEmpty ? Copy.Report.emailNoWords : report.words]
            if report.hadPhoto {
                lines.append(Copy.Report.emailPhoto)
            }
            if let quote = report.quote {
                lines.append(Copy.Report.emailQuote(quote.author, quote.words.isEmpty ? Copy.Report.emailNoWords : quote.words))
            }
        }
        lines += ["", Copy.Report.emailAddMore, ""]
        body = lines.joined(separator: "\n")
    }

    /// A `mailto:` link to ``AbuseReport/address`` carrying the subject and text, for a phone without Mail's account,
    /// or `nil` if it cannot be made.
    public var mailto: URL? {
        // Only the unreserved characters go bare: `URLComponents` leaves `&` and `+` alone in a query item's value,
        // and a mail app reads them as the next field and a space.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: unreserved),
            let encodedBody = body.addingPercentEncoding(withAllowedCharacters: unreserved)
        else {
            return nil
        }
        return URL(string: "mailto:\(AbuseReport.address)?subject=\(encodedSubject)&body=\(encodedBody)")
    }

    /// A moment as ISO 8601 in UTC, which reads the same to Knit wherever the reporter is.
    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
