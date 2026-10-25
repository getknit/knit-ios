import Foundation
public import KnitWire
public import Observation

/// How far a photo streaming in has got, as its bubble shows it (`ArrivingFile` and `ArrivalIndicator` in knit-next,
/// ADR 2026-10.y9qh): the bytes in so far, and the size its sender's header declared, when it declared one.
public struct PhotoArrival: Sendable, Equatable {
    /// The bytes in so far.
    public var bytes: Int
    /// The size the header declared: the peer's claim, a label and never a bound.
    public var total: Int?

    /// An arrival of `bytes` out of `total`.
    public init(bytes: Int, total: Int?) {
        self.bytes = bytes
        self.total = total
    }

    /// `reading` as a bubble shows it.
    public init(_ reading: FileIntake.Reading) {
        self.init(bytes: reading.bytes, total: reading.total)
    }

    /// The share in, from 0 to 1, or `nil` without a total, or once the bytes overrun it (`ArrivingFile.fraction`): a
    /// sender that sends more than it declared is shown by its count alone.
    public var fraction: Double? {
        guard let total, total > 0, bytes <= total else {
            return nil
        }
        return Double(bytes) / Double(total)
    }

    /// The line under the ring: "84 kB of 204 kB", or "84 kB received" with no share to show.
    public var caption: String {
        let received = Self.size(bytes)
        guard fraction != nil, let total else {
            return Copy.Attachments.photoArrivingBytes(received: received)
        }
        return Copy.Attachments.photoArriving(received: received, total: Self.size(total))
    }

    /// The arrival once its bytes are all in: what a photo stored before its row redraws shows, so the bubble never
    /// steps back to its waiting line in between.
    var whole: Self {
        let size = max(bytes, total ?? 0)
        return Self(bytes: size, total: size)
    }

    /// `bytes` as Files and Finder write a file's size, in the current locale.
    private static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}

/// The photos streaming in now, by the hash a message names (`ChatViewModel.arrivals` in knit-next). It moves no
/// session revision, so a ring that moves twice a second rebuilds no rows: only the bubbles that read it draw again.
@preconcurrency
@MainActor
@Observable
public final class PhotoArrivals {
    /// Each arrival, by its blob's hash.
    public internal(set) var byHash: [BlobHash: PhotoArrival] = [:]
    /// The photos stored since the last sample and held whole through this one (``AppSession/sampleArrivals()``).
    @ObservationIgnored var heldOver: Set<BlobHash> = []

    /// No photo streaming in.
    public init() {
        // Nothing arrives yet.
    }

    /// How far `hash` has got, or `nil` while no link brings its bytes.
    public subscript(hash: BlobHash) -> PhotoArrival? {
        byHash[hash]
    }
}
