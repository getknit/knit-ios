# Knit for iOS

Message the people around you when there is no network at all, from an iPhone. Knit for iOS is the iPhone
port of [Knit](https://github.com/getknit/knit), the offline mesh messenger for Android, and it talks to
Android phones directly over Bluetooth LE.

> [!NOTE]
> Knit for iOS is in early development and has no release yet. The first milestone is an iPhone and an
> Android phone exchanging Nearby-room posts and direct messages as peers on the same mesh.
> [`.agents/specs/mvp.md`](.agents/specs/mvp.md) lists what that has to prove.

## How it works

Phones in range link up over Bluetooth LE and pass each message from one to the next, so it can reach
people you were never in range of yourself. There is no server, no account and no phone number. A phone
that meets someone later hands over what it was carrying for them.

- **Direct messages are end-to-end encrypted.** The phones that carry a direct message cannot read it. The
  first release uses Knit's static-key scheme, which has no forward secrecy; the epoch ratchet that Knit
  for Android already runs comes next.
- **The Nearby room is open to everyone in range.** Posts are signed, so nobody can post as you, but they
  are not encrypted.
- **It meshes with Android.** An iPhone speaks the same protocol as Knit for Android and relays for Android
  phones the way they relay for each other. Knit for Android also meshes over Wi-Fi Aware, LoRa boards and
  internet relays, and an iPhone reaches those parts of the mesh through the Android phones around it.
- **Knit finds new people while it is open.** iOS can keep an app's open Bluetooth links running in the
  background, but it doesn't let other phones discover the app there. Direct messages meant for you wait
  on the phones around you, for up to a day, until you are back in range with Knit open.

## Build

Knit for iOS is one Swift package. The protocol code builds and tests on Linux and macOS. On Linux, the
app itself builds with [xtool](https://github.com/xtool-org/xtool); on a Mac it builds with Xcode.

You need Swift 6.4 (`.swift-version`), plus `libdbus-1-dev` and `pkg-config` on Linux.

```sh
git config core.hooksPath .githooks   # sign-off, lint and ADR checks on every commit
scripts/check.sh fast                 # format, lint, build and unit tests
scripts/check.sh all                  # every gate that runs on Linux, sanitizers included
xtool dev build                       # the iOS app, into xtool/Knit.app
```

On Linux, the Darwin SDK that xtool installs needs one repair before it can build: run
`scripts/xtool-sdk-fixup.sh` after `xtool sdk install`. [`.agents/context/toolchain.md`](.agents/context/toolchain.md)
explains why, and lists every tool and version the gates use.

## Contributing

Start with [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributors and coding agents both begin at
[`AGENTS.md`](AGENTS.md), which routes to the rules, reference and decisions in [`.agents/`](.agents/).
The decisions behind the design are indexed in
[`.agents/memory/decisions.md`](.agents/memory/decisions.md).

## Security

Please report vulnerabilities privately, as [`SECURITY.md`](SECURITY.md) describes. It also lists the
limits that are known and deliberate.

## License

Copyright (C) 2026 Jeffrey Walter Mixon

Knit for iOS is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
option) any later version, with the additional permission in
[`APP-STORE-EXCEPTION.md`](APP-STORE-EXCEPTION.md) for distribution through app stores.

Knit for iOS is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
for more details. You should have received a copy of the GNU General Public License along with this
program; see [`COPYING`](COPYING). If not, see <https://www.gnu.org/licenses/>.

Third-party components and their licenses are listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
