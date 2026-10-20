#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI
    import UIKit

    /// Add contact (ADR 2026-10.tpr5, `AddContactScreen` in knit-next): our code for someone nearby to scan and the way to
    /// scan theirs, our link to send someone further away, and a link someone sent, previewed before it is added.
    internal struct AddContactView: View {
        @State private var model: AddContactModel
        @State private var scanning = false
        /// What the scan found, until its sheet has gone.
        @State private var pending: AddContactScanOutcome?
        /// What the scan found, while the alert says so.
        @State private var outcome: AddContactScanOutcome?
        /// Whether our link was copied since the screen opened.
        @State private var copied = false
        @FocusState private var editing: Bool
        private let camera: any CameraAccess
        private let opened: (NodeId) -> Void

        /// Add contact over `session`, previewing `link` at once when one was opened, which hands the person added to
        /// `opened`.
        init(session: AppSession, camera: any CameraAccess, link: String?, opened: @escaping (NodeId) -> Void) {
            let made = AddContactModel(session: session)
            if let link {
                made.lookup(link)
            }
            _model = State(initialValue: made)
            self.camera = camera
            self.opened = opened
        }

        var body: some View {
            Form {
                InPersonSection(code: model.ownCode) { scanning = true }
                LinkSection(shareText: model.shareText, copied: copied) {
                    UIPasteboard.general.string = model.linkURL
                    copied = true
                }
                ByLinkSection(model: model, editing: $editing)
            }
            .navigationTitle(Copy.AddContact.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.addContactScreen)
            .task { await model.signLink() }
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
            // The alert waits for the sheet to go: SwiftUI drops one presented while another is dismissing.
            .sheet(isPresented: $scanning, onDismiss: revealOutcome) {
                CodeScannerSheet(camera: camera) { text in
                    Task {
                        pending = await model.scanned(text)
                        scanning = false
                    }
                }
            }
            .alert(outcome.map(Copy.AddContact.scanOutcome) ?? "", isPresented: showsOutcome) {
                Button(Copy.Common.done, role: .cancel) { outcome = nil }
            }
            .sensoryFeedback(trigger: outcome) { _, now in
                switch now {
                case .added:
                    .success
                case .mismatch, .failed:
                    .error
                case .ownCode, .notACode, nil:
                    nil
                }
            }
            .alert(model.problem.map(Copy.AddContact.problem) ?? "", isPresented: showsProblem) {
                Button(Copy.Common.done, role: .cancel) { model.problem = nil }
            }
            .sheet(item: $model.preview, onDismiss: model.previewClosed) { preview in
                AddContactPreviewSheet(preview: preview) {
                    Task {
                        if let nodeId = await model.confirm() {
                            opened(nodeId)
                        }
                    }
                }
            }
        }

        private var showsOutcome: Binding<Bool> {
            Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
        }

        private var showsProblem: Binding<Bool> {
            Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        }

        /// The scan's result, once its sheet has gone.
        private func revealOutcome() {
            outcome = pending
            pending = nil
        }
    }

    /// Our code for someone nearby to scan, and the way to scan theirs.
    private struct InPersonSection: View {
        let code: String
        let scan: () -> Void

        var body: some View {
            Section {
                VStack(spacing: Layout.small) {
                    QRCodeView(text: code)
                    Text(Copy.AddContact.codeCaption)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.small)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(AccessibilityID.addContactCode)
                Button(action: scan) {
                    RowLabel(Copy.Profile.scan, symbol: "qrcode.viewfinder")
                }
                .accessibilityIdentifier(AccessibilityID.addContactScan)
            } footer: {
                SectionNote(Copy.AddContact.inPerson)
            }
        }
    }

    /// Our link, to share or copy, once it is signed.
    private struct LinkSection: View {
        let shareText: String?
        let copied: Bool
        let copy: () -> Void

        var body: some View {
            Section {
                if let shareText {
                    ShareLink(item: shareText) {
                        RowLabel(Copy.AddContact.shareLink, symbol: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier(AccessibilityID.addContactShareLink)
                    Button(action: copy) {
                        RowLabel(
                            copied ? Copy.AddContact.linkCopied : Copy.AddContact.copyLink,
                            symbol: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .accessibilityIdentifier(AccessibilityID.addContactCopyLink)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                SectionNote(Copy.AddContact.linkCaption)
            }
        }
    }

    /// A link someone sent: typed or pasted, then read.
    private struct ByLinkSection: View {
        @Bindable var model: AddContactModel
        let editing: FocusState<Bool>.Binding

        var body: some View {
            Section {
                TextField(Copy.AddContact.inputLabel, text: $model.input, prompt: Text(Copy.AddContact.inputPrompt), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused(editing)
                    .onSubmit { model.lookup() }
                    .accessibilityIdentifier(AccessibilityID.addContactInput)
                HStack {
                    // The system's Paste reads the pasteboard on a tap, with no prompt to allow it.
                    PasteButton(payloadType: String.self) { texts in
                        if let text = texts.first {
                            editing.wrappedValue = false
                            model.lookup(text)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier(AccessibilityID.addContactPaste)
                    Spacer()
                    Button(Copy.AddContact.lookup) {
                        editing.wrappedValue = false
                        model.lookup()
                    }
                    .disabled(model.input.allSatisfy(\.isWhitespace))
                    .accessibilityIdentifier(AccessibilityID.addContactLookup)
                }
                .buttonStyle(.borderless)
            } header: {
                SectionNote(Copy.AddContact.byLink)
            } footer: {
                SectionNote(Copy.AddContact.byLinkCaption)
            }
        }
    }

    /// The person a link names, with the safety number to compare, before they are added.
    private struct AddContactPreviewSheet: View {
        let preview: AddContactPreview
        let confirm: () -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    PreviewHeader(preview: preview)
                    Section {
                        ValueRow(Copy.Profile.aliasLabel, value: preview.alias)
                        NodeIdRow(nodeId: preview.nodeId.string)
                    }
                    PreviewSafetyNumber(preview: preview)
                    PreviewNote(preview: preview)
                    Section {
                        Button(preview.isBlocked ? Copy.AddContact.confirmUnblocking : Copy.AddContact.confirm, action: confirm)
                            .prominentButton()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier(AccessibilityID.addContactConfirm)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Common.cancel) { dismiss() }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.addContactPreview)
            }
            // Opaque, as the other sheets are: text over the glass took its contrast from the screen behind.
            .presentationBackground(.background)
        }
    }

    /// The preview's face and question, centered on the page as a profile heads one.
    private struct PreviewHeader: View {
        let preview: AddContactPreview

        var body: some View {
            Section {
                VStack(spacing: Layout.tight) {
                    AvatarView(face: preview.face, size: Layout.faceProfile)
                        .padding(.bottom, Layout.small)
                    Text(Copy.AddContact.previewTitle(preview.title))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }
    }

    /// The safety number both phones should read, and why to compare it before adding.
    private struct PreviewSafetyNumber: View {
        let preview: AddContactPreview

        var body: some View {
            Section {
                VStack(alignment: .leading, spacing: Layout.small) {
                    Text(Copy.Profile.safetyNumber)
                        .font(.headline)
                    ForEach(preview.safetyNumber, id: \.self) { line in
                        Text(line)
                            .font(.title3.monospaced())
                    }
                    Text(Copy.AddContact.safetyCaption(preview.title))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// That the person is blocked, or already a contact, if either holds.
    private struct PreviewNote: View {
        let preview: AddContactPreview

        var body: some View {
            if preview.isBlocked {
                Section {
                    Label(Copy.AddContact.blocked, systemImage: "hand.raised.fill")
                        .foregroundStyle(Palette.critical)
                }
            } else if preview.isContact {
                Section {
                    Label(Copy.AddContact.already(preview.title), systemImage: "person.crop.circle.badge.checkmark")
                }
            }
        }
    }
#endif
