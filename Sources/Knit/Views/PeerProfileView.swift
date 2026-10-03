#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// Another person's profile: who they are, their safety number and our code for them to scan, and Message (MVP
    /// items 3 and 5, ADR 2026-10.65xx).
    internal struct PeerProfileView: View {
        @State private var model: PeerProfileModel
        @State private var scanning = false
        /// What the scan found, until its sheet has gone.
        @State private var pending: VerifyScanOutcome?
        /// What the scan found, while the alert says so.
        @State private var outcome: VerifyScanOutcome?
        /// Whether their photo is open full screen.
        @State private var viewing = false
        @Environment(\.dynamicTypeSize) private var typeSize
        private let camera: any CameraAccess

        init(nodeId: NodeId, session: AppSession, camera: any CameraAccess) {
            _model = State(initialValue: PeerProfileModel(nodeId: nodeId, session: session))
            self.camera = camera
        }

        var body: some View {
            let state = model.state
            Form {
                Section {
                    PeerHeader(state: state) { viewing = true }
                    if !model.isSelf {
                        NavigationLink(value: Route.chat(state.conversationId)) {
                            // At the accessibility sizes the glyph left the word too little room, and it broke.
                            if typeSize.isAccessibilitySize {
                                Text(Copy.Profile.message)
                            } else {
                                Label(Copy.Profile.message, systemImage: "message")
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.profileDetailsMessage)
                    }
                }
                Section {
                    ValueRow(Copy.Profile.aliasLabel, value: state.alias)
                        .accessibilityIdentifier(AccessibilityID.profileDetailsAlias)
                    NodeIdRow(nodeId: state.nodeId.string)
                        .accessibilityIdentifier(AccessibilityID.profileDetailsNodeId)
                }
                if !model.isSelf {
                    EncryptionSection(
                        state: state,
                        scan: { scanning = true },
                        setVerified: { verified in Task { await model.setVerified(verified) } }
                    )
                }
            }
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.profileDetailsScreen)
            // The alert waits for the sheet to go: SwiftUI drops one presented while another is dismissing.
            .sheet(isPresented: $scanning, onDismiss: revealOutcome) {
                CodeScannerSheet(camera: camera) { text in
                    Task {
                        pending = await model.scanned(text)
                        scanning = false
                    }
                }
            }
            .alert(outcome.map { Copy.Profile.scanOutcome($0, name: state.title) } ?? "", isPresented: showsOutcome) {
                Button(Copy.Common.done, role: .cancel) { outcome = nil }
            }
            .fullScreenCover(isPresented: $viewing) {
                if let photo = state.face.photo {
                    PhotoViewer(photo: photo, title: state.title)
                }
            }
        }

        private var showsOutcome: Binding<Bool> {
            Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
        }

        /// The scan's result, once its sheet has gone.
        private func revealOutcome() {
            outcome = pending
            pending = nil
        }
    }

    /// Their face, their name, whether they are in range, and what they say about themselves. A photo opens full
    /// screen.
    private struct PeerHeader: View {
        let state: PeerProfileState
        let viewPhoto: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Layout.tight) {
                HeaderFace(face: state.face, viewPhoto: viewPhoto)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Layout.small)
                Text(state.title)
                    .font(.title2.bold())
                Label(
                    state.isLinked ? Copy.Profile.inRange : Copy.Profile.outOfRange,
                    systemImage: state.isLinked ? "dot.radiowaves.left.and.right" : "circle.dashed"
                )
                .font(.subheadline)
                .foregroundStyle(state.isLinked ? Palette.positive : Palette.secondaryText)
                .accessibilityIdentifier(AccessibilityID.profileDetailsPresence)
                if !state.status.isEmpty {
                    Text(state.status)
                }
                if state.openToChat {
                    Label(Copy.Profile.openToChat, systemImage: "bubble.left.and.bubble.right")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    /// A profile's face, which opens their photo full screen when they have one.
    private struct HeaderFace: View {
        let face: Face
        let viewPhoto: () -> Void

        var body: some View {
            if face.photo != nil {
                Button(action: viewPhoto) {
                    AvatarView(face: face, size: Layout.faceProfile)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Profile.viewPhoto)
                .accessibilityIdentifier(AccessibilityID.profileDetailsPhoto)
            } else {
                AvatarView(face: face, size: Layout.faceProfile)
            }
        }
    }

    /// A node id, small, monospaced and selectable.
    internal struct NodeIdRow: View {
        let nodeId: String

        var body: some View {
            LabeledContent(Copy.Profile.nodeIdLabel) {
                Text(nodeId)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Palette.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    /// The safety number both phones should show, our code for them to scan, the way to scan theirs, and the user's
    /// verdict.
    private struct EncryptionSection: View {
        let state: PeerProfileState
        let scan: () -> Void
        let setVerified: (Bool) -> Void
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            Section {
                Label(
                    state.isVerified ? Copy.Profile.verified : Copy.Profile.notVerified,
                    systemImage: state.isVerified ? "checkmark.seal.fill" : "seal"
                )
                .foregroundStyle(state.isVerified ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.secondaryText))
                .accessibilityIdentifier(AccessibilityID.profileDetailsVerified)
                if let number = state.safetyNumber {
                    SafetyNumberView(lines: number, name: state.title)
                    OwnCodeView(code: state.ownCode, name: state.title)
                    Button(action: scan) {
                        // At the accessibility sizes the glyph left the words too little room, as on Message.
                        if typeSize.isAccessibilitySize {
                            Text(Copy.Profile.scan)
                        } else {
                            Label(Copy.Profile.scan, systemImage: "qrcode.viewfinder")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.profileDetailsScan)
                    Button(state.isVerified ? Copy.Profile.clearVerification : Copy.Profile.markVerified) {
                        setVerified(!state.isVerified)
                    }
                } else {
                    Text(Copy.Profile.noKey)
                        .foregroundStyle(Palette.secondaryText)
                }
            } header: {
                SectionNote(Copy.Profile.encryptionSection)
            }
        }
    }

    /// Our own verify code, for the other person to scan, with whom it is for.
    private struct OwnCodeView: View {
        let code: String
        let name: String

        var body: some View {
            VStack(spacing: Layout.small) {
                QRCodeView(text: code)
                Text(Copy.Profile.codeCaption(name))
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.small)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier(AccessibilityID.profileDetailsCode)
        }
    }

    private struct SafetyNumberView: View {
        let lines: [String]
        let name: String

        var body: some View {
            VStack(alignment: .leading, spacing: Layout.small) {
                Text(Copy.Profile.safetyNumber)
                    .font(.headline)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.title3.monospaced())
                }
                Text(Copy.Profile.safetyNumberCaption(name))
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .textSelection(.enabled)
        }
    }
#endif
