---
id: "2026-10.qhsv"
slug: crashes-and-hangs-are-kept
title: "Crashes and hangs are kept on the iPhone and filed by the user"
date: 2026-10-23
topics: [privacy, crash-reports, support]
---

# ADR 2026-10.qhsv — Crashes and hangs are kept on the iPhone and filed by the user

Status: Accepted (2026-10-23)

**Context:** Knit for Android keeps a crash on the phone, redacted. The reporter can copy it, share it, or open a
GitHub bug form filled in from it (knit-next ADR 028, and its ANRs since ADR 2026-10.fzsy). Knit for iOS had none of
this. A crash left the reporter nothing to attach, and `bug_report.yml` could only point at Console.app on a Mac.
Xcode's Organizer gets crashes from TestFlight testers and from App Store users who share analytics with
developers, but only the maintainer sees those, and none of them becomes an issue anyone can follow.

**Decision:** port Android's design, with MetricKit doing the capture and hangs in scope (the maintainer's choices,
2026-10-23). Nothing is sent anywhere unless the user sends it.

- **Capture.** A Swift trap is not an exception, so Android's uncaught-exception handler has no counterpart here.
  `MetricKitCollector`, the only file that imports MetricKit, subscribes in the app delegate once the launch has
  begun. MetricKit is no in-process handler, so subscribing first would catch nothing more, and on a restoration
  relaunch the Bluetooth managers come first (bluetooth-reviewer, 2026-10-23). It reads each `MXCrashDiagnostic` and `MXHangDiagnostic` through MetricKit's typed API into a plain
  `CrashDiagnostic`, and only the call-stack tree crosses over as JSON. Everything after that is `KnitAppCore`,
  tested on Linux. MetricKit hands a diagnostic to the launch after the one that failed, native crashes and
  watchdog kills included. The past payloads are read again at every launch and at the first unlock, because a
  launch before the first unlock cannot write the store. A hang is the iPhone's ANR.
- **Redacted by construction.** A frame is a binary, its UUID, an address and an offset, so no string the app
  wrote reaches one. The free text is the system's: the termination reason, the memory region a bad access
  touched, and an Objective-C exception's name, class and format string. Each passes `CrashRedactor`, Android's
  structural rules with the iPhone's paths. Its base64 rule wants a digit, because Android's ate selector names and
  framework paths. The collector never reads an exception's arguments or the message composed from them, which is
  where a runtime value such as a name would ride. So Android's second pass, over the contact names a phone knows,
  has nothing to do here and is left out.
- **The store.** `CrashStore` keeps one text file per diagnostic in `Application Support/CrashReports`, with the
  database's protection class and out of every backup (ADR 2026-09.nyya). A file's name carries its kind, time
  and fingerprint, and the store never reads a file's own dates, a required-reason API. For the same reason it
  checks no free space: an atomic write that fails loses nothing. It keeps five reports of each kind and two of one
  fingerprint, so a crash loop or a run of hangs never pushes out a report of something else. A hang under a
  second is not kept, a starting value. A list of the keys already imported (`seen`) makes each diagnostic import
  once, and Delete all leaves it, so a deleted report never comes back.
- **The reader.** Foundation's JSON decoder stops at 512 levels of nesting (measured on Linux; Darwin's decoder is
  the same swift-foundation code). Every frame nests an object in an array, so a stack past 255 frames would not
  decode, and a stack overflow is a crash worth reporting. `CallStackReader` reads the tree in one pass without
  recursion, up to 512 frames deep.
- **Reporting is a link, never a post.** Diagnostics shows the newest crash and hang. A report's screen has Report
  on GitHub, Copy, Share and Delete all. Report on GitHub asks first, because an issue is public. It then puts the
  whole report on the clipboard and opens `bug_report.yml` filled in by `CrashIssueURL`, with as much of the report
  as fits in 7,000 encoded characters and the attributed thread first. Steps to reproduce and What you expected
  stay blank, so GitHub refuses the issue until the reporter writes them. The form's ids are now a contract, which
  `CrashIssueURLTests` holds by reading the template. Each report carries Android's `<!-- knit-crash-report -->`
  marker for a triage workflow to find, which this repo does not have yet.
- **Symbolication** happens on the Mac. `scripts/symbolicate.py` finds each UUID's dSYM through `--dsym`, Spotlight
  or Xcode's archives and asks `atos` for each frame. Its tests stub the Mac's tools and run in `check.sh scripts`
  and both CIs.

