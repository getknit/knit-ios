extension MeshControl {
    /// Reacts to message `id` with `emoji`, or takes our reaction back, and answers the message, us, and the emoji we
    /// hold now, `null` once taken back (ADR 2026-10.ehe6).
    func react(to id: String, with emoji: String) async -> Result<[String: JSONValue], ControlError> {
        guard let reaction = await actions.react(to: id, with: emoji) else {
            return .failure(.refused("no such message, a status line, or not one emoji"))
        }
        return .success(ControlLines.fields(of: reaction))
    }
}
