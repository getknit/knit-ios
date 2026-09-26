#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Message requests: strangers' DMs, each with Accept. A row opens the thread to read it first.
    internal struct RequestsView: View {
        @State private var model: RequestsModel

        init(session: AppSession) {
            _model = State(initialValue: RequestsModel(session: session))
        }

        var body: some View {
            List {
                Section {
                    if model.rows.isEmpty {
                        Text(Copy.Requests.empty)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.rows) { row in
                        HStack {
                            NavigationLink(value: Route.chat(row.id)) {
                                VStack(alignment: .leading, spacing: Layout.hairline) {
                                    Text(row.title)
                                        .font(.headline)
                                    Text(row.preview)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(Layout.previewLines)
                                }
                            }
                            .accessibilityIdentifier(AccessibilityID.requestRow(row.id))
                            Button(Copy.Requests.accept) {
                                Task { await model.accept(row.id) }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(AccessibilityID.requestAccept(row.id))
                        }
                    }
                } footer: {
                    Text(Copy.Requests.explanation)
                }
            }
            .navigationTitle(Copy.Requests.title)
        }
    }
#endif