The alternatives:

- **A signal handler, or PLCrashReporter,** would catch the message `fatalError` prints, which MetricKit does not
  keep. Async-signal-safe code is hard to get right, PLCrashReporter is a dependency, and both race the system's
  own crash reporter. The maintainer chose MetricKit alone.
- **A crash SDK** uploads by itself, which Knit is built not to do. Android ruled it out in ADR 028 for the same
  reason.
- **iOS 27's Swift MetricKit API** (Codable diagnostics, and a `MemoryExceptionDiagnostic` for memory) needs iOS
  27, and the floor is iOS 18 (ADR 2026-09.txqp). Its `CrashDiagnostic` shares our type's name, so
  `MetricKitCollector` writes `KnitAppCore.CrashDiagnostic`.

**Consequences / limits:**

- **Not covered,** and the report's screen names the common case: iOS ending Knit for memory, which MetricKit
  counts but does not report before iOS 27; the share extension, a process of its own; `fatalError`'s message; and
  a process under the debugger, which MetricKit never reports.
- **Delivery may depend on Share iPhone Analytics.** Apple does not say, and developers' reports disagree. The
  device trial should note how the lab iPhone is set.
- **A report is only as readable as its dSYM,** and only the dSYM of the very build that failed will do. Each
  `check.sh archive` or `upload` replaces the Mac's one archive, so it first zips the archive's dSYMs to
  `.build-xcode/dsyms/knit-ios-<version>-<build>-dSYMs.zip`, which no later build touches. CI's `release:testflight`
  keeps that zip as an artifact that never expires, and `symbolicate.py --dsym` reads the zip as it is. The dSYMs
  also go to App Store Connect (`uploadSymbols`), but nobody has checked that they can be downloaded from there.
  1.0.0 (4)'s were gone from the Mac by 2026-10-23; 1.0.0 (5)'s are the first kept.
- **The privacy label stays "Data Not Collected".** The user sends a report from their own browser or share
  sheet, as with an emailed report (ADR 2026-10.tydq).
- **The trap:** the collector must never read an Objective-C exception's `arguments` or `composedMessage`, and a new
  free-text field must pass `CrashRedactor` before it is written. A frame line's shape is read by
  `scripts/symbolicate.py`, and the form's ids by GitHub, so change either with its reader.
- **The guards:** `CrashReportTests`, `CallStackReaderTests`, `CrashRedactorTests`, `CrashStoreTests`,
  `CrashIssueURLTests`, `CrashLogModelTests`, `KnitUITests.walkSettings` (the saved crash and Report on GitHub's
  question, at every size and in dark), `testDeleteAllEmptiesTheSavedReports`, and `scripts/test_symbolicate.py`.
  The device trial, 2026-10-23, on the lab iPhone 12 (iOS 27.0.1, debug build 1.0.0 (5)):
  - **Crash, passed.** The bridge's `crash-now` trapped, iOS started Knit again within a second, and MetricKit handed
    the crash to that launch. The report's time was the crash's, half a second after the bridge's reply. A root frame
    is the innermost call (`libswiftCore`'s trap, then Knit's frames, `dyld`'s start last). The report fit the bug
    form's link whole (6,278 characters), and `symbolicate.py` named Knit's frames against the installed build, frame
    1 as the bridge's own closure.
  - **What it changed.** A debug build keeps the app's code in `Knit.debug.dylib`, which the summary now names, and
    MetricKit lists idle threads with no frames, which a report now says. A second crash on the fixed build showed
    both, and the first report stayed listed once.
  - **Hang, not delivered yet.** A main thread blocked for 3 and for 10 seconds with Knit on screen left no hang in
    MetricKit at the next launch, nor among the phone's crash logs. The last run had the maintainer tapping the frozen
    screen and Settings › Developer › Hang Detection on, whose timer counted the freeze on screen and whose log list then held a spindump
    and a tailspin of it, so iOS recorded that hang. Those logs are Hang Detection's own, kept apart from what
    MetricKit hands an app, and MetricKit had still handed nothing over at the next launch. Knit reads MetricKit's past payloads at every
    launch, so a hang delivered late still lands in Diagnostics; until one does, the path from a hang to a report is
    tested only with `DemoCrash`'s made-up payload. Whether Share iPhone Analytics was on is not known either.
