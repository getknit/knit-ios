#if os(iOS)
    // A debug build's alone until the maintainer approves the spool plane for the store (ADR 2026-11.adrq, P6): a store build
    // shows no relay settings, opens no consent sheet and ignores relay invites.
    #if DEBUG
        import KnitAppCore
        import SwiftUI

        /// Settings' Internet relays, following link previews' section (ADR 2026-11.hcvg): the master switch, which asks first,
        /// the relays with the host each dials, who runs it, a private mark and where it stands, Stop using and Remove, and
        /// Paste, which takes an invite link through the system's paste button, so nothing reads the pasteboard before a tap.
        internal struct InternetRelaySection: View {
            let relays: InternetRelays

            var body: some View {
                Section {
                    Toggle(isOn: Binding(get: { relays.spoolEnabled }, set: { relays.setSwitch($0) })) {
                        RowLabel(Copy.Relays.switchTitle, symbol: "network")
                    }
                    .disabled(!relays.isLoaded)
                    .accessibilityIdentifier(AccessibilityID.settingsInternetRelays)
                    // A kept list that does not read yet is left as it is, and nothing is dialled until it does.
                    if !relays.isLoaded {
                        Text(Copy.Relays.listUnreadable)
                            .foregroundStyle(Palette.secondaryText)
                    } else if relays.rows.isEmpty {
                        Text(Copy.Relays.empty)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(relays.rows) { row in
                        RelayRowView(row: row, relays: relays)
                    }
                } header: {
                    SectionNote(Copy.Relays.title)
                } footer: {
                    SectionNote(Copy.Relays.footer)
                }
                Section {
                    PasteButton(payloadType: String.self) { texts in
                        if let text = texts.first {
                            relays.offer(pasted: text)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(AccessibilityID.relaysPaste)
                } header: {
                    SectionNote(Copy.Relays.addHeader)
                } footer: {
                    SectionNote(Copy.Relays.pasteFooter)
                }
                // Where each relay stands, read again each second while Settings is up: words, never counts.
                .task {
                    while !Task.isCancelled {
                        await relays.refreshStatus()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        }

        /// One relay: its host, whole, who runs it and whether it is private, where it stands, and its two buttons, each named by
        /// the relay's handle.
        private struct RelayRowView: View {
            let row: RelayRow
            let relays: InternetRelays

            var body: some View {
                VStack(alignment: .leading, spacing: Layout.small) {
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        Text(row.title)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.details)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
                    HStack {
                        // A row whose address does not read, or another row dials, has nothing to stop using: only Remove.
                        if row.host != nil, row.status != .duplicate {
                            Button(row.parked ? Copy.Relays.unpark : Copy.Relays.park) { relays.setParked(row.handle, !row.parked) }
                                .accessibilityIdentifier(AccessibilityID.relayPark(row.handle))
                        }
                        Spacer()
                        // The palette's red: the system's reads about 3.6:1 on a grouped cell in light.
                        Button(Copy.Relays.remove, role: .destructive) { relays.remove(row.handle) }
                            .foregroundStyle(Palette.critical)
                            .accessibilityIdentifier(AccessibilityID.relayRemove(row.handle))
                    }
                    .buttonStyle(.borderless)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.relayRow(row.handle))
            }
        }

        /// The consent a sheet asks: the hosts the switch dials, or the one relay an invite adds, what a relay learns, what rides
        /// it and when it runs. Its button applies the sheet it was built from, never one that came after it.
        internal struct RelayConsentView: View {
            let sheet: RelaySheet
            /// Whether the switch is on, for an invite's sheet to say it adds a relay nothing dials yet.
            let switchOn: Bool
            let confirm: () -> Void
            let decline: () -> Void

            var body: some View {
                ScrollView {
                    ConsentWords(sheet: sheet, switchOn: switchOn)
                        .padding(Layout.page)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.relaysConsent)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: Layout.medium) {
                        Button(sheet.isTurnOn ? Copy.RelayConsent.turnOn : Copy.RelayConsent.add, action: confirm)
                            .prominentButton()
                            .accessibilityIdentifier(AccessibilityID.relaysConsentAccept)
                        Button(Copy.RelayConsent.notNow, action: decline)
                            .secondaryButton()
                            .accessibilityIdentifier(AccessibilityID.relaysConsentDecline)
                    }
                    .padding(Layout.page)
                    .background(.background)
                }
                // Opaque, as an info sheet is: text over the glass sheet took its contrast from whatever was behind it.
                .presentationBackground(.background)
            }
        }

        /// What a consent sheet says: its title, the hosts it names, and what a relay learns, carries and when it runs.
        private struct ConsentWords: View {
            let sheet: RelaySheet
            let switchOn: Bool

            var body: some View {
                VStack(alignment: .leading, spacing: Layout.large) {
                    Text(sheet.isTurnOn ? Copy.RelayConsent.turnOnTitle : Copy.RelayConsent.addTitle)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    switch sheet.kind {
                    case .turnOn(let joining):
                        Text(joining.isEmpty ? Copy.RelayConsent.turnOnNone : Copy.RelayConsent.turnOnHosts)
                        // Every relay that can join under this consent: one whose address cannot be read now by its number,
                        // which joins once it reads.
                        ForEach(joining, id: \.handle) { relay in
                            HostView(title: relay.title, marks: relay.marks)
                        }
                    case .add(let url):
                        let host = RelayHost(url)
                        HostView(title: host.host, marks: host.marks)
                        if host.isPrivate {
                            Text(Copy.RelayConsent.privateNote)
                        }
                        if !switchOn {
                            Text(Copy.RelayConsent.offNote)
                        }
                    }
                    Text(Copy.RelayConsent.learns)
                    Text(Copy.RelayConsent.textOnly)
                    Text(Copy.RelayConsent.openOnly)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        /// A relay's host as the dialler reads it, wrapped whole, or its number while its address cannot be read, with who runs
        /// it and its access-key mark, or that it joins once its address reads.
        private struct HostView: View {
            let title: String
            let marks: String

            var body: some View {
                VStack(alignment: .leading, spacing: Layout.tight) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(marks)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }

        extension View {
            /// The relay settings' prompts over the live screens: an invite a launch holds goes to the relays once onboarding
            /// and the terms are behind, after `close` has closed what is up, and the consent sheet and the refusal's line
            /// show here, wherever in the app the person is.
            func relayPrompts(_ relays: InternetRelays?, launch: Launch, takesRequests: Bool, close: @escaping () -> Void) -> some View {
                modifier(RelayPrompts(relays: relays, launch: launch, takesRequests: takesRequests, closeSheets: close))
            }
        }

        private struct RelayPrompts: ViewModifier {
            let relays: InternetRelays?
            let launch: Launch
            let takesRequests: Bool
            let closeSheets: () -> Void

            func body(content: Content) -> some View {
                content
                    .onChange(of: launch.requestedRelayInvite, initial: true) { _, link in
                        guard takesRequests, let link else {
                            return
                        }
                        launch.requestedRelayInvite = nil
                        closeSheets()
                        relays?.offer(opened: link)
                    }
                    .sheet(item: sheet) { shown in
                        RelayConsentView(
                            sheet: shown,
                            switchOn: relays?.spoolEnabled == true,
                            confirm: { relays?.confirm(shown) },
                            decline: { relays?.dismiss(shown) }
                        )
                    }
                    .alert(Copy.RelayConsent.inviteAlert, isPresented: noticeShown, presenting: relays?.notice) { _ in
                        Button(Copy.Common.done, role: .cancel) {
                            relays?.notice = nil
                        }
                    } message: { notice in
                        Text(notice.message)
                    }
            }

            private var sheet: Binding<RelaySheet?> {
                Binding {
                    relays?.sheet
                } set: { value in
                    if value == nil, let shown = relays?.sheet {
                        relays?.dismiss(shown)
                    }
                }
            }

            private var noticeShown: Binding<Bool> {
                Binding {
                    relays?.notice != nil
                } set: { shown in
                    if !shown {
                        relays?.notice = nil
                    }
                }
            }
        }
    #endif
#endif
