---
id: "2026-10.ab6k"
slug: the-lab-s-hardware-addresses
title: "The lab's hardware addresses and hosts live in a private env file, not the repository"
date: 2026-10-11
topics: [peer, devices, build]
---

# ADR 2026-10.ab6k — The lab's hardware addresses and hosts live in a private env file, not the repository

Status: Accepted (2026-10-11)

**Context:** the repository is going public on GitHub. Its code and scripts named the lab by its real identifiers:
the Bluetooth addresses of the two nRF52840 dongles, the retired ATS2851 and Edimax, and the maintainer's own Intel
adapter, which carries their keyboard and speaker and can be tracked over the air; the dongles' USB serials; the
Mac's LAN host name; the build machines' names; and the Apple Team ID in `.gitlab-ci.yml`. `knit-peer` defaulted to
dongle A's address, `AdapterSelection` refused the Intel by a constant, `interop.py` and `knit-hci.sh` hard-coded
the dongles, and `mac.sh` defaulted to the Mac's host. None of it is secret the way a key is, but none of it helps a
contributor, and an adapter address identifies a person's machine for as long as they own it.

**Decision:** the identifiers live outside the repository. `.private/lab.env`, which git ignores, holds KEY=VALUE
lines: `KNIT_ADAPTER_A`, `KNIT_ADAPTER_B`, `KNIT_ADAPTER_ATS2851`, `KNIT_ADAPTER_EDIMAX`, `KNIT_ADAPTER_RESERVED`
(comma-separated) and `KNIT_MAC_HOST`. The environment wins over the file.

- `knit-peer` takes its default adapter from `KNIT_ADAPTER_A` and its reserved adapters from
  `KNIT_ADAPTER_RESERVED`. With neither `--adapter-address` nor the variable, the BlueZ host refuses to start and
  says which to set; the Mac's CoreBluetooth host needs no address, so parsing does not fail there.
- `AdapterSelection` takes the reserved set from its caller and reserves nothing by default, so its tests inject a
  fake address and never read the host's environment.
- `interop.py` loads the file into its environment, so every `knit-peer` it starts inherits the adapters, and exits
  naming the variable when one a run needs is missing. `mac.sh` reads `KNIT_MAC_HOST` the same way.
- `knit-hci.sh` and `hci1-supervision.sh` run as root through sudo or udev, which give them no environment. They read
  `/etc/knit-hci.conf` (`a`, `b` and `ats2851`, one `NAME ADDRESS` line each) and refuse it unless root owns it and
  nobody else can write it, which keeps the guarantee that sudo only ever reaches Knit's own adapters.
  `.private/knit-hci.conf` is the copy to install.
- The signing jobs read `KNIT_DEVELOPMENT_TEAM` from a masked CI/CD variable on the GitLab project.
- The tests use made-up addresses that keep the originals' address-type bits.

The first alternative is to leave the values in and rely on their being harmless. That works for the Team ID, which
every signed app carries, but not for the Intel's address. The second is a committed config file with placeholders,
which leaves the real file one careless `git add` from public; `.private/` is ignored as a whole already.

**Consequences / limits:** a fresh clone cannot run an interop script or `mac.sh` until someone writes
`.private/lab.env`, and the error says so. Installing `knit-hci` now also needs
`sudo install -o root -g root -m 0644 .private/knit-hci.conf /etc/knit-hci.conf`. History before this decision still
holds the old values; this ADR does not rewrite it. `PeerOptionsTests.theEnvironmentNamesTheDefaultAndReservedAdapters`,
`BlueZModelTests.nothingIsReservedUnlessTheCallerSaysSo` and the reserved-adapter tests keep the wiring true.
