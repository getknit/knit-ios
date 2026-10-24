/// The wall clock a pure blob test reads beside its monotonic `now`, from another base as ``ManualClock``'s two are: a
/// deadline compared with the monotonic clock, or a streak's start compared with the wall one, then reads wrong (ADR
/// 2026-10.8hek). `EngineFixture.start` is two days into 2025, so a deadline of 0 is long past.
func wallAt(_ monotonic: Int64) -> Int64 {
    EngineFixture.start + monotonic
}
