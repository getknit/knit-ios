#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// Where the app goes from the chat list.
    internal enum Route: Hashable {
        case chat(String)
        case requests
        case peer(NodeId)
        case profile
        case settings
        case about
        case diagnostics
    }

    /// The launch's stage: waiting for the first unlock, onboarding, or the app.
    internal struct RootView: View {
        let launch: Launch

        var body: some View {
            switch launch.stage {
            case .waiting(let reason):
                WaitingView(reason: reason, retry: launch.begin)
            case .ready(let environment):
                ReadyView(environment: environment, launch: launch)
            }
        }
    }

    /// Shown until the keys can be read: before the first unlock since a reboot.
    private struct WaitingView: View {
        let reason: String
        let retry: () -> Void

        var body: some View {
            VStack(spacing: Layout.large) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Copy.Launch.waitingTitle)
                    .font(.title2.bold())
                Text(Copy.Launch.waitingBody)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if !reason.isEmpty {
                    Text(verbatim: reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Button(Copy.Launch.retry, action: retry)
                    .buttonStyle(.borderedProminent)
            }
            .padding(Layout.spacious)
        }
    }

    /// Onboarding until it is done, then the app.
    private struct ReadyView: View {
        let environment: AppEnvironment
        let launch: Launch
        @State private var onboarding: OnboardingModel

        init(environment: AppEnvironment, launch: Launch) {
            self.environment = environment
            self.launch = launch
            _onboarding = State(
                initialValue: OnboardingModel(
                    session: environment.session, preferences: environment.preferences, permission: environment.notifier)
            )
        }

        var body: some View {
            if onboarding.isFinished {
                MainView(environment: environment, launch: launch)
            } else {
                OnboardingView(model: onboarding)
            }
        }
    }

    /// The chat list and everything reached from it.
    private struct MainView: View {
        let environment: AppEnvironment
        let launch: Launch
        @State private var path: [Route] = []

        var body: some View {
            NavigationStack(path: $path) {
                ChatListView(session: environment.session)
                    .navigationDestination(for: Route.self, destination: destination)
            }
            .onChange(of: launch.requestedConversation, initial: true) { _, conversation in
                if let conversation {
                    path = [.chat(conversation)]
                    launch.requestedConversation = nil
                }
            }
            .onChange(of: launch.requestedRequests, initial: true) { _, requested in
                if requested {
                    path = [.requests]
                    launch.requestedRequests = false
                }
            }
        }

        @ViewBuilder
        private func destination(_ route: Route) -> some View {
            switch route {
            case .chat(let conversationId):
                ChatView(conversationId: conversationId, session: environment.session)
            case .requests:
                RequestsView(session: environment.session)
            case .peer(let nodeId):
                PeerProfileView(nodeId: nodeId, session: environment.session)
            case .profile:
                OwnProfileView(session: environment.session)
            case .settings:
                SettingsView(session: environment.session, permission: environment.notifier, about: environment.about)
            case .about:
                AboutView(about: environment.about)
            case .diagnostics:
                DiagnosticsView(session: environment.session, replaceIdentity: environment.replaceIdentity)
            }
        }
    }
#endif
