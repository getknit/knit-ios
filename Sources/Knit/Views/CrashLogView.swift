#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// The newest saved report of one kind (ADR 2026-10.qhsv, after Android's `CrashLogScreen`): what it is, Report on
    /// GitHub, Copy and Share, what no report covers, the report itself, and Delete all. Report on GitHub asks first, since
    /// an issue is public, then puts the whole report on the clipboard and opens the bug form filled in with what fits.
    internal struct CrashLogView: View {
        @State private var model: CrashLogModel
        @State private var confirmingReport = false
        @State private var confirmingDelete = false
        @Environment(\.openURL) private var openURL

        init(store: CrashStore, kind: CrashDiagnostic.Kind) {
            _model = State(initialValue: CrashLogModel(store: store, kind: kind))
        }

        var body: some View {
            Form {
                if let report = model.report {
                    ActionSection(report: report, kind: model.kind) { confirmingReport = true }
                    Section {
                        Text(report.text)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        SectionNote(Copy.CrashReports.details)
                    }
                    Section {
                        Button(Copy.CrashReports.deleteAll, role: .destructive) {
                            confirmingDelete = true
                        }
                        .accessibilityIdentifier(AccessibilityID.crashLogDelete)
                    }
                } else if model.isLoaded {
                    Text(Copy.CrashReports.empty)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .navigationTitle(Copy.CrashReports.title(model.kind))
            .task { await model.load() }
            .alert(Copy.CrashReports.reportTitle, isPresented: $confirmingReport) {
                Button(Copy.CrashReports.openForm, action: report)
                Button(Copy.Common.cancel, role: .cancel) {
                    // The alert closes itself.
                }
            } message: {
                Text(Copy.CrashReports.reportBody)
            }
            .alert(Copy.CrashReports.deleteTitle, isPresented: $confirmingDelete) {
                Button(Copy.CrashReports.deleteAll, role: .destructive) {
                    Task { await model.deleteAll() }
                }
                Button(Copy.Common.cancel, role: .cancel) {
                    // The alert closes itself.
                }
            } message: {
                Text(Copy.CrashReports.deleteBody)
            }
            .accessibilityIdentifier(AccessibilityID.crashLogScreen)
        }

        /// Opens the bug form. The link carries what fits; the clipboard carries all of it, for the reporter to paste in.
        private func report() {
            guard let report = model.report, let issue = report.issue else {
                return
            }
            UIPasteboard.general.string = report.text
            openURL(issue)
        }
    }

    /// The report's summary and when it was saved, its three ways off the phone, and what it is and is not.
    private struct ActionSection: View {
        let report: CrashLogModel.Loaded
        let kind: CrashDiagnostic.Kind
        /// Asks before the bug form opens.
        let onReport: () -> Void
        @State private var copied = false

        var body: some View {
            Section {
                VStack(alignment: .leading, spacing: Layout.hairline) {
                    Text(report.ref.summary)
                        .font(.headline)
                    Text(Copy.CrashReports.saved(Date(milliseconds: report.ref.at).formatted(.relative(presentation: .named))))
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
                Button(Copy.CrashReports.report, action: onReport)
                    .disabled(report.issue == nil)
                    .accessibilityIdentifier(AccessibilityID.crashLogReport)
                Button(copied ? Copy.CrashReports.copied : Copy.CrashReports.copy) {
                    UIPasteboard.general.string = report.text
                    copied = true
                }
                .accessibilityIdentifier(AccessibilityID.crashLogCopy)
                if let file = report.shareFile {
                    ShareLink(item: file, preview: SharePreview(Copy.CrashReports.shareTitle(kind))) {
                        Text(Copy.CrashReports.share)
                    }
                    .accessibilityIdentifier(AccessibilityID.crashLogShare)
                }
            } footer: {
                VStack(alignment: .leading, spacing: Layout.small) {
                    SectionNote(Copy.CrashReports.explanation(kind))
                    SectionNote(Copy.CrashReports.limits)
                }
            }
        }
    }
#endif
