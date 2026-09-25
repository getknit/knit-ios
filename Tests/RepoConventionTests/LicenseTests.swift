import Crypto
import Foundation
import Testing

/// Knit for iOS is GPL-3.0-or-later with an App Store exception. `COPYING` must stay the verbatim license text
/// the FSF publishes, byte for byte: the exception lives in its own file, never as an edit to this one.
@Suite struct LicenseTests {
    @Test func copyingIsTheVerbatimGPLv3() throws {
        let digest = SHA256.hash(data: try RepoFiles.data("COPYING"))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986")
    }

    @Test func theAppStoreExceptionNamesGPLv3Section7() throws {
        let exception = try RepoFiles.text("APP-STORE-EXCEPTION.md")
        #expect(exception.contains("section 7"))
        #expect(exception.contains("GNU General Public License"))
    }
}
