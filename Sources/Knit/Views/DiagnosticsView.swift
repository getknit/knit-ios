#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Diagnostics: the mesh as it is now, read every two seconds while on screen, and the debug build's test
    /// identities.
    internal struct DiagnosticsView: View {
        /// How often the screen reads the mesh again, in seconds.
        private static let refreshSeconds: Int64 = 2

        @State private var model: DiagnosticsModel

        init(session: AppSession, replaceIdentity: IdentityReplacer?) {
            _model = State(initialValue: DiagnosticsModel(session: session, replaceIdentity: replaceIdentity))
        }

        var body: some View {
            Form {
                Section(Copy.Diagnostics.thisDevice) {
                    LabeledContent(Copy.Profile.aliasLabel, value: model.alias)
                    NodeIdRow(nodeId: model.nodeId)
                    if let state = model.state {
                        LabeledContent(Copy.Diagnostics.bluetooth, value: state.radio)
                        LabeledContent(Copy.Diagnostics.mesh, value: state.isRunning ? Copy.Diagnostics.running : Copy.Diagnostics.stopped)
                    }
                }
                if let state = model.state {
                    PeerSection(title: Copy.Diagnostics.linked(state.linked.count), peers: state.linked, none: Copy.Diagnostics.noneLinked)
                    PeerSection(
                        title: Copy.Diagnostics.sighted(state.sighted.count), peers: state.sighted, none: Copy.Diagnostics.noneSighted)
                    if !state.known.isEmpty {
                        PeerSection(title: Copy.Diagnostics.known(state.known.count), peers: state.known, none: nil)
                    }
                    Section(Copy.Diagnostics.counters) {
                        ForEach(state.counters) { counter in
                            LabeledContent(counter.id) {
                                Text(counter.count, format: .number)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                if model.mintsIdentities {
                    TestIdentitySection(model: model)
                }
            }
            .navigationTitle(Copy.Diagnostics.title)
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(for: .seconds(Self.refreshSeconds))
                }
            }
            .accessibilityIdentifier(AccessibilityID.diagnosticsScreen)
        }
    }

    /// A list of peers, each opening its profile.
    private struct PeerSection: View {
        let title: String
        let peers: [DiagnosticsPeer]
        let none: String?

        var body: some View {
            Section(title) {
                if peers.isEmpty, let none {
                    Text(none)
                        .foregroundStyle(.secondary)
                }
                ForEach(peers) { peer in
                    NavigationLink(value: Route.peer(peer.id)) {
                        VStack(alignment: .leading, spacing: Layout.hairline) {
                            Text(peer.title)
                            Text(peer.detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if let clock = peer.clock {
                                Text(clock)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// Mints an identity above or below given node ids, for checking both dial orders (MVP item 2).
    private struct TestIdentitySection: View {
        let model: DiagnosticsModel
        @State private var above = ""
        @State private var below = ""

        var body: some View {
            Section {
                NodeIdField(prompt: Copy.TestIdentity.above, text: $above)
                NodeIdField(prompt: Copy.TestIdentity.below, text: $below)
                Button(Copy.TestIdentity.mint) {
                    Task { await model.mint(above: above, below: below) }
                }
                if let outcome = model.mintOutcome {
                    Text(outcome)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            } header: {
                Text(Copy.TestIdentity.title)
            } footer: {
                Text(Copy.TestIdentity.footer)
            }
        }
    }

    private struct NodeIdField: View {
        let prompt: String
        @Binding var text: String

        var body: some View {
            TextField(prompt, text: $text)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
#endif
