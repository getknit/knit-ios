#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Settings: the profile row, Stop and Start, notifications, About and Diagnostics (MVP item 10).
    internal struct SettingsView: View {
        @State private var model: SettingsModel
        @Environment(\.scenePhase) private var scenePhase

        init(session: AppSession, permission: any NotificationPermission, about: AboutInfo) {
            _model = State(initialValue: SettingsModel(session: session, permission: permission, about: about))
        }

        var body: some View {
            Form {
                Section {
                    NavigationLink(value: Route.profile) {
                        Label(model.profileTitle, systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier(AccessibilityID.settingsProfileRow)
                }
                MeshSection(isRunning: model.isRunning) { Task { await model.toggleMesh() } }
                Section {
                    LabeledContent(Copy.Settings.notifications) {
                        NotificationControl(authorization: model.notifications) { Task { await model.requestNotifications() } }
                    }
                } footer: {
                    Text(Copy.Settings.notificationsFooter)
                }
                Section {
                    NavigationLink(Copy.Settings.about, value: Route.about)
                    NavigationLink(Copy.Settings.diagnostics, value: Route.diagnostics)
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

    /// Stop and Start, what stopping does, and the radio's one boundary.
    private struct MeshSection: View {
        let isRunning: Bool
        let toggle: () -> Void

        var body: some View {
            Section {
                Button(isRunning ? Copy.Settings.stop : Copy.Settings.start, action: toggle)
            } header: {
                Text(Copy.Settings.meshSection)
            } footer: {
                VStack(alignment: .leading, spacing: Layout.small) {
                    Text(Copy.Settings.stopFooter)
                    Text(Copy.Status.boundary)
                }
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
