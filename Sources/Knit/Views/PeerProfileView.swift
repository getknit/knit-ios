#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// Another person's profile: who they are, their safety number, and Message (MVP items 3 and 5).
    internal struct PeerProfileView: View {
        @State private var model: PeerProfileModel

        init(nodeId: NodeId, session: AppSession) {
            _model = State(initialValue: PeerProfileModel(nodeId: nodeId, session: session))
        }

        var body: some View {
            let state = model.state
            Form {
                Section {
                    PeerHeader(state: state)
                    if !model.isSelf {
                        NavigationLink(value: Route.chat(state.conversationId)) {
                            Label(Copy.Profile.message, systemImage: "message")
                        }
                        .accessibilityIdentifier(AccessibilityID.profileDetailsMessage)
                    }
                }
                Section {
                    LabeledContent(Copy.Profile.aliasLabel, value: state.alias)
                        .accessibilityIdentifier(AccessibilityID.profileDetailsAlias)
                    NodeIdRow(nodeId: state.nodeId.string)
                        .accessibilityIdentifier(AccessibilityID.profileDetailsNodeId)
                }
                if !model.isSelf {
                    EncryptionSection(state: state) { verified in
                        Task { await model.setVerified(verified) }
                    }
                }
            }
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.profileDetailsScreen)
        }
    }

    /// The name, whether they are in range, and what they say about themselves.
    private struct PeerHeader: View {
        let state: PeerProfileState

        var body: some View {
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text(state.title)
                    .font(.title2.bold())
                Label(
                    state.isLinked ? Copy.Profile.inRange : Copy.Profile.outOfRange,
                    systemImage: state.isLinked ? "dot.radiowaves.left.and.right" : "circle.dashed"
                )
                .font(.subheadline)
                .foregroundStyle(state.isLinked ? .green : .secondary)
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

    /// A node id, small, monospaced and selectable.
    internal struct NodeIdRow: View {
        let nodeId: String

        var body: some View {
            LabeledContent(Copy.Profile.nodeIdLabel) {
                Text(nodeId)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    /// The safety number both phones should show, and the user's verdict on it.
    private struct EncryptionSection: View {
        let state: PeerProfileState
        let setVerified: (Bool) -> Void

        var body: some View {
            Section {
                Label(
                    state.isVerified ? Copy.Profile.verified : Copy.Profile.notVerified,
                    systemImage: state.isVerified ? "checkmark.seal.fill" : "seal"
                )
                .foregroundStyle(state.isVerified ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityIdentifier(AccessibilityID.profileDetailsVerified)
                if let number = state.safetyNumber {
                    SafetyNumberView(lines: number, name: state.title)
                    Button(state.isVerified ? Copy.Profile.clearVerification : Copy.Profile.markVerified) {
                        setVerified(!state.isVerified)
                    }
                } else {
                    Text(Copy.Profile.noKey)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(Copy.Profile.encryptionSection)
            }
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
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .textSelection(.enabled)
        }
    }
#endif
