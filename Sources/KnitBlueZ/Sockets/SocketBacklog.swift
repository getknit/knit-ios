import KnitMesh
import KnitSync

/// What an L2CAP socket has taken from the loop and not yet sent: the buffer below the link, which the
/// `custody-carry-policy` contract counts as unwritten (§2, "Unwritten"; §9, "The iPhone doesn't count the buffer below
/// its link yet"). The loop counts a byte written once `send` takes it (``OutboxLevels``), and on `hci1` the socket can
/// then hold minutes of digests (`.agents/context/linux-peer.md`, "Why the frames were late"), which a reply round read
/// as drained would queue behind.
///
/// The kernel is read as `bt_sock_ioctl` is written (`net/bluetooth/af_bluetooth.c`), not yet as a run on `hci1` showed
/// it: `TIOCOUTQ` answers the free space, `sk_sndbuf` less `sk_wmem_alloc` and at least 0, and `SO_SNDBUF` answers
/// `sk_sndbuf`, so what the socket holds is their difference. That counts each buffer's whole allocation, not its
/// payload, so it reads high, which only makes custody's line cautious. A buffer charged past `sk_sndbuf` reads as the
/// whole buffer, low by the excess.
internal enum SocketBacklog {
    /// The bytes held below the link, from `SO_SNDBUF` (`sendBuffer`) and `TIOCOUTQ` (`freeSpace`), each `nil` when its
    /// call failed. Any answer that cannot be the kernel's (a failed call, a buffer of 0 or less, free space below 0 or
    /// past the buffer) counts nothing, so the outbox alone is counted, as before the read: a misread never holds a
    /// round off.
    static func bytes(sendBuffer: Int32?, freeSpace: Int32?) -> Int {
        guard let sendBuffer, let freeSpace, sendBuffer > 0, freeSpace >= 0, freeSpace <= sendBuffer else {
            return 0
        }
        return Int(sendBuffer - freeSpace)
    }
}

/// Every open channel's socket, as the loop holds it, so ``Mailbox/level(on:)`` reads the buffer below it from any thread,
/// at once, fresh at each read (``Radio/outboxLevel(on:)``, ADR 2026-10.f5zs).
///
/// The read runs on the caller's thread, under this lock, and the loop takes the same lock to forget a channel before it
/// closes the socket, so a read never lands on a descriptor the kernel has handed to another socket. The two calls are
/// a `getsockopt` and an `ioctl` that answer from the socket's counters without waiting on the radio. Sampling on the
/// loop instead would go stale while it waits in `poll` for its idle second, with nothing left to write and the kernel
/// draining, and custody looks every 100 ms. The lock is `KnitSync`'s (ADR 2026-09.ahrr).
internal final class SocketBacklogs: Sendable {
    private let sockets = Lock<[ChannelID: Int32]>([:])
    private let read: @Sendable (Int32) -> Int

    /// Reads each socket with `read` (``SocketProvider/queuedBelow(_:)``).
    init(read: @escaping @Sendable (Int32) -> Int) {
        self.read = read
    }

    /// `id` is open on `descriptor`: from now its buffer is read.
    func watch(_ id: ChannelID, descriptor: Int32) {
        sockets.withLock { $0[id] = descriptor }
    }

    /// `id`'s socket is about to close: no read reaches it from here.
    func forget(_ id: ChannelID) {
        sockets.withLock { $0[id] = nil }
    }

    /// What `id`'s socket holds below the link, never below 0; 0 for a channel not watched.
    func bytes(on id: ChannelID) -> Int {
        sockets.withLock { sockets in
            sockets[id].map { max(0, read($0)) } ?? 0
        }
    }
}
