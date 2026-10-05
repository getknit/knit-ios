extension MeshControl {
    /// Deletes what `command` names here, sending nothing (ADR 2026-10.u7cq). A chat with nothing left in it is no
    /// error: its reply says it deleted nothing.
    func answer(_ command: DeleteCommand) async -> Result<[String: JSONValue], ControlError> {
        switch command {
        case .message(let id):
            guard await actions.deleteMessage(id) else {
                return .failure(.refused("no such message, or a status line"))
            }
            return .success(["id": .string(id)])
        case .chat(let conversation):
            return .success(["conv": .string(conversation), "deleted": .bool(await actions.deleteChat(conversation))])
        }
    }
}
