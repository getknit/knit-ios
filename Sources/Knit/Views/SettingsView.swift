#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Settings: the profile row, Stop and Start, notifications, the people blocked, About and Diagnostics (MVP item 10).
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
                Section {
                    LabeledContent(Copy.Settings.notifications) {
                        NotificationControl(authorization: model.notifications) { Task { await model.requestNotifications() } }
                    }
                } footer: {
                    SectionNote(Copy.Settings.notificationsFooter)
                }
                Section {
                    NavigationLink(Copy.Block.listTitle, value: Route.blocked)
                        .accessibilityIdentifier(AccessibilityID.settingsBlocked)
                }
                if let screening {
                    ContentFilterSection(screening: screening)
                }
                Section {
                    NavigationLink(Copy.Settings.about, value: Route.about)
                        .accessibilityIdentifier(AccessibilityID.settingsAbout)
                    NavigationLink(Copy.Settings.diagnostics, value: Route.diagnostics)
                        .accessibilityIdentifier(AccessibilityID.settingsDiagnostics)
                }
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

    /// Content filtering, and what it does (ADR 2026-10.rpmq).
    private struct ContentFilterSection: View {
        @Bindable var screening: PhotoScreening

        var body: some View {
            Section {
                Toggle(Copy.Moderation.filter, isOn: $screening.filtersContent)
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
                Button(isRunning ? Copy.Settings.stop : Copy.Settings.start, action: toggle)
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
                Text(Copy.Settings.notificationsOn)
            case .notDetermined:
                Button(Copy.Settings.notificationsAsk, action: ask)
            case .denied:
                OpenSettingsButton()
            }
        }
    }
#endif
