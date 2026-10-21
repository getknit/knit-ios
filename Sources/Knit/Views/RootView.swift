#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    /// Where the app goes from the chat list.
    internal enum Route: Hashable, Sendable {
        case chat(String)
        case requests
        case groupInfo(String)
        case peer(NodeId)
        /// Add contact, previewing a link that was opened, if one was.
        case addContact(String?)
        case profile
        case settings
        case blocked
        case about
        case support
        case terms
        case diagnostics
    }

    /// Opens a screen on the app's navigation stack. A thread's rows are drawn in a UIKit collection view, outside the
    /// stack's SwiftUI, where a `NavigationLink` to a value finds no destination (ADR 2026-10.5waw).
    internal struct OpenRoute: Sendable {
        let open: @MainActor @Sendable (Route) -> Void

        @MainActor
        func callAsFunction(_ route: Route) {
            open(route)
        }
    }

    extension EnvironmentValues {
        /// Opens a screen on the app's navigation stack; nothing outside it.
        @Entry var openRoute = OpenRoute { _ in
            // Outside the stack, nothing opens.
        }
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

    /// Onboarding until it is done, then the app, once the user has agreed to the current terms: an install that onboarded
    /// before them, or before they changed, sees the terms page alone first (ADR 2026-10.cgm3).
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
            Group {
                if onboarding.isFinished, onboarding.acceptedTerms {
                    MainView(environment: environment, launch: launch)
                } else if onboarding.isFinished {
                    NavigationStack {
                        TermsPage(model: onboarding)
                    }
                } else {
                    OnboardingView(model: onboarding)
                }
            }
            .environment(environment.photos)
            .environment(environment.screening)
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
            let stack = $path
            NavigationStack(path: $path) {
                ChatListView(session: environment.session) { composing = true }
                    .navigationDestination(for: Route.self, destination: destination)
            }
            .environment(\.openRoute, OpenRoute { stack.wrappedValue.append($0) })
            .sheet(isPresented: $composing) {
                // The sheet goes and the thread is under it, as Android drops its picker from the back stack.
                NewMessageView(session: environment.session) { conversationId in
                    composing = false
                    path = [.chat(conversationId)]
                } addContact: {
                    composing = false
                    path.append(.addContact(nil))
                }
            }
            // A contact link opened from outside Knit, once onboarding is done, as Android's inbox waits for it.
            .onChange(of: launch.requestedContactLink, initial: true) { _, link in
                if let link {
                    composing = false
                    path = [.addContact(link)]
                    launch.requestedContactLink = nil
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
                ChatView(
                    conversationId: conversationId,
                    session: environment.session,
                    codec: environment.codec,
                    screening: environment.screening,
                    demoPhoto: environment.demoPhoto,
                    shares: environment.shares
                )
            case .requests:
                RequestsView(session: environment.session)
            case .groupInfo(let groupId):
                // Leaving closes the group's screens and comes back to the chat list.
                GroupInfoView(groupId: groupId, session: environment.session) { path = [] }
            case .peer(let nodeId):
                PeerProfileView(nodeId: nodeId, session: environment.session, camera: environment.camera)
            case .addContact(let link):
                // The person added replaces Add contact, as Android pops it for their profile.
                AddContactView(session: environment.session, camera: environment.camera, link: link) { nodeId in
                    path.removeLast()
                    path.append(.peer(nodeId))
                }
            case .profile:
                OwnProfileView(
                    session: environment.session,
                    codec: environment.codec,
                    screening: environment.screening,
                    demoPhoto: environment.demoPhoto
                )
            case .settings:
                SettingsView(session: environment.session, permission: environment.notifier, about: environment.about)
            case .blocked:
                BlockedView(session: environment.session)
            case .about:
                AboutView(about: environment.about)
            case .support:
                SupportView()
            case .terms:
                TermsView()
            case .diagnostics:
                DiagnosticsView(session: environment.session, replaceIdentity: environment.replaceIdentity)
            }
        }
    }
#endif
