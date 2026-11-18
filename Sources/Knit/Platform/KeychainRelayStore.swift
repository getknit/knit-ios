#if os(iOS)
    // A debug build's alone while the spool plane is (ADR 2026-11.adrq): a store build keeps no relay address.
    #if DEBUG
        import Foundation
        import KnitAppCore
        import KnitMesh
        import Security

        /// Internet relays' addresses and the install's consent nonce in the Keychain (ADR 2026-11.adrq, P6): one
        /// generic-password item per relay, under a service of its own and the relay's handle in decimal as the account, and
        /// one for the nonce, account `consent`, each never synchronised and readable after the first unlock on this phone
        /// alone (`…AfterFirstUnlockThisDeviceOnly`, ADR 2026-09.tkww), set on every add and update. A private relay's token is
        /// its whole access control, and the preferences are backed up, so no address is kept anywhere else. Apart from the
        /// identity's ``KeychainSecretStore``: a relay can never read or replace the identity's item. A failure logs its bare
        /// status alone, never the query, the account or what the item holds.
        internal struct KeychainRelayStore: RelaySecretStore {
            /// The items' service. `scripts/check.sh release` fails when a release build holds it: it would mean relay
            /// addresses are kept in a store build.
            static let service = "app.getknit.knit.spool-relay"
            /// The consent nonce's account, which no handle's decimal account can be.
            static let consentAccount = "consent"

            let log: any KnitLog

            func read(_ handle: Int) throws(RelaySecretError) -> String? {
                try read(account: String(handle))
            }

            func write(_ handle: Int, _ address: String) throws(RelaySecretError) {
                try write(address, account: String(handle))
            }

            func delete(_ handle: Int) throws(RelaySecretError) {
                try delete(Self.item(String(handle)))
            }

            func readConsent() throws(RelaySecretError) -> String? {
                try read(account: Self.consentAccount)
            }

            func writeConsent(_ nonce: String) throws(RelaySecretError) {
                try write(nonce, account: Self.consentAccount)
            }

            func deleteConsent() throws(RelaySecretError) {
                try delete(Self.item(Self.consentAccount))
            }

            /// Every item under the service, the nonce's included, synchronised or not: no install of Knit writes a
            /// synchronised one, and the sweep leaves none either way.
            func deleteAll() throws(RelaySecretError) {
                try delete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.service,
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                ])
            }

            private func read(account: String) throws(RelaySecretError) -> String? {
                var query = Self.item(account)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    guard let data = result as? Data else {
                        throw failed("read", status)
                    }
                    // Bytes that are no UTF-8 read as text the factory refuses: the row says this build can't use it.
                    return String(bytes: data, encoding: .utf8) ?? ""
                case errSecItemNotFound:
                    return nil
                default:
                    throw failed("read", status)
                }
            }

            private func write(_ text: String, account: String) throws(RelaySecretError) {
                let update: [String: Any] = [
                    kSecValueData as String: Data(text.utf8),
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                var status = SecItemUpdate(Self.item(account) as CFDictionary, update as CFDictionary)
                if status == errSecItemNotFound {
                    var add = Self.item(account)
                    add.merge(update) { _, new in new }
                    status = SecItemAdd(add as CFDictionary, nil)
                }
                guard status == errSecSuccess else {
                    throw failed("write", status)
                }
            }

            private func delete(_ query: [String: Any]) throws(RelaySecretError) {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw failed("delete", status)
                }
            }

            /// The failure of a `what`, logged as the bare status the Keychain answered.
            private func failed(_ what: String, _ status: OSStatus) -> RelaySecretError {
                log.log(.warning, "relay keychain \(what) failed: status \(status)")
                return RelaySecretError()
            }

            /// The attributes that name `account`'s item.
            private static func item(_ account: String) -> [String: Any] {
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrSynchronizable as String: false,
                ]
            }
        }
    #endif
#endif
