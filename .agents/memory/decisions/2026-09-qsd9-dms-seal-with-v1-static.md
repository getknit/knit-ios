---
id: "2026-09.qsd9"
slug: dms-seal-with-v1-static
title: "DMs seal with v1 static keys until the ratchet lands"
date: 2026-09-25
topics: [crypto, dm, interop]
---

# ADR 2026-09.qsd9 — DMs seal with v1 static keys until the ratchet lands

Status: Accepted (2026-09-25)

**Context:** knit-next seals a DM with one of three schemes. v1 wraps a fresh AES-256-GCM key to the
recipient's static X25519 key with HPKE. v2 and v3 are an epoch-rekey ratchet with an X3DH bootstrap, which
Android uses only toward a peer whose profile advertises `CAP_RATCHET`. The ratchet is the larger half of
the crypto: session races, resets and retention rules, 31 behavioural scenarios in `RatchetEngineTest`, and
no keyed vectors to port against. v1 is about 100 lines of `MessageCrypto.kt`, and every knit-next build
since launch reads it.

**Decision:** the MVP seals and opens v1 only, and advertises capabilities `0x9` (end-to-end and
store-and-forward), never `CAP_RATCHET`, so Android keeps sealing v1 toward the iPhone. A v2 or v3 envelope is
still decoded, relayed and carried, then dropped locally. Porting the ratchet first would hold the MVP behind
the largest piece of work with the least to test it against. Shipping without DMs would leave nothing
private to test the mesh with.

**Consequences / limits:** v1 has no forward secrecy. Whoever later takes a device's X25519 key can open
every v1 DM ever sent to it, which `SECURITY.md` says in plain words, and no copy may claim otherwise. The
ratchet is the next milestone and comes before any public build (`.agents/memory/roadmap.md`); it starts by
adding keyed vectors to knit-next. `LinkTests` pins the advertised capabilities to `0x9`, and
`MessageCryptoTests` covers the v1 seal and open, including the low-order keys Tink refuses and swift-crypto
would not.
