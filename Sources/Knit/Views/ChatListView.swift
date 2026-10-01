#if os(iOS)
    import KnitAppCore
    import KnitStore
    import SwiftUI

    /// The chat list: the status line, the first-run card, the room, the DMs and the requests entry.
    internal struct ChatListView: View {
        @State private var model: ChatListModel

        init(session: AppSession) {
            _model = State(initialValue: ChatListModel(session: session))
        }

        var body: some View {
            let state = model.state
            List {
                Section {
                    StatusLine(status: model.status) { Task { await model.start() } }
                        .accessibilityIdentifier(AccessibilityID.chatListStatus)
                }
                if state.showsGettingStarted {
                    Section {
                        GettingStartedCard()
                    }
                }
                Section {
                    ForEach(state.rows) { row in
                        NavigationLink(value: Route.chat(row.id)) {
                            ChatRowView(row: row)
                        }
                        .accessibilityIdentifier(AccessibilityID.chatRow(row.id))
                    }
                    if state.requestCount > 0 {
                        RequestsEntry(count: state.requestCount)
                    }
                }
            }
            .navigationTitle(Copy.ChatList.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) {
                        Label(Copy.ChatList.settings, systemImage: "gearshape")
                    }
                    .accessibilityIdentifier(AccessibilityID.chatListSettings)
                }
            }
        }
    }

    /// The way into the message requests, with how many wait.
    private struct RequestsEntry: View {
        let count: Int

        var body: some View {
            NavigationLink(value: Route.requests) {
                LabeledContent(Copy.ChatList.requests) {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .accessibilityValue(Copy.ChatList.requestCount(count))
            .accessibilityIdentifier(AccessibilityID.chatListRequests)
        }
    }

    /// How many peers are linked, or why none can be, with the one control that helps.
    private struct StatusLine: View {
        let status: ConnectionStatus
        let start: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Layout.small) {
                Label {
                    Text(status.line)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(status.isWarning ? Palette.warning : Palette.accent)
                }
                .accessibilityIdentifier(AccessibilityID.chatListStatus(status.accessibilityState))
                if status.offersStart {
                    Button(Copy.Status.start, action: start)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(AccessibilityID.chatListStatusStart)
                }
                if status.offersSettings {
                    OpenSettingsButton()
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(AccessibilityID.chatListStatusSettings)
                }
                if case .linked = status {
                    Text(Copy.Status.boundary)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .accessibilityElement(children: .contain)
        }

        private var symbol: String {
            switch status {
            case .linked(let count):
                count > 0 ? "dot.radiowaves.left.and.right" : "magnifyingglass"
            case .starting:
                "hourglass"
            case .stopped:
                "pause.circle"
            case .bluetoothOff, .notAllowed, .unsupported:
                "exclamationmark.triangle"
            }
        }
    }

    /// The button that opens Knit's page in the Settings app, where a refused permission can change.
    internal struct OpenSettingsButton: View {
        @Environment(\.openURL) private var openURL

        var body: some View {
            Button(Copy.Common.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }
    }

    private struct GettingStartedCard: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Layout.small) {
                Text(Copy.ChatList.gettingStartedTitle)
                    .font(.headline)
                Text(Copy.ChatList.gettingStartedBody)
                    .foregroundStyle(Palette.secondaryText)
                NavigationLink(value: Route.chat(Conversations.nearby)) {
                    Text(Copy.ChatList.gettingStartedAction)
                }
                .prominentButton()
            }
            .padding(.vertical, Layout.tight)
        }
    }

    /// One thread: one VoiceOver element that reads the title, the preview, the time and the tick.
    private struct ChatRowView: View {
        let row: ChatRow
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            HStack(spacing: Layout.medium) {
                // At the accessibility sizes the glyph would take a third of the row from the title, which says the same.
                if !typeSize.isAccessibilitySize {
                    Image(systemName: row.isRoom ? "person.3.fill" : "person.crop.circle.fill")
                        .font(.title)
                        .foregroundStyle(row.isRoom ? Palette.accent : Palette.secondaryText)
                        .frame(width: Layout.glyphColumn)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Layout.hairline) {
                    RowTitle(row: row)
                    HStack(spacing: Layout.tight) {
                        if let status = row.lastStatus {
                            DeliveryTick(status: status)
                        }
                        Text(row.preview ?? Copy.ChatList.noMessages)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(Layout.previewLines)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// A row's first line: the title, its badges, and when the newest message was sent.
    private struct RowTitle: View {
        let row: ChatRow
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            // One line while it fits; at the accessibility sizes the time goes under a title that may wrap.
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
            layout {
                Text(row.title)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                if row.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Copy.Profile.verified)
                }
                if row.isLinked {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Palette.positive)
                        .accessibilityLabel(Copy.ChatList.inRange)
                }
                if !typeSize.isAccessibilitySize {
                    Spacer()
                }
                if let at = row.lastMessageAt {
                    Text(Date(milliseconds: at), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }

    /// The tick on one of our messages: a clock, one check, or a filled check. The glyph never carries the meaning
    /// alone; its label is the status's words.
    internal struct DeliveryTick: View {
        let status: DeliveryStatus

        var body: some View {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(status == .delivered ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.secondaryText))
                .accessibilityLabel(status.label)
        }

        private var symbol: String {
            switch status {
            case .waitingForKey, .waitingForMembersKeys:
                "clock"
            case .sent:
                "checkmark"
            case .delivered:
                "checkmark.circle.fill"
            }
        }
    }

    extension Date {
        private static let millisecondsPerSecond = 1000.0

        /// A mesh timestamp, in milliseconds since the epoch.
        init(milliseconds: Int64) {
            self.init(timeIntervalSince1970: Double(milliseconds) / Self.millisecondsPerSecond)
        }
    }
#endif
