// A session's reports (ADR 2026-10.f6kf): what a report does on this iPhone. Its email is the user's to send.
extension AppSession {
    /// Files a report on this iPhone: the reported message is deleted, so an unblock never brings it back, and the person
    /// is blocked. Nobody is told, and the mesh sees no change. Never ourselves.
    public func report(_ report: AbuseReport) async {
        guard report.person != identity.nodeId else {
            return
        }
        if let messageId = report.messageId {
            await deleteMessage(messageId)
        }
        await block(report.person)
    }
}
