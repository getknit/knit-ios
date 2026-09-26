import Foundation

/// The directory the database lives in, and the protection it carries on Apple platforms.
///
/// GRDB's advice is to give the database a directory of its own and protect that: SQLite's `-wal` and `-shm`
/// files come and go beside the main file and take the directory's class. On iOS the class is
/// `completeUntilFirstUserAuthentication`, not `complete`: the mesh relays and carries frames while the phone
/// sits locked in a pocket, and a `complete` file is unreadable then. The main file gets the class too, in case
/// it predates the directory's.
///
/// The directory is also excluded from backups. Nothing encrypts the file beyond Data Protection, so a backup
/// would copy message text off the phone, and the identity those messages belong to is a Keychain item that
/// never leaves it (ADR 2026-09.nyya).
internal enum StorageDirectory {
    /// Creates `directory` if needed and applies its protection and its backup exclusion.
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
        #if canImport(Darwin)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = directory
            try url.setResourceValues(values)
        #endif
    }

    /// Applies the protection class to `item`. It does nothing off iOS, where there is none to apply.
    static func protect(_ item: URL) throws {
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: item.path(percentEncoded: false)
            )
        #else
            _ = item
        #endif
    }
}
