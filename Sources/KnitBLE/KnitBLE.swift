#if canImport(CoreBluetooth)
    import CoreBluetooth

    /// The CoreBluetooth radio (P6). This target is the only importer of CoreBluetooth.
    internal enum KnitBLE {
        /// The presence service knit-next advertises under (`BleConstants.SERVICE_UUID`). `CBUUID` is not
        /// `Sendable`, so it is built where it is used rather than stored in a global.
        static var serviceUUID: CBUUID { CBUUID(string: "FE30") }
    }
#endif
