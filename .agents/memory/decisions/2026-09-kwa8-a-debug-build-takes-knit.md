---
id: "2026-09.kwa8"
slug: a-debug-build-takes-knit
title: "a debug build takes knit-peer's commands over USB"
date: 2026-09-26
topics: [interop, testing, app]
---

# ADR 2026-09.kwa8 — a debug build takes knit-peer's commands over USB

Status: Accepted (2026-09-26)

**Context:** the first iPhone runs were checked by hand. The debug log carries link events and nothing about
messages, so every room post, DM and tick needed someone to read the phone, or a read-only mount of the app's
database. Android has knit-next's debug bridge (`am broadcast`), and the Linux peer takes JSON lines on standard
input, but nothing on Linux can send an iPhone app a command: `xtool launch` fails on iOS 27, and XCUITest needs
the Mac. A spike on 2026-09-26 found that usbmuxd, which xtool already uses, reaches a TCP listener on the phone's
own loopback. The connection arrives from `127.0.0.1`, a two-line exchange takes 4 to 6 ms, and iOS asks for no
Local Network permission.

**Decision:** a debug build listens on `127.0.0.1:5648` and speaks `knit-peer`'s control protocol. A computer
reaches it over USB with `iproxy 5648:5648`.

- **One protocol for both nodes.** The command parser, the replies and the event lines moved out of `KnitPeer`
  into a platform-free `KnitControl` target (`MeshControl`), which `knit-peer` and the app both use. A script
  drives the iPhone with the code that drives the peer. The protocol gained `stop` and `start` for the app's
  Stop and Start.
- **Commands take the path a tap takes.** In the app, `MeshControl` changes the node through the session
  (`ControlActions`), so a bridged post or Accept shows on screen and clears notifications as a tap would. Reads,
  and `deny-link`, go to the mesh.
- **Events are pushed.** The session hands every mesh event on through `AppSession.eventTap`, since the mesh
  has one event stream and the session consumes it. Every connection hears `link`, `profile`, `message`, `sent`,
  `delivered` and `radio` as they happen, where Android's bridge is polled.

The alternatives were command files dropped into the app's container over AFC, which the spike also proved but
which would need polling, and pymobiledevice3, which can launch apps and take screenshots but needs root and
Apple's developer disk image.

**Consequences / limits:**

- **The listener exists only in a debug build** (`#if DEBUG`), and only on loopback, so only a computer on the
  USB cable reaches it. Using it counts as driving the phone (`.agents/rules/devices.md`).
- **Knit has to be running.** Nothing here opens it: someone opens Knit after each install or crash. A
  suspended Knit answers nothing until it resumes, and then answers what waited. iOS may take the listening
  socket back during a long suspension, so the app listens again at every foreground.
- **It checks the mesh and the store, not the screens.** What the UI shows is left to XCUITest on the Mac.
- **Guards.** `MeshControlTests` covers the session path, `stop`, `start` and the event lines. `PeerNodeTests`
  covers the protocol through the peer. `SessionTests`' `theTapHearsEveryEventAfterTheSession` covers the tap.
  The listener itself has no test until the Mac, and is checked on the iPhone.
