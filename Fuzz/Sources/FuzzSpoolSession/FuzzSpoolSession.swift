@_spi(Fuzz) import KnitMesh

/// Arbitrary bytes as a script for one spool connection and its heal loop (ADR 2026-11.adrq, P4b1): arbitrary records off a
/// spool, ticks at any `Int64` clock, the harness's own `sub`, `list`, `pull` and `push`, closes and stamp answers with a
/// session and without one. ``SpoolSessionFuzz`` checks its invariants after every step; nothing traps.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzSpoolSession(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    _ = SpoolSessionFuzz.run(Array(unsafe UnsafeBufferPointer(start: data, count: count)))
    return 0
}
