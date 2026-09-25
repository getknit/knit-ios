import Foundation

/// Where a device keeps its identity's private keys: the Keychain on the phone, a file for the Linux peer.
public protocol SecretStore: Sendable {
    /// The stored secret, or `nil` when nothing has been stored yet. Throws when the store cannot answer now.
    func read() throws(SecretStoreError) -> [UInt8]?
    /// Replaces the stored secret.
    func write(_ secret: [UInt8]) throws(SecretStoreError)
}

/// A store that could not be read or written. Try again later; never answer this by making new keys.
public enum SecretStoreError: Error, Sendable, Equatable {
    /// The store refused, with its reason.
    case unavailable(String)
}

/// A ``SecretStore`` in one file only its owner can read, for the Linux peer and for tests.
///
/// A missing directory is created with mode 0700, and the file is written atomically, then set to 0600. The
/// temporary file exists for a moment with the process's default mode, which is why the directory matters.
public struct FileSecretStore: SecretStore {
    private static let directoryMode = 0o700
    private static let fileMode = 0o600

    /// The file's path.
    public let path: String

    /// A store at `path`.
    public init(path: String) {
        self.path = path
    }

    /// The file's bytes, or `nil` when there is no file.
    public func read() throws(SecretStoreError) -> [UInt8]? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw .unavailable("cannot read \(path)")
        }
        return Array(data)
    }

    /// Replaces the file's bytes.
    public func write(_ secret: [UInt8]) throws(SecretStoreError) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryMode]
            )
            try Data(secret).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: path)
        } catch {
            throw .unavailable("cannot write \(path): \(error)")
        }
    }
}
