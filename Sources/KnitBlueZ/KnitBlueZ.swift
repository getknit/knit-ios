#if os(Linux)
    import CBluetoothShim
    import CDBus

    /// The BlueZ radio for the headless Linux peer (P4). This target is the only importer of CDBus.
    public enum KnitBlueZ {
        /// The libdbus version this build links, as `major.minor.micro`. Proves the pkg-config target resolves.
        public static func libdbusVersion() -> String {
            var major: Int32 = 0
            var minor: Int32 = 0
            var micro: Int32 = 0
            dbus_get_version(&major, &minor, &micro)
            return "\(major).\(minor).\(micro)"
        }

        /// `sockaddr_l2`'s size, which the socket calls pass to the kernel.
        public static let sockaddrL2Size = MemoryLayout<knit_sockaddr_l2>.size
    }
#endif
