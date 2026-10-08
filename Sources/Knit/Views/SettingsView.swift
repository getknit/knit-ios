#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Settings: the profile row, Stop and Start, notifications, the people blocked, About and Diagnostics (MVP item 10),
    /// each row after a glyph, as Signal lists its settings (ADR 2026-10.5waw).
    internal struct SettingsView: View {
        @State private var model: SettingsModel
        @Environment(\.scenePhase) private var scenePhase
        @Environment(PhotoScreening.self) private var screening: PhotoScreening?

        init(session: AppSession, permission: any NotificationPermission, about: AboutInfo) {
            _model = State(initialValue: SettingsModel(session: session, permission: permission, about: about))
        }

        var body: some View {
            Form {
                Section {
                    NavigationLink(value: Route.profile) {
                        ProfileRow(title: model.profileTitle, face: model.profileFace)
                    }
                    .accessibilityIdentifier(AccessibilityID.settingsProfileRow)
                }
                MeshSection(isRunning: model.isRunning) { Task { await model.toggleMesh() } }
                NotificationSection(authorization: model.notifications) { Task { await model.requestNotifications() } }
                Section {
                    NavigationLink(value: Route.blocked) {
                        RowLabel(Copy.Block.listTitle, symbol: "hand.raised")
                    }
                    .accessibilityIdentifier(AccessibilityID.settingsBlocked)
                }
                if let screening {
                    ContentFilterSection(screening: screening)
                }
                AboutSection()
            }
            .navigationTitle(Copy.Settings.title)
            .task { await model.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await model.refresh() }
                }
            }
            .accessibilityIdentifier(AccessibilityID.settingsScreen)
        }
    }

    /// Whether notifications are on, and what they say.
    private struct NotificationSection: View {
        let authorization: NotificationAuthorization
        let ask: () -> Void

        var body: some View {
            Section {
                LabeledContent {
                    NotificationControl(authorization: authorization, ask: ask)
                } label: {
                    RowLabel(Copy.Settings.notifications, symbol: "bell")
                }
            } footer: {
                SectionNote(Copy.Settings.notificationsFooter)
            }
        }
    }

    /// About and Diagnostics.
    private struct AboutSection: View {
        var body: some View {
            Section {
                NavigationLink(value: Route.about) {
                    RowLabel(Copy.Settings.about, symbol: "info.circle")
                }
                .accessibilityIdentifier(AccessibilityID.settingsAbout)
                NavigationLink(value: Route.diagnostics) {
                    RowLabel(Copy.Settings.diagnostics, symbol: "stethoscope")
                }
                .accessibilityIdentifier(AccessibilityID.settingsDiagnostics)
            }
        }
    }

    /// Content filtering, what it does in a line, and the rest behind an info button (ADR 2026-10.rpmq).
    private struct ContentFilterSection: View {
        @Bindable var screening: PhotoScreening
        @State private var showsInfo = false
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            Section {
                // The info button sits in the toggle's label, so the row keeps a toggle row's height; a tap on the label
                // never flips the switch, so the button keeps its own. VoiceOver reads the row as the one switch, so
                // the sheet is also among its actions.
                Toggle(isOn: $screening.filtersContent) {
                    // A Label on the outside, as RowLabel draws it, so the words keep the column every other row's do.
                    let title = HStack(spacing: Layout.tight) {
                        Text(Copy.Moderation.filter)
                        InfoButton(label: Copy.Moderation.filterInfo) { showsInfo = true }
                    }
                    if typeSize.isAccessibilitySize {
                        title
                    } else {
                        Label {
                            title
                        } icon: {
                            Image(systemName: "eye.slash")
                        }
                    }
                }
                .accessibilityAction(named: Copy.Moderation.filterInfo) { showsInfo = true }
                .accessibilityIdentifier(AccessibilityID.settingsContentFiltering)
            } footer: {
                SectionNote(Copy.Moderation.filterFooter)
            }
            .infoSheet(
                isPresented: $showsInfo,
                symbol: "eye.slash",
                title: Copy.Moderation.filter,
                points: [
                    InfoPoint(symbol: "iphone", text: Copy.Moderation.filterOnDevice),
                    InfoPoint(symbol: "person.crop.circle", text: Copy.Moderation.filterProfilePhoto),
                    InfoPoint(symbol: "exclamationmark.triangle", text: Copy.Moderation.filterMistakes),
                ],
                identifier: nil
            )
        }
    }

    /// Our face and our name, the way into our profile.
    private struct ProfileRow: View {
        let title: String
        let face: Face
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            HStack(spacing: Layout.medium) {
                // At the accessibility sizes the face would squeeze the name, which says who.
                if !typeSize.isAccessibilitySize {
                    AvatarView(face: face, size: Layout.faceSettings)
                }
                Text(title)
                    .font(.headline)
            }
        }
    }

    /// Stop and Start, what stopping costs in a line, and the rest, with the radio's one boundary, behind an info button.
    private struct MeshSection: View {
        let isRunning: Bool
        let toggle: () -> Void
        @State private var showsInfo = false

        var body: some View {
            Section {
                HStack(spacing: Layout.tight) {
                    // Borderless beside the info button, so each takes its own taps; the label fills the row up to it.
                    Button(action: toggle) {
                        RowLabel(isRunning ? Copy.Settings.stop : Copy.Settings.start, symbol: isRunning ? "pause.circle" : "play.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(AccessibilityID.settingsMesh)
                    InfoButton(label: Copy.Settings.meshInfo) { showsInfo = true }
                }
            } header: {
                SectionNote(Copy.Settings.meshSection)
            } footer: {
                SectionNote(Copy.Settings.stopFooter)
            }
            .infoSheet(
                isPresented: $showsInfo,
                symbol: "point.3.connected.trianglepath.dotted",
                title: Copy.Settings.meshInfo,
                points: [InfoPoint(symbol: "pause.circle", text: Copy.Settings.stopDetail)] + Copy.Status.boundaryPoints,
                identifier: nil
            )
        }
    }

    /// Whether notifications are on, a way to ask, or the way to Settings after a refusal.
    private struct NotificationControl: View {
        let authorization: NotificationAuthorization
        let ask: () -> Void

        var body: some View {
            switch authorization {
            case .allowed:
                // In the palette's gray: `LabeledContent`'s own reads about 3.4:1 on a grouped cell.
                Text(Copy.Settings.notificationsOn)
                    .foregroundStyle(Palette.secondaryText)
            case .notDetermined:
                Button(Copy.Settings.notificationsAsk, action: ask)
            case .denied:
                OpenSettingsButton()
            }
        }
    }
#endif
