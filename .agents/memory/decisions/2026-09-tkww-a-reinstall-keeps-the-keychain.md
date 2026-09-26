---
id: "2026-09.tkww"
slug: a-reinstall-keeps-the-keychain
title: "a reinstall keeps the Keychain identity and republishes its profile"
date: 2026-09-26
topics: [identity, storage, app]
---

# ADR 2026-09.tkww — a reinstall keeps the Keychain identity and republishes its profile

Status: Accepted (2026-09-26)

**Context:** the identity's private keys live in the Keychain, as `…AfterFirstUnlockThisDeviceOnly`
(`.agents/context/architecture.md`), and the database lives in the app's container (ADR 2026-09.nyya). On iOS
a Keychain item outlives the app: deleting Knit removes the database, the preferences and the container, and
leaves the keys. So a reinstall finds an identity with nothing around it: no peers, no threads, no accepted
conversations, and an own profile back at version 0 with no publish stamp. Android has no such case, because an
uninstall deletes `identity.key` with the rest of the app's data, and the next install is a new node.

Two ways were open. Keep the surviving identity, or notice the reinstall (the preferences are gone while the
Keychain item is not) and delete the item, so a reinstall starts as a new node, as it does on Android.

**Decision:** a reinstall keeps the identity it finds.

- **What keeping buys.** The node id is the identity. Peers who verified this phone's safety number still
  hold a verification that is true. DMs sealed to this key while the app was gone still open when custody
  serves them. A contact's thread carries on under the same name instead of a stranger turning up.
- **Onboarding always publishes the profile**, with a name or without one (`OnboardingModel.finish`). A
  reinstall always shows onboarding, since the preference that skips it went with the app. The publish moves
  the profile's version to `max(now, version + 1)`, past any version a peer holds, so the phone takes its
  presentation back. Without it, peers would keep showing the old profile, and a blank republish at version 0
  would never outrank it.
- **The item never leaves the phone.** `ThisDeviceOnly` keeps it out of backups and device transfers. A new
  phone set up from a backup starts a new identity, which is the case Android's "also active on another
  phone" banner exists for, and it cannot arise here.
- **Reading before the first unlock is not a missing identity.** `IdentityKeys.load` throws when the store
  cannot answer, and the app then waits for protected data rather than minting keys. The database is under
  the same protection class, so nothing can run before that first unlock anyway.

**Consequences / limits:**

- **The user cannot reset their identity by reinstalling.** A person who wants a fresh node id needs a way to
  ask for one. Android's "Sign out here" is the model, and it is not in the MVP.
- **What the old install stored is gone for good.** Only what peers still carry comes back: DMs to this
  phone, room posts under 6 hours old, and profiles through the digest exchange.
- **An xtool install and an Xcode-signed build are different apps to the Keychain** (`XTL-` bundle prefix), so
  switching between them is a new identity, not a reinstall (`.agents/context/toolchain.md`).
- **Guards:** `OnboardingAndSettingsTests.finishingPublishesTheProfileEvenBlankStartsTheMeshAndIsRemembered`
  keeps the blank publish. `IdentityTests` keeps a store that cannot answer from minting keys. The Keychain
  store itself runs only on Apple platforms, so it waits for the Mac's test job (P7).
