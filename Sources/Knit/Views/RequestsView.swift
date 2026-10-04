#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Message requests: strangers' DMs, each with Accept, and Block a swipe away. A row opens the thread to read it
    /// first, where Block also waits under Accept.
    internal struct RequestsView: View {
        @State private var model: RequestsModel
        /// The request whose sender Block is asking about.
        @State private var blocking: RequestRow?
        @Environment(\.dynamicTypeSize) private var typeSize

        init(session: AppSession) {
            _model = State(initialValue: RequestsModel(session: session))
        }

        var body: some View {
            List {
                Section {
                    if model.rows.isEmpty {
                        Text(Copy.Requests.empty)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(model.rows) { row in
                        // At the accessibility sizes, Accept goes under the request rather than squeezing it.
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                        layout {
                            NavigationLink(value: Route.chat(row.id)) {
                                RequestLabel(row: row)
                            }
                            .accessibilityIdentifier(AccessibilityID.requestRow(row.id))
                            Button(Copy.Requests.accept) {
                                Task { await model.accept(row.id) }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(AccessibilityID.requestAccept(row.id))
                        }
                        .swipeActions {
                            // A group's request has nobody to block. Not a destructive role: the row stays until the
                            // dialog's Block, which takes it.
                            if !row.isGroup {
                                Button(Copy.Block.block) { blocking = row }
                                    .tint(Palette.critical)
                                    .accessibilityIdentifier(AccessibilityID.requestBlock(row.id))
                            }
                        }
                    }
                } footer: {
                    SectionNote(Copy.Requests.explanation)
                }
            }
            .navigationTitle(Copy.Requests.title)
            .confirmsBlock(of: blocking?.title ?? "", isPresented: confirmsBlock) {
                if let row = blocking {
                    Task { await model.block(row.id) }
                }
            }
        }

        private var confirmsBlock: Binding<Bool> {
            Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } })
        }
    }

    /// A request's face, title and newest message.
    private struct RequestLabel: View {
        let row: RequestRow
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            HStack(spacing: Layout.medium) {
                // At the accessibility sizes the face would squeeze the request; its title says who.
                if !typeSize.isAccessibilitySize {
                    AvatarView(face: row.face, size: Layout.faceRequest)
                }
                VStack(alignment: .leading, spacing: Layout.hairline) {
                    Text(row.title)
                        .font(.headline)
                    Text(row.preview ?? Copy.ChatList.noMessages)
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : Layout.previewLines)
                }
            }
        }
    }
#endif
