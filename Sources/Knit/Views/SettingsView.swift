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

    /// Content filtering, and what it does (ADR 2026-10.rpmq).
    private struct ContentFilterSection: View {
        @Bindable var screening: PhotoScreening

        var body: some View {
            Section {
                Toggle(isOn: $screening.filtersContent) {
                    RowLabel(Copy.Moderation.filter, symbol: "eye.slash")
                }
                .accessibilityIdentifier(AccessibilityID.settingsContentFiltering)
            } footer: {
                SectionNote(Copy.Moderation.filterFooter)
            }
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

    /// Stop and Start, what stopping does, and the radio's one boundary.
    private struct MeshSection: View {
        let isRunning: Bool
        let toggle: () -> Void

        var body: some View {
            Section {
                Button(action: toggle) {
                    RowLabel(isRunning ? Copy.Settings.stop : Copy.Settings.start, symbol: isRunning ? "pause.circle" : "play.circle")
                }
                .accessibilityIdentifier(AccessibilityID.settingsMesh)
            } header: {
                SectionNote(Copy.Settings.meshSection)
            } footer: {
                VStack(alignment: .leading, spacing: Layout.small) {
                    Text(Copy.Settings.stopFooter)
                    Text(Copy.Status.boundary)
                }
                .foregroundStyle(Palette.secondaryText)
            }
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
