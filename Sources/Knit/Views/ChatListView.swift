#if os(iOS)
    import KnitAppCore
    import KnitStore
    import SwiftUI

    /// The chat list, laid out as Signal's (ADR 2026-10.5waw): our face at the top left, which opens Settings, and compose at
    /// the top right; then the status line, the first-run card, the room, the DMs and groups, and the requests entry.
    internal struct ChatListView: View {
        @State private var model: ChatListModel
        private let newMessage: () -> Void

        /// The list over `session`, whose compose button calls `newMessage`.
        init(session: AppSession, newMessage: @escaping () -> Void) {
            _model = State(initialValue: ChatListModel(session: session))
            self.newMessage = newMessage
        }

        var body: some View {
            let state = model.state
            List {
                StatusLine(status: model.status) { Task { await model.start() } }
                    .accessibilityIdentifier(AccessibilityID.chatListStatus)
                    .listRowSeparator(.hidden)
                if state.showsGettingStarted {
                    GettingStartedCard()
                        .listRowSeparator(.hidden)
                }
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
            .listStyle(.plain)
            .navigationTitle(Copy.ChatList.title)
            // Small, between the face and compose: the screen hardly needs naming, but VoiceOver and the back button
            // read the title.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SettingsButton(face: model.ownFace)
                }
                // Compose at the trailing edge, where Signal, Messages and Mail keep it.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: newMessage) {
                        Label(Copy.NewMessage.title, systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier(AccessibilityID.chatListNewMessage)
                }
            }
        }
    }

    /// Our face, which opens Settings. VoiceOver and the Large Content Viewer name it Settings: the face is decorative. It
    /// is the link's whole label, since a toolbar shows a label's title where its icon is no image.
    private struct SettingsButton: View {
        let face: Face

        var body: some View {
            NavigationLink(value: Route.settings) {
                AvatarView(face: face, size: Layout.faceToolbar)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.ChatList.settings)
            .accessibilityAddTraits(.isButton)
            .accessibilityShowsLargeContentViewer {
                Label(Copy.ChatList.settings, systemImage: "gearshape")
            }
            .accessibilityIdentifier(AccessibilityID.chatListSettings)
        }
    }

    /// The way into the message requests, with how many wait, in a coral count at the trailing edge.
    private struct RequestsEntry: View {
        let count: Int

        var body: some View {
            NavigationLink(value: Route.requests) {
                HStack(spacing: Layout.medium) {
                    Image(systemName: "tray.full")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: Layout.faceList, height: Layout.faceList)
                        .background(Palette.incomingBubble, in: .circle)
                        .accessibilityHidden(true)
                    Text(Copy.ChatList.requests)
                        .font(.headline)
                    Spacer()
                    // The value says how many, in words.
                    Text(count, format: .number)
                        .font(.subheadline.bold())
                        .monospacedDigit()
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Layout.small)
                        .padding(.vertical, Layout.hairline)
                        .background(Palette.accent, in: .capsule)
                        .accessibilityHidden(true)
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
        @State private var showsBoundary = false

        var body: some View {
            VStack(alignment: .leading, spacing: Layout.small) {
                HStack(spacing: Layout.small) {
                    Label {
                        Text(status.line)
                            .font(.subheadline)
                    } icon: {
                        StatusMark(status: status)
                    }
                    .accessibilityIdentifier(AccessibilityID.chatListStatus(status.accessibilityState))
                    if status.offersBoundary {
                        Spacer()
                        BoundaryButton(isShowing: $showsBoundary)
                    }
                }
                if status.offersBoundary, showsBoundary {
                    Text(Copy.Status.boundary)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.chatListBoundary)
                }
                if status.offersStart {
                    Button(Copy.Status.start, action: start)
                        .secondaryButton()
                        .accessibilityIdentifier(AccessibilityID.chatListStatusStart)
                }
                if status.offersSettings {
                    OpenSettingsButton()
                        .secondaryButton()
                        .accessibilityIdentifier(AccessibilityID.chatListStatusSettings)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// The status line's mark, Android's dot (`ConnectionStatus.kt`): green with someone linked, gray with nobody, and in
    /// the warning color when the mesh cannot run; Knit's stitches while it starts. The words beside it say the same, so
    /// the color is never the only cue.
    private struct StatusMark: View {
        let status: ConnectionStatus
        @ScaledMetric(relativeTo: .subheadline) private var side = Layout.statusDot

        var body: some View {
            if case .starting = status {
                StitchIndicator()
            } else {
                Circle()
                    .fill(color)
                    .frame(width: side, height: side)
                    .accessibilityHidden(true)
            }
        }

        private var color: Color {
            switch status {
            case .linked(let count):
                count > 0 ? Palette.positive : Palette.secondaryText
            case .starting, .stopped, .bluetoothOff, .notAllowed, .unsupported:
                status.isWarning ? Palette.warning : Palette.secondaryText
            }
        }
    }

    /// The status line's info button, which shows the radio's boundary under the line and hides it again. The boundary
    /// needs reading once, not every time the list opens. It is no popover: anchored in a list row, one opens as a
    /// sheet on the iPhone whatever its compact adaptation asks.
    private struct BoundaryButton: View {
        @Binding var isShowing: Bool

        var body: some View {
            Button {
                withAnimation { isShowing.toggle() }
            } label: {
                Label(Copy.Status.boundaryButton, systemImage: isShowing ? "info.circle.fill" : "info.circle")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Layout.hitTarget, minHeight: Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            // Borderless, so only the glyph takes the tap and not the whole row.
            .buttonStyle(.borderless)
            .accessibilityAddTraits(isShowing ? .isSelected : [])
            .accessibilityIdentifier(AccessibilityID.chatListStatusAbout)
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

    /// The first-run card: Knit's mark, what to do first, and the way into the room, on a gray card.
    private struct GettingStartedCard: View {
        @ScaledMetric(relativeTo: .headline) private var mark = Layout.markInline

        var body: some View {
            VStack(alignment: .leading, spacing: Layout.small) {
                HStack(spacing: Layout.small) {
                    KnitMark()
                        .fill(.tint)
                        .frame(width: mark, height: mark)
                        .accessibilityHidden(true)
                    Text(Copy.ChatList.gettingStartedTitle)
                        .font(.headline)
                }
                Text(Copy.ChatList.gettingStartedBody)
                    .foregroundStyle(Palette.secondaryText)
                NavigationLink(value: Route.chat(Conversations.nearby)) {
                    Text(Copy.ChatList.gettingStartedAction)
                }
                .prominentButton()
            }
            .padding(Layout.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.incomingBubble, in: .rect(cornerRadius: Layout.cardCorner))
        }
    }

    /// One thread, as Signal lists it: the face, the title and the time, and the preview under them. One VoiceOver element
    /// that reads the title, the preview, the time and the tick, and whether the peer is in range.
    private struct ChatRowView: View {
        let row: ChatRow
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            HStack(spacing: Layout.medium) {
                // At the accessibility sizes the face would take a third of the row from the title, which says who.
                if !typeSize.isAccessibilitySize {
                    AvatarView(face: row.face, size: Layout.faceList)
                        .overlay(alignment: .bottomTrailing) {
                            if row.isLinked {
                                LinkedBadge()
                            }
                        }
                }
                VStack(alignment: .leading, spacing: Layout.hairline) {
                    RowTitle(row: row)
                    HStack(alignment: .firstTextBaseline, spacing: Layout.tight) {
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
            .padding(.vertical, Layout.tight)
            .accessibilityElement(children: .combine)
            // The badge is drawn on the face, which VoiceOver skips; at the accessibility sizes the title carries a glyph.
            .accessibilityValue(row.isLinked && !typeSize.isAccessibilitySize ? Copy.ChatList.inRange : "")
        }
    }

    /// A linked peer's dot on their face, ringed in the list's background so it reads on any photo.
    private struct LinkedBadge: View {
        var body: some View {
            Circle()
                .fill(Palette.positive)
                .frame(width: Layout.badge, height: Layout.badge)
                .padding(Layout.badgeRing)
                .background(.background, in: .circle)
                .accessibilityHidden(true)
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
                // At the accessibility sizes the face, and its badge, are gone.
                if row.isLinked, typeSize.isAccessibilitySize {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Palette.positive)
                        .accessibilityLabel(Copy.ChatList.inRange)
                }
                if !typeSize.isAccessibilitySize {
                    Spacer()
                }
                if let at = row.lastMessageAt {
                    // Formatted against the clock, not once at render, so the time keeps counting while the list
                    // stays open. Android's list ticks the same way (ChatListScreen.kt's rememberCurrentTimeMillis).
                    Text(
                        .currentDate,
                        format: Date.AnchoredRelativeFormatStyle(
                            anchor: Date(milliseconds: at), presentation: .numeric, unitsStyle: .abbreviated)
                    )
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

#endif
