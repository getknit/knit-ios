/// The link manager's events, handed to the engine.
extension Mesh {
    /// Whether the app is in the background, where iOS may suspend it, so the links seek peers while none is up
    /// (``LinkManager/setInBackground(_:)``). Kept while stopped, for the next start.
    public func setInBackground(_ background: Bool) {
        apply(links.setInBackground(background))
        settle()
    }

    /// Hands each link event to the engine, in order.
    func apply(_ linkEvents: [LinkManager.Event]) {
        for event in linkEvents {
            switch event {
            case .up(let neighbor):
                engine.linkUp(neighbor)
            case .down(let nodeId):
                engine.linkDown(nodeId)
            case .frame(let frame):
                engine.receive(frame)
            case .digest(let ids, let from):
                engine.receiveDigest(ids, from: from)
            case .file(let file):
                engine.receiveFile(file)
            case .fileProgress(let progress):
                engine.fileProgress(progress)
            case .fileSent(let hash, let peer):
                engine.fileSent(hash, to: peer)
            case .fileOverLimit(let hash, let peer):
                engine.fileOverLimit(hash, from: peer)
            }
        }
    }
}
