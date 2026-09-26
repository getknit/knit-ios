#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The first run: welcome, a name, then Bluetooth and notifications (MVP item 1).
    internal struct OnboardingView: View {
        let model: OnboardingModel

        var body: some View {
            NavigationStack {
                Group {
                    switch model.step {
                    case .welcome:
                        WelcomePage(model: model)
                    case .name:
                        NamePage(model: model)
                    case .permissions:
                        PermissionsPage(model: model)
                    }
                }
                .toolbar {
                    if let progress = model.progress {
                        ToolbarItem(placement: .principal) {
                            Text(progress)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.onboardingScreen)
        }
    }

    /// A page's one button, at the bottom where a thumb finds it.
    private struct PageButton: View {
        let title: String
        let identifier: String
        let action: () -> Void

        var body: some View {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding()
                .accessibilityIdentifier(identifier)
        }
    }

    private struct WelcomePage: View {
        let model: OnboardingModel

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.page) {
                    VStack(alignment: .leading, spacing: Layout.small) {
                        Text(Copy.Onboarding.welcomeTitle)
                            .font(.largeTitle.bold())
                        Text(Copy.Onboarding.welcomeTagline)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Point(symbol: "antenna.radiowaves.left.and.right", title: Copy.Onboarding.hopTitle, detail: Copy.Onboarding.hopBody)
                    Point(symbol: "lock.fill", title: Copy.Onboarding.sealedTitle, detail: Copy.Onboarding.sealedBody)
                    Point(symbol: "person.3.fill", title: Copy.Onboarding.carryTitle, detail: Copy.Onboarding.carryBody)
                }
                .padding(Layout.page)
            }
            .safeAreaInset(edge: .bottom) {
                PageButton(title: Copy.Onboarding.getStarted, identifier: AccessibilityID.onboardingNext, action: model.next)
            }
            .accessibilityIdentifier(AccessibilityID.onboardingWelcome)
        }
    }

    /// One of the welcome page's three points.
    private struct Point: View {
        let symbol: String
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: Layout.large) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: Layout.glyphColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Layout.tight) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private struct NamePage: View {
        @Bindable var model: OnboardingModel
        @FocusState private var focused: Bool

        var body: some View {
            Form {
                Section {
                    TextField(model.alias, text: $model.name)
                        .textContentType(.nickname)
                        .submitLabel(.continue)
                        .focused($focused)
                        .onSubmit(model.next)
                        .accessibilityIdentifier(AccessibilityID.onboardingName)
                } header: {
                    PageHeading(text: Copy.Onboarding.nameTitle)
                } footer: {
                    Text(Copy.Onboarding.nameBody(alias: model.alias))
                }
            }
            .onAppear { focused = true }
            .safeAreaInset(edge: .bottom) {
                PageButton(
                    title: model.skipsName ? Copy.Onboarding.nameSkip : Copy.Onboarding.nameNext,
                    identifier: AccessibilityID.onboardingNext,
                    action: model.next
                )
            }
            .accessibilityIdentifier(AccessibilityID.onboardingNamePage)
        }
    }

    /// A page's heading, set as the first section's header.
    private struct PageHeading: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    private struct PermissionsPage: View {
        let model: OnboardingModel
        @Environment(\.scenePhase) private var scenePhase

        var body: some View {
            Form {
                Section {
                    PermissionRow(
                        title: Copy.Onboarding.bluetoothTitle,
                        detail: Copy.Onboarding.bluetoothBody,
                        optional: false,
                        state: PermissionRow.State(model.bluetooth)
                    ) {
                        Task { await model.allowBluetooth() }
                    }
                    PermissionRow(
                        title: Copy.Onboarding.notificationsTitle,
                        detail: Copy.Onboarding.notificationsBody,
                        optional: true,
                        state: PermissionRow.State(model.notifications)
                    ) {
                        Task { await model.allowNotifications() }
                    }
                } header: {
                    PageHeading(text: Copy.Onboarding.permissionsTitle)
                } footer: {
                    BluetoothFooter(grant: model.bluetooth)
                }
            }
            .task { await model.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await model.refresh() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PageButton(title: Copy.Onboarding.start, identifier: AccessibilityID.onboardingStart) {
                    Task { await model.finish() }
                }
            }
            .accessibilityIdentifier(AccessibilityID.onboardingPermissions)
        }
    }

    /// What a refused or missing Bluetooth means here, and the way to Settings when it can change there.
    private struct BluetoothFooter: View {
        let grant: BluetoothGrant

        var body: some View {
            switch grant {
            case .denied:
                VStack(alignment: .leading) {
                    Text(Copy.Onboarding.bluetoothDenied)
                    OpenSettingsButton()
                }
            case .unsupported:
                Text(Copy.Onboarding.unsupported)
            case .notAsked, .asking, .allowed:
                EmptyView()
            }
        }
    }

    /// A permission, what it does, and its button or its outcome.
    private struct PermissionRow: View {
        enum State {
            case ask
            case waiting
            case allowed
            case refused

            init(_ grant: BluetoothGrant) {
                switch grant {
                case .notAsked:
                    self = .ask
                case .asking:
                    self = .waiting
                case .allowed:
                    self = .allowed
                case .denied, .unsupported:
                    self = .refused
                }
            }

            init(_ authorization: NotificationAuthorization) {
                switch authorization {
                case .notDetermined:
                    self = .ask
                case .allowed:
                    self = .allowed
                case .denied:
                    self = .refused
                }
            }
        }

        let title: String
        let detail: String
        let optional: Bool
        let state: State
        let allow: () -> Void

        var body: some View {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Layout.tight) {
                    HStack {
                        Text(title)
                            .font(.headline)
                        if optional {
                            Text(Copy.Onboarding.optional)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                outcome
            }
            .padding(.vertical, Layout.tight)
        }

        @ViewBuilder private var outcome: some View {
            switch state {
            case .ask:
                Button(Copy.Onboarding.allow, action: allow)
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Copy.Onboarding.allowLabel(title))
            case .waiting:
                ProgressView()
            case .allowed:
                Label(Copy.Onboarding.allowed, systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            case .refused:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
#endif
