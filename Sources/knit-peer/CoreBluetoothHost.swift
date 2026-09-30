#if os(macOS)
    import KnitBLE
    import KnitMesh
    import KnitPeer

    /// The Mac peer's radio: CoreBluetooth through `KnitBLE`, the iPhone's own radio (ADR 2026-09.vcdk). A Mac cannot
    /// advertise service data any more than an iPhone can, so it always runs the `ios` profile: the `0xFE30` UUID in
    /// its advert, its payload over GATT, and a doorbell. It must run in the desktop session, where macOS can ask for
    /// Bluetooth; from ssh CoreBluetooth reports it unauthorized (`scripts/mac-desktop.sh --stdio`).
    /// This platform's peer radio.
    internal typealias PeerHost = CoreBluetoothHost

    internal struct CoreBluetoothHost: PeerRadioHost {
        let radio: any Radio
        let profile = "ios"
        private let bluetooth: BLERadio

        /// The CoreBluetooth radio. The adapter options are BlueZ's and mean nothing here, so they are ignored; a
        /// profile or MTU it cannot honour is refused.
        init(_ options: RunOptions, log: any KnitLog) throws(PeerHostError) {
            if let asked = options.radioProfile, asked != profile {
                throw .unsupported("--radio-profile \(asked): CoreBluetooth advertises as an iPhone does, so the Mac runs ios")
            }
            if options.receiveMTU != nil || options.sendMTU != nil {
                throw .unsupported("--receive-mtu and --send-mtu: CoreBluetooth picks a channel's MTU itself")
            }
            if !options.neverSighted.isEmpty || !options.servesGattPayload || !options.readsGattPayloads {
                throw .unsupported("--never-sight, --no-gatt-payload and --no-gatt-reads: they are BlueZ's test switches")
            }
            bluetooth = BLERadio(log: log)
            radio = bluetooth
        }

        func shutdown() {
            bluetooth.stop()
        }

        /// `scan` drives BlueZ directly, so it runs on Linux.
        static func scan(_: ScanOptions) {
            KnitPeerMain.fail("scan runs on the Linux peer; on a Mac, run the node and read its `peers`")
        }
    }
#endif
