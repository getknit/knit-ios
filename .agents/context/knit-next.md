# knit-next, the source of truth

Knit for Android lives in `~/source/knit-next` on the maintainer's machine (origin
`source.jeffmixon.com/knit/knit-next`, public mirror `github.com/getknit/knit`). Everything this repo
puts on the air has to match what that code does, byte for byte. When a doc and the Kotlin disagree, the
Kotlin wins.

## The pinned reference

- Release `v2.7.0` is commit `7e73e891`. The port started from HEAD `02051b64`, five test-only commits
  later, on 2026-09-25.
- The `.agents/context/` files in this repo (`wire-format.md`, `ble-transport.md`, `crypto.md`,
  `custody.md`) were read from that tree. Moving the pin means re-reading the files below and updating
  those four, in the same change.

## Where to look

All paths are under `app/src/main/java/app/getknit/knit/` unless they start with `docs/` or `app/src/test`.

| Question | Kotlin |
| --- | --- |
| What the advert, the L2CAP link and the handshake look like | `mesh/bluetooth/BluetoothMeshTransport.kt`, `BleAdvertPayload.kt`, `BleAdvertiser.kt`, `BleScanner.kt`, `BleConstants.kt`, `mesh/link/LinkFraming.kt`, `LinkHandshake.kt`, `FramedLink.kt` |
| Who dials, who gets promoted, how long to back off | `mesh/bluetooth/PromotionPolicy.kt`, `ConnectBackoffPolicy.kt`, `BlePresenceTracker.kt` |
| The CBOR envelope and every payload type | `mesh/protocol/Wire.kt`, `Protocol.kt`, `FrameId.kt`, `CanonicalText.kt` |
| Keys, node ids, DM sealing, safety numbers, aliases | `mesh/crypto/PublicKeyBundle.kt`, `MessageCrypto.kt`, `SafetyNumber.kt`, `identity/NodeId.kt`, `Alias.kt`, `AliasWords.kt` |
| Flooding, dedup, custody, sync, receipts, key recovery | `mesh/MeshRouter.kt`, `SeenSet.kt`, `ForwardSync.kt`, `data/forward/ForwardRepository.kt`, `mesh/InboundPipeline.kt`, `MeshManager.kt`, `AckSync.kt`, `KeyExchange.kt`, `PendingInbound.kt`, `IngressBudget.kt` |
| Byte-exact fixtures | `vectors/` from A2 on (`wire-v1.json`, `keyed-v1.json`, `ios-emitted-v1.json`; `vectors/README.md`), checked by `mesh/protocol/GoldenVectorTest`, `KeyedVectorTest` and `IosEmittedVectorTest`. Before A2, `GoldenVectorTest.kt` held the 57 fixtures as inline hex. Also `NodeIdTest.kt`, `AliasTest.kt` |
| The additive-change rules | `docs/WIRE_COMPAT.md`, `docs/NEXT_WIRE_BREAK.md` |

## Docs that are out of date

Read these for design reasons, never for bytes:

- `docs/IOS_PORT_REVIEW.md` describes the pre-launch wire. Its node id scheme (`knit-node-id-v1:`, 8
  bytes mapped `% 36`), its 16-byte advert with a version byte, its one-way HELLO, its 64 KiB file chunks
  and its Tink-prefixed signatures were all replaced before v1.
- `docs/ARCHITECTURE.md` says the L2CAP link is encrypted. The code opens insecure channels; trust comes
  from the per-frame signature and the end-to-end layer.
- `docs/NEXT_WIRE_BREAK.md` gives the database version as 11. The code is at 15.

Companion change A2 corrects the first two; until it merges, the corrections exist only on its branch.

## Companion changes (Track A)

Changes this port needs in knit-next. They follow knit-next's own `AGENTS.md`: its ADR tooling, changelog
gate, mesh-lab rules and wire-compatibility rules. Status lives in `.agents/memory/roadmap.md`.

- **A1:** Android's responder accepts a HELLO from a dialer it never sighted, whatever the node id order;
  it replaces a stale link from such a dialer; teardown removes a link only if it is still the registered
  one; an unsighted link scores −90 dBm rather than −127. Without A1, an iPhone links to an Android phone
  only when the iPhone's node id sorts higher.
- **A2:** the golden vectors move into a JSON file that `GoldenVectorTest` reads, joined by keyed vectors
  (fixed identities, signed frames, a sealed v1 DM, the safety number, advert, HELLO, DIGEST and FNV hex)
  and a test that checks fixtures this repo emits.
- **A3:** Android finds and dials iPhones: it reads the `0xFE30` GATT payload from an advert that carries
  no service data, sets `FLAG_DIALS_GATT_PEERS`, and adds a UUID list to its scan response.
