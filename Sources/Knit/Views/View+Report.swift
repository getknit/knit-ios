#if os(iOS)
    import KnitAppCore
    import MessageUI
    import SwiftUI
    import UIKit

    extension View {
        /// Asks before filing `report` (ADR 2026-10.f6kf): what a report does here, then Report, Report and Email Knit, or
        /// Cancel. Either button files it through `file`; the second then opens the email in Mail, or in the phone's mail
        /// app through a `mailto:` link, or, with neither, names the address to write to. An alert, as Block's and
        /// Delete's are.
        func confirmsReport(_ report: Binding<AbuseReport?>, file: @escaping (AbuseReport) async -> Void) -> some View {
            modifier(ReportFlow(report: report, file: file))
        }
    }

    private struct ReportFlow: ViewModifier {
        @Binding var report: AbuseReport?
        let file: (AbuseReport) async -> Void
        /// The email Mail is writing.
        @State private var mailing: ReportEmail?
        /// Whether no way to send email was found.
        @State private var mailless = false
        @Environment(\.openURL) private var openURL

        func body(content: Content) -> some View {
            content
                .alert(report.map { Copy.Report.confirmTitle($0.name) } ?? "", isPresented: asking, presenting: report) { shown in
                    Button(Copy.Report.reportAndEmail, role: .destructive) {
                        Task {
                            await file(shown)
                            email(shown)
                        }
                    }
                    Button(Copy.Report.report, role: .destructive) {
                        Task { await file(shown) }
                    }
                    Button(Copy.Common.cancel, role: .cancel) {
                        // The alert closes itself.
                    }
                } message: { shown in
                    Text(shown.messageId == nil ? Copy.Report.confirmPerson(shown.name) : Copy.Report.confirmMessage(shown.name))
                }
                .sheet(item: $mailing) { email in
                    MailComposer(email: email)
                        .ignoresSafeArea()
                }
                .alert(Copy.Report.noMailTitle, isPresented: $mailless) {
                    Button(Copy.Report.copyAddress) {
                        UIPasteboard.general.string = AbuseReport.address
                    }
                    Button(Copy.Common.done, role: .cancel) {
                        // The alert closes itself.
                    }
                } message: {
                    Text(Copy.Report.noMailBody(AbuseReport.address))
                }
        }

        private var asking: Binding<Bool> {
            Binding(get: { report != nil }, set: { if !$0 { report = nil } })
        }

        /// Opens `report` as an email: in Mail when it has an account, else in whatever app takes `mailto:`, else says
        /// where to write.
        private func email(_ report: AbuseReport) {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? ""
            let build = info["CFBundleVersion"] as? String ?? ""
            let email = ReportEmail(report, version: "\(version) (\(build))", now: .now)
            if MFMailComposeViewController.canSendMail() {
                mailing = email
            } else if let url = email.mailto {
                openURL(url) { opened in
                    mailless = !opened
                }
            } else {
                mailless = true
            }
        }
    }

    /// Mail's composer, addressed to Knit and filled with the report, which the user may edit, send or cancel. It closes
    /// itself either way.
    private struct MailComposer: UIViewControllerRepresentable {
        let email: ReportEmail
        @Environment(\.dismiss) private var dismiss

        func makeUIViewController(context: Context) -> MFMailComposeViewController {
            let composer = MFMailComposeViewController()
            composer.mailComposeDelegate = context.coordinator
            composer.setToRecipients([AbuseReport.address])
            composer.setSubject(email.subject)
            composer.setMessageBody(email.body, isHTML: false)
            return composer
        }

        func updateUIViewController(_: MFMailComposeViewController, context _: Context) {
            // Nothing changes once it is open.
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(dismiss: dismiss)
        }

        /// Mail calls its delegate on the main thread, so the conformance is the main actor's, where `dismiss` runs.
        @MainActor
        final class Coordinator: NSObject, @MainActor MFMailComposeViewControllerDelegate {
            private let dismiss: DismissAction

            init(dismiss: DismissAction) {
                self.dismiss = dismiss
            }

            func mailComposeController(_: MFMailComposeViewController, didFinishWith _: MFMailComposeResult, error _: (any Error)?) {
                dismiss()
            }
        }
    }
#endif
