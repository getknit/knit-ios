#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// Where the app goes from the chat list.
    internal enum Route: Hashable {
        case chat(String)
        case requests
        case groupInfo(String)
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
                WaitingView(reason: reason) { launch.begin(.retry) }
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
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityHidden(true)
                Text(Copy.Launch.waitingTitle)
                    .font(.title2.bold())
                Text(Copy.Launch.waitingBody)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.secondaryText)
                if !reason.isEmpty {
                    Text(verbatim: reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.secondaryText)
                        .textSelection(.enabled)
                }
                Button(Copy.Launch.retry, action: retry)
                    .prominentButton()
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
        /// Whether New message is up.
        @State private var composing = false

        var body: some View {
            NavigationStack(path: $path) {
                ChatListView(session: environment.session) { composing = true }
                    .navigationDestination(for: Route.self, destination: destination)
            }
            .sheet(isPresented: $composing) {
                // The sheet goes and the thread is under it, as Android drops its picker from the back stack.
                NewMessageView(session: environment.session) { conversationId in
                    composing = false
                    path = [.chat(conversationId)]
                }
            }
            // A notification's thread would open under the sheet, so the sheet goes first.
            .onChange(of: launch.requestedConversation, initial: true) { _, conversation in
                if let conversation {
                    composing = false
                    path = [.chat(conversation)]
                    launch.requestedConversation = nil
                }
            }
            .onChange(of: launch.requestedRequests, initial: true) { _, requested in
                if requested {
                    composing = false
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
            case .groupInfo(let groupId):
                // Leaving closes the group's screens and comes back to the chat list.
                GroupInfoView(groupId: groupId, session: environment.session) { path = [] }
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
