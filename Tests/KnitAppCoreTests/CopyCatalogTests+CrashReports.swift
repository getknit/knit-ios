import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Saved reports' strings, apart so the suite stays under the lint's length.
    static var crashReportStrings: [String] {
        [
            Copy.CrashReports.section,
            Copy.CrashReports.lastCrash,
            Copy.CrashReports.lastHang,
            Copy.CrashReports.title(.crash),
            Copy.CrashReports.title(.hang),
            Copy.CrashReports.saved("2 hours ago"),
            Copy.CrashReports.explanation(.crash),
            Copy.CrashReports.explanation(.hang),
            Copy.CrashReports.limits,
            Copy.CrashReports.empty,
            Copy.CrashReports.report,
            Copy.CrashReports.copy,
            Copy.CrashReports.copied,
            Copy.CrashReports.share,
            Copy.CrashReports.details,
            Copy.CrashReports.deleteAll,
            Copy.CrashReports.reportTitle,
            Copy.CrashReports.reportBody,
            Copy.CrashReports.openForm,
            Copy.CrashReports.deleteTitle,
            Copy.CrashReports.deleteBody,
            Copy.CrashReports.shareTitle(.crash),
            Copy.CrashReports.shareTitle(.hang),
        ]
    }
}
