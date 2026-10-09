import KnitCrypto
import KnitMesh
import KnitSync
import KnitWire

// The pictures a ``FakeMesh`` already holds (ADR 2026-10.f3mv), apart so `AppRig.swift` stays inside the lint's length.
extension FakeMesh {
    /// Holds `photo` as what a pick of `picked` finds (``heldPhoto(picked:)``).
    func hold(_ photo: OutgoingPhoto, pickedAs picked: [UInt8]) {
        held.withLock { $0[BlobHash(of: picked)] = photo }
    }

    func heldPhoto(picked: [UInt8]) -> OutgoingPhoto? {
        held.withLock { $0[BlobHash(of: picked)] }
    }
}
