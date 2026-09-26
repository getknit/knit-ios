#if os(iOS)
    import Foundation
    import KnitCrypto
    import Security

    /// The identity's private keys in the Keychain: one generic-password item, readable after the first unlock
    /// since a reboot, and never copied off this phone (`…AfterFirstUnlockThisDeviceOnly`). The mesh reads it while
    /// the phone sits locked; a backup or a new phone never gets it, so an identity runs on one phone only.
    ///
    /// The item outlives the app: a reinstall finds it and carries on as the same node (ADR 2026-09.tkww). The only
    /// file in the app that imports Security.
    internal struct KeychainSecretStore: SecretStore {
        /// The item's service, fixed for the life of the identity.
        static let service = "app.getknit.knit.identity"
        /// The item's account.
        static let account = "identity"

        func read() throws(SecretStoreError) -> [UInt8]? {
            var query = Self.item
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else {
                    throw .unavailable("the Keychain answered without data")
                }
                return Array(data)
            case errSecItemNotFound:
                return nil
            default:
                // errSecInteractionNotAllowed before the first unlock: not a missing identity, so never an answer
                // that makes new keys.
                throw .unavailable(Self.describe(status))
            }
        }

        func write(_ secret: [UInt8]) throws(SecretStoreError) {
            let update: [String: Any] = [
                kSecValueData as String: Data(secret),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(Self.item as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = Self.item
                add.merge(update) { _, new in new }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw .unavailable(Self.describe(status))
            }
        }

        /// The attributes that name the item.
        private static var item: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
            ]
        }

        private static func describe(_ status: OSStatus) -> String {
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "no description"
            return "Keychain status \(status): \(message)"
        }
    }
#endif
