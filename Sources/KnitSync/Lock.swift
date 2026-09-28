#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// A value that one thread at a time reads and changes, with `Synchronization.Mutex`'s API over a
/// `pthread_mutex_t`.
///
/// On Linux `Mutex` waits on a futex that ThreadSanitizer cannot see, so TSan reported races inside `withLock`
/// bodies that the lock rules out, and the sanitizer gate failed at random. TSan intercepts every pthread call, so
/// it sees this lock take and give (ADR 2026-09.ahrr). Use it wherever `Mutex` would go; SwiftLint's `no_mutex`
/// rule bans `Mutex` everywhere else.
@safe
public final class Lock<Value>: @unchecked Sendable {
    // The mutex lives on the heap, because a pthread mutex must never move and a stored property has no stable
    // address. `init` and `deinit` own it, and nothing else holds the pointer.
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    // Read and written only between lock and unlock, which is what makes the class Sendable.
    private var value: Value

    /// A lock around `initialValue`.
    public init(_ initialValue: sending Value) {
        unsafe mutex = UnsafeMutablePointer.allocate(capacity: 1)
        unsafe mutex.initialize(to: pthread_mutex_t())
        unsafe pthread_mutex_init(mutex, nil)
        value = initialValue
    }

    deinit {
        unsafe pthread_mutex_destroy(mutex)
        unsafe mutex.deinitialize(count: 1)
        unsafe mutex.deallocate()
    }

    /// Runs `body` on the value, holding the lock until it returns or throws.
    public func withLock<Result: ~Copyable, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
    ) throws(Failure) -> sending Result {
        unsafe pthread_mutex_lock(mutex)
        defer { unsafe pthread_mutex_unlock(mutex) }
        return try body(&value)
    }
}
