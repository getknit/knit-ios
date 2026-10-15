# Identity and end-to-end crypto

How knit-next derives identities and seals DMs at the pinned commit. This port seals the v1 scheme only
(ADR router: `.agents/memory/decisions.md`). The ratchet (v2, v3 and the group form) is being ported dark behind a
switch, and the last section is its reference (ADR 2026-10.5sk9). The `crypto-owner` reads it before it writes and
the `crypto-reviewer` before it judges (`.agents/rules/owners.md`).

## Keys

- **X25519 identity key** (`hpkePub`): v1 HPKE, and later the X3DH identity key.
- **Ed25519 signing key** (`sigPub`): every frame signature, and the signed prekey's signature.
- **Signed prekey:** the ratchet's only; it rides `ProfileContent.prekey`. This port publishes none while the
  ratchet's switch is off ("The ratchet", below).

Android keeps the private keys in a file wrapped by AndroidKeyStore, outside the database, so a database
wipe keeps the identity. On iOS they live in the Keychain as `…AfterFirstUnlockThisDeviceOnly`.

## The public key bundle

The wire form, and the pinned form, is standard padded base64 (112 characters) of this exact 84-byte
definite-length CBOR map, `sigPub` first:

```text
A2 66 "sigPub" 58 20 <32 bytes>  67 "hpkePub" 58 20 <32 bytes>
```

It rides `ProfileContent.pubKey`. A peer pins it verbatim, and once pinned it never changes: a different
key for a known node id is refused. Contact cards rebuild the bundle from raw keys, so our encoding must be
byte-identical or a card import fails its id check.

## Node id

```text
nodeId = base32lower_nopad( SHA-256( UTF-8("knit-node-id-v2:" + bundleBase64) )[0..<16] )
```

That is 128 bits in 26 characters of `[a-z2-7]` (RFC 4648 alphabet, lowercase). The hash input is the
base64 text, not the key bytes. The last character is always one of `a e i m q u y 4`, because two
padding bits are zero; a canonical id is one that round-trips. The advert carries the raw 16 bytes.

Goldens: `NodeIdTest` pins `derive("android-id-123") = ffbbh6thbepahqxsv2gqog45m4` and
`derive("") = wnuon3pfxkl6auzh2ngvinfc3i` (arbitrary seed strings). `GoldenVectorTest`'s bundle probe gives
`cswad43wmlont27jr4tyvu63i4`. The contact-card identity (Ed25519 seed `bytes(32, 1)`, X25519 scalar
`bytes(32, 2)`) gives `4cgq2pnhh6p3j3afwsue3chrpi`.

## Signatures

Ed25519 over the `signed` bytes, 64 bytes, no prefix. CryptoKit on Apple platforms randomizes Ed25519
signatures, and swift-crypto on Linux does not. Both verify anywhere, but two consequences follow:

- **Tests verify signatures and never compare them.** A byte comparison passes on Linux and fails on the
  Mac runner.
- **Each frame id is signed exactly once and its bytes are stored.** Re-signing makes a second, different
  set of bytes for the same id, and knit-next's custody treats a frame id as one set of bytes. The ratchet's
  re-seal after a peer's reset is the one exception: it flies live under the original id and never replaces
  custodied bytes (ADR 2026-09.2ved, amended).

## v1 DM sealing

This is what `MessageCrypto.kt` does, and what Android uses toward any peer whose profile lacks
`CAP_RATCHET`.

```text
header = UTF-8("{id}|{senderId}|{sentAt}|{thread}")     thread = the recipient's node id for a DM
K  = 32 random bytes;  iv = 12 random bytes
ct = AES-256-GCM(key K, nonce iv, aad header, plaintext CBOR(MessageContent))   → ciphertext ‖ tag16
wk = HPKE base mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM,
     recipient hpkePub, info = header, aad = empty, plaintext K                 → enc32 ‖ ct48 (80 bytes)
EncEnvelope { nonce: iv, ct, keys: [{ to: recipientId, wk }] }   (v omitted; keys sorted by `to`)
```

- **Opening** reverses it: find `keys[].to == me`, unwrap K with HPKE, then open the body with the header
  as AAD, decode `MessageContent`, and drop it if its `v > 1`.
- **CryptoKit returns** `AES.GCM.SealedBox` with ciphertext and tag split; the wire wants them joined.
- **The plaintext is named CBOR:** `{"body":"hi"}` is `A1 64 626F6479 62 6869`. `body` is always present.
- **A message with a non-nil `ctl` is machinery.** It is never rendered, notified or acknowledged.
- **Without the recipient's bundle** (no profile yet), a DM waits locally as `pendingKey` and is sealed
  when the profile pins.
- **Android never wraps ctl payloads in v1.** Toward a v1 peer it sends cleartext `receipt` and `reaction`
  frames instead, so the MVP must accept those.

v1 has no forward secrecy: the same static keys open every message a peer ever sent us.

## v1 group sealing and the group id

A v1 group message is sealed the way a DM is, to several people at once (`MeshManager.kt:1159-1179`).
Android seals a group's message with v1 unless every other member's profile carries `CAP_RATCHET` and a
prekey, so every group with an iPhone in it is v1 (ADR 2026-09.n393).

```text
header = UTF-8("{id}|{senderId}|{sentAt}|{groupId}")
keys   = one wk per member of the effective roster with a pinned bundle, the sender excepted; sorted by `to`
```

- **The frame** is a `chat` with `relay = true`, no `recipientId`, the roster in the cleartext `group`, and
  `ChatContent{enc}` (`MeshManager.kt:1933-1952`). The body key, the nonce and the wraps work as a DM's do.
- **A member whose key the sender lacks is skipped.** The iPhone also sends a `keyreq` for them. When no
  member has a key yet, the message waits as `pendingKey`, as a DM does; Android stores it as sent and
  never sends it.
- **The sender wraps nothing to itself,** so after a wipe it cannot open its own group messages again.
- **The group id** names the founding set: the members and the departed, the creator among them
  (`Conversations.kt:161`, `groupIdFor`).

  ```text
  canonical = sortedDistinct(members + departed).joined(",")
  groupId   = "g-" + lowercase_hex( SHA-256( UTF-8("knit-group-id-v1:" + canonical) )[0..<12] )
  ```

  Kotlin's `toSortedSet()` sorts in Java `String` order, by UTF-16 code unit, and drops exact duplicates.
  Swift's `String` order and `==` both differ (ADR 2026-09.jc2x), so `GroupId.derive` compares `utf16`.
- **Goldens,** computed in Python from the Kotlin until A5 puts them in `keyed-v1.json`: `[alice, bob,
  carol]` gives `g-0fcb434512afea55af84f0a5`, and `[a, b]` gives `g-0aaf7d9b49f9210774ddcf1d`.
  `[U+FF61, U+1F600]` gives `g-54465e508ab811be30a4eb91`, where scalar order would give
  `g-786c8e7cddfe4cc9ea05e679`.
- **The name and the roster are not sealed.** Relays read both, and a group message's ticks travel in the
  clear, as a room post's do.

## A photo in a DM or a group

A photo is sealed on its own, and the message carries the key (`AttachmentCrypto.kt`, ADR 2026-10.6cas).

```text
K  = 32 random bytes;  iv = 12 random bytes            a fresh pair for every photo sent
blob = iv ‖ AES-256-GCM(key K, nonce iv, aad empty, plaintext photo) ‖ tag16
hash = lowercase hex SHA-256(blob)                       the name the blob is stored, asked for and served by
MessageContent { body, attachmentHash: hash, attachmentMime, attachmentKey: base64(K) }   sealed as above
ChatContent { enc, attachmentHash: hash }                the hash alone in the clear, for a carrier to pull
```

- **Opening** takes the key from the opened message: split off the 12-byte nonce and the 16-byte tag, and
  open. A wrong key, a bad tag or a blob shorter than 28 bytes opens nothing, as Android answers null.
- **A photo is sealed once,** on both phones (knit-next ADR 2026-10.mptm, ADR 2026-10.f3mv). Sent again, it goes
  under the hash and key it arrived with, so one blob and key may recur across messages and a carrier can see that
  two frames carry one file. A fresh key is drawn only for a picture this phone has not held. The plaintext's
  SHA-256 is kept beside a sealed row (`attachmentPlainHash`, local only), and a key-less frame naming it, from
  someone party to the conversation that copy came through, is held from our own copy rather than pulled.
- **The key and the nonce come from the system's generator,** never the injected one, as a message's do.
- **A room post's photo is not sealed:** its blob is the photo, and its hash is the photo's. A sealed DM or group
  message may name such a photo too, with no `attachmentKey`: a room picture Android forwards under its own hash
  (knit-next ADR 2026-10.mptm), and so does this port's. A null key has always meant a plaintext blob, and this
  port shows it as one (`MeshEnginePhotoTests.aSealedMessageMayNameAPhotoWithNoKeyWhichIsThePlaintextBlob`).
- **The goldens:** `AttachmentCryptoTests` pins a blob and its hash at a fixed key and nonce, computed with
  the port itself and checked against Python's `cryptography`, until A7 adds one to `keyed-v1.json`.

## Safety number

```text
digest = SHA-256( UTF-8( sorted(["<idA>|<bundleA>", "<idB>|<bundleB>"]).joined(separator: "\u{0}") ) )
number = digest as 8 big-endian UInt32 values, each mod 100000, zero-padded to 5 digits, space-separated
```

The separator is a raw NUL byte inside the Kotlin string literal at `SafetyNumber.kt:25`. It reads as
nothing in most editors, and `SafetyNumberTest` pins only the format, so the A2 golden is the only check
that catches a port that gets it wrong.

## Verify code

```text
code = "knit-id:v1:" + nodeId + ":" + bundle      // VerifyPayload.kt; always 150 ASCII bytes
```

Each phone draws its own code as a QR code (zxing, error correction L) on a peer's profile, and the peer
scans it there. The node id ends at the first `:` after the prefix, and the bundle is the rest, since
standard base64 has no `:`. Android's profile compares a scanned code with the pinned bundle's text and
writes nothing unless both match (`ProfileDetailsViewModel.kt:397-411`). Its Add contact path pins a key
from a scan, and this port does not have it yet (ADR 2026-10.65xx). Android's scanner also reads a signed
contact card (`docs/CONTACT_CARD.md`), which no phone draws as a QR code, and which this port reads as no
code at all. knit-next pins no vector for the code: `VerifyPayloadTests` checks keyed-v1 Alice's, computed
from the format.

## Alias

A blank display name shows an alias. With `d = SHA-256(UTF-8("knit-alias-v2:" + nodeId))`, token t is
`ADVERBS[d[3t]] + ADJECTIVES[d[3t+1]] + NOUNS[d[3t+2]]`, for up to 10 tokens (`identity/Alias.kt`).

- **The word lists** are three sorted, disjoint lists of exactly 256 words in `identity/AliasWords.kt`. The
  SHA-256 of `(adverbs + adjectives + nouns).joined("\n") + "\n"` is
  `3d36fd522087180cef0ccaab6b6f3cc6f28aaf8a72816c44bcc9b778240164ed`.
- **Goldens:** `node123 → OptimallyArtfulFox`, `k3p9xq2a → ThriftilyWoollyOriole`,
  `aaaaaaaa → MindfullyZealousZircon`, `zzzzzzzz → EquallyQuaintMeerkat`.
- **The lists must be ported byte for byte.** If they differ, the two platforms show different names for
  the same person. `scripts/sync-vectors.py` generates `Sources/KnitCrypto/AliasWords.swift` from the Kotlin
  file, and `AliasTests` checks the fingerprint.

## Text limits

Limits count UTF-16 code units (`TextLimits.kt`): display name 32, group name 32, status 100, message 2000,
reaction 32. A name is normalized by trimming with Kotlin's `trim()` and collapsing runs of Java regex `\s` to
one space before it is cut. Both sets are ART's, which knit-next's `ArtTextSemanticsTest` reads on a device: `\s`
is Unicode White_Space, and `isWhitespace` adds `\u{1C}`–`\u{1F}` but not U+0085. U+180E is neither, as on ART
from API 37's mainline module (ADR 2026-10.7uyt). A group name that arrives is only cut, and a blank one never
clears the name held.
Swift must count `utf16`, not `Character`s.

## The Swift port (`KnitCrypto`)

| knit-next | Swift |
| --- | --- |
| `PublicKeyBundle` | `PublicKeyBundle`: `init?(encoded:)`, `init?(signingKey:agreementKey:)`, `nodeId`, `isValidSignature(_:for:)` |
| `NodeId.derive` | `NodeId(deriving:)`, an extension on the `KnitWire` type |
| `IdentityKeyStore` | `IdentityKeys` plus a `SecretStore` (a file for the peer; the Keychain in P6) |
| `IdentityKeyStore`'s prekeys | `PrekeyRing`: `load(for:from:)`, `newest`, `prekey(id:)`, `rotateIfDue(now:)`, `rotate(now:)` |
| `MessageCrypto` | `MessageCrypto.header`, `.seal`, `.open`; `IdentityKeys.signature(for:)` |
| `AttachmentCrypto` | `AttachmentCrypto.seal(_:)`, `.open(_:key:)`, and `BlobHash(of:)` for the blob's name |
| `Conversations.groupIdFor` | `GroupId.derive(_:)` |
| `SafetyNumber`, `Alias`, `DeviceTag` | the same names |
| `VerifyPayload`, `ContactCard.parseLegacy`'s check | `VerifyPayload.encode`, `.parse`, `Parsed.certifiedNodeId` |
| `RatchetEngine` | `RatchetEngine`: `initiate`, `seal`, `open`, over `SessionState`, `OpenContext`, `OpenOutcome` and `OpenDelta` |
| `RatchetSessions` | KnitMesh's `RatchetSessions`: `sealDm`, `open`, `noteUndecryptable`, `sealResetDm`, `sweep`, `forget`, `settle`; the reset's pure rules in `RatchetResetPolicy` |
| `RatchetStore`, `RatchetRepository` | KnitStore's `RatchetStore`, `MemoryRatchetStore` and `RatchetRetention`; KnitStoreSQL's `SQLRatchetStore` (schema v17); `RatchetRecords` maps the rows to the engine's types |

- **Stored keys** are the CBOR map `{signingSeed, agreementScalar}`, two raw 32-byte private keys. The
  ratchet's prekeys join it as a third key, `prekeys`, which `PrekeyRing` writes and an older build ignores ("Keys
  and the signed prekey", below). `IdentityKeys.load(from:)` makes a new identity only when the store is empty or holds
  something unreadable. A store that cannot answer throws instead, so a Keychain read before the first unlock
  after a reboot never mints a new node id.
- **Low-order X25519 keys are refused on both seal and open.** RFC 9180 §7.1.4 requires it and Tink does
  it, but swift-crypto and CryptoKit skip the all-zero check on purpose (`X25519Keys_boring.swift`).
  `MessageCrypto` runs one throwaway exchange to find such a key. The bundle itself still parses, as it does
  on Android, so the profile frame is relayed and carried like any other.
- **Where parsing is stricter than knit-next,** the outcome is the same. A bundle whose keys are not 32
  bytes is refused at parse, where Android fails later at verify or seal. A bundle with trailing CBOR bytes
  is refused on both sides: kotlinx-serialization-cbor 1.11.0 refuses them too (`Cbor.kt:90-94`). Base64 padding
  follows `java.util.Base64`: optional, but exact when present.
- **Where the goldens come from:** `KeyedVectorTests` checks knit-next's own identities, signatures, sealed
  DM and safety number (`keyed-v1.json`). The device tag golden and two further safety numbers were
  computed in Python from the Kotlin sources, because knit-next pins no value for them.
- **The ratchet's DM engine** is Kotlin's `RatchetEngine`, pure, with this port's types: our `IdentityKeys`, the
  `SignedPrekey` an init names, the peer's `PublicKeyBundle` and `PeerPrekey`, and `NodeId`s. It differs from Kotlin's
  engine in four ways (ADR 2026-10.5sk9's P4b amendment):
  - Where Tink throws out of Kotlin's engine, it throws `RatchetCryptoError`. The caller refuses that frame with nothing
    committed and nothing counted toward a reset.
  - A carried nonce that is not 12 bytes is `BAD_HEADER`, which Kotlin's pipeline decides before its engine. It reads
    a chain or skipped key only for the header's own `se` and `n`, where Kotlin trusts its caller.
  - Its session keeps no `sendEpochExport`, the spool's half.
  - `seal` answers `nil` both when a new epoch is due with no base and for a session missing its send chain or,
    unconfirmed, its init, where Kotlin's `checkNotNull` throws. The second is unreachable by construction, so the
    session store's round trip must keep every `SessionState` field. Neither `nil` means "send v1" by itself: a chat
    falls back to v1, a ctl to its cleartext frame, and a seed waits.

## The ratchet: v2, v3 and the group form

knit-next's forward secrecy, which this port carries but does not yet open. ADR 2026-10.5sk9 ports all of it dark,
behind `MeshConfiguration.ratchet`, phase by phase, and turns the capability bits on once, at the end. Kotlin lines
in this section are at knit-next `ac491f4c`, past the pin. The DM side is under `mesh/crypto/ratchet/`
(`RatchetCrypto.kt`, `RatchetEngine.kt`, `RatchetSessions.kt`), `data/ratchet/` and
`data/crypto/IdentityKeyStore.kt`. The rest is in `InboundPipeline.kt`, `MeshManager.kt`, `IntroSync.kt`,
`CryptoScheme.kt` and `MessageContentV2.kt`. Where `docs/FORWARD_SECRECY_RATCHET.md` or
`docs/GROUP_FORWARD_SECRECY.md` disagree with the Kotlin, this port follows the Kotlin ("Where the docs lag the
Kotlin", below).

It is an epoch-rekey ratchet with an X3DH bootstrap, not Signal's Double Ratchet: custody leaves permanent holes
that an in-order chain would not survive. The session root never changes, and each epoch derives from it on its own.

### Keys and the signed prekey

- **IK** is the v1 X25519 identity key (`hpkePub`). The bundle, the node id and the safety number do not change.
- **The signed prekey (SPK)** is a fresh X25519 pair:
  - its id is the newest id plus 1, starting at 1;
  - it rotates once the newest is 7 days old, checked at start and on every heal;
  - five private keys are kept, the current one and four more, beside the identity and outside the database
    (`IdentityKeyStore.kt:189-202`, `:273-276`).
  - A rotation republishes the profile with a version bump (`MeshManager.kt:996-1003`).
- **Signed bytes:** `"knit/dm/v2/spk" ‖ u32be(id) ‖ pub`, 50 bytes, signed with the identity's Ed25519 key
  (`RatchetCrypto.kt:171-174`). Tink's Ed25519 is deterministic and CryptoKit's is not, so this port keeps each
  prekey's signature from its mint.
- **On the wire:** `ProfileContent.prekey = {id, pub, sig}`, with a 32-byte `pub` and a 64-byte `sig`. It is
  the eighth field, after `capabilities`. It rides the cleartext profile only, never the sealed `CTL_PROFILE`
  (`Wire.kt:576-581`, `:682-686`).
- **Taking a peer's prekey in** (`InboundPipeline.kt:3281-3368`):
  - verify `sig` against the bundle in the same profile, and require a 32-byte `pub`; anything else counts as no
    prekey;
  - the prekey has its own watermark, the profile's `version`;
  - a profile newer on that watermark with no prekey, or a bad one, clears the pin;
  - a profile older on the presentation's watermark and not on the prekey's still moves the prekey, and with it the
    capabilities, device tag and protocol version, which follow any profile not older on both (`:3310-3318`).

  This port does all of it whatever the switch says, since it sends nothing (`PeerRecord.prekey`,
  `prekeyProfileAt`, schema v16).
- **Our own, in this port** (`PrekeyRing`; `MeshEngine.syncPrekey` and `currentProfileEnvelope`):
  - The identity's item grows to `{signingSeed, agreementScalar, prekeys: [{id, priv, createdAt, sig}]}`, newest
    first. Loading never writes, and leaves out of the ring a stored prekey whose key or signature a peer would refuse.
  - A rotation reads the item, checks that the identity in it is this one byte for byte, replaces `prekeys` alone,
    writes and reads back. The ring changes only after all of that, so no profile names a prekey whose private half
    is not stored.
  - The new id is one above the highest id any stored entry names, whether or not the rest of that entry reads, since
    a peer may hold that id under another public value (`MeshManager.kt:1011-1013`). Retention keeps the five highest
    ids this build reads and prunes nothing else: an entry it cannot read is written back as it was stored, and does
    not count toward the five. Android never mints over prekeys it cannot parse (`IdentityKeyStore.kt:136-137`), and
    a `prekeys` value that is not one list is not minted over here either.
  - `OwnProfile.prekeyId` names the prekey a publish carries, so one stamp is one payload. With the switch on, start
    and every heal mint a due prekey and republish as an edit when the newest differs; with it off, a profile that
    still names one is republished without it.
  - A profile at version 0 has never been edited, and takes no edit for its prekey either. It is republished under a
    new stamp with its version left at 0, so a peer that holds any edit of ours keeps the name and the prekey it has,
    which the ring still holds. The first edit, onboarding's, carries the prekey with the name. A profile the store
    cannot read (`OwnProfileStore.loadIfReadable`) changes nothing.
  - The three bits and the prekey ride the profile together, or neither does: `CAP_RATCHET` promises a published
    prekey. A node with no ring, or whose store refused the first mint, publishes what it would with the switch off.
  - A start that finds prekeys over a profile never published is a reinstall, and mints a fresh one whatever the
    newest one's age, as Android's restore does (`MeshManager.kt:1036-1047`), with no resets. Android's restore brings
    the name back and bumps the version. A reinstall here has no name until onboarding publishes one, so its prekey
    rides the republish at version 0: an edit would flood an empty name that every peer takes, and Android would
    write a rename line into every thread with us (`InboundPipeline.kt:1299-1301`).

### Derivations

All HKDF here is HKDF-SHA256 called as Tink calls it: input key material first, then salt (`RatchetCrypto.kt:27`).
The zero salt is 32 zero bytes, and labels are ASCII.

```text
X3DH, initiator          DH1 = X25519(IK_a, SPK_b)   DH2 = X25519(EK_a, IK_b)   DH3 = X25519(EK_a, SPK_b)
X3DH, responder          the same three, from the other side's private keys
root                     HKDF(ikm = 0xFF×32 ‖ DH1 ‖ DH2 ‖ DH3, salt = zero, info = "knit/dm/v2/x3dh", 32)
epoch                    okm = HKDF(ikm = X25519(epoch or base private, the other's public), salt = root,
                                    info = "knit/dm/v2/epoch" ‖ dir ‖ u32be(se) ‖ u32be(pe), 64)
                         chainKey0 = okm[0..<32]; export = okm[32..<64]
message key              mk(n)   = HKDF(ikm = ck(n), salt = zero, info = "knit/dm/v2/mk", 32)
next chain key           ck(n+1) = HKDF(ikm = ck(n), salt = zero, info = "knit/dm/v2/ck", 32)
v3 nonce                 HKDF(ikm = mk(n), salt = zero, info = "knit/dm/v3/nonce" ‖ boundAad, 12)
v3 header binding        "knit/dm/v3/hdr" ‖ u32be(se) ‖ ek ‖ u32be(pe) ‖ u32be(n) ‖ u8(flags)
                           ‖ (no init: 0x00 | init: 0x01 ‖ eph ‖ u32be(pkid) ‖ u64be(at))      60 or 104 bytes
root tag                 HKDF(ikm = root, salt = zero, info = "knit/dm/v2/root-tag", 8), read as a big-endian
                           Int64 and kept locally
exports                  "knit/dm/v2/export/root" and "/export/epoch": the spool's alone; this port leaves them out
```

- **`dir`** is `'i'` (0x69) when the epoch's sender initiated the session, else `'r'` (0x72)
  (`RatchetCrypto.kt:116-129`).
- **The sender's DH base** is the peer's newest epoch it has seen (`peerBasePub`), or the peer's pinned SPK when
  `pe = 0`.
- **The receiver's DH base** is our SPK for `init.pkid` when `pe = 0`, and otherwise our own local epoch numbered
  `pe`. The lookup is by number alone (`RatchetEngine.kt:451`, `RatchetSessions.kt:134-140`).
- **No one-time prekeys.** The EK private key is used once for the root and never stored.
- **A new send epoch starts** at any of: no epoch or no chain yet; the peer has contributed a newer epoch; 200
  messages; or 24 h. Its number is the last one plus 1 (`RatchetEngine.kt:300-311`, `:830-859`).

### The envelope

- **v2:** `{v: 2, nonce: 12 random bytes, ct, keys: [], r: {se, ek, pe, n, init?, flags?}}`.
  - The AAD is the v1 header, `"{id}|{senderId}|{sentAt}|{recipientId}"`.
  - `flags` is written onto the header after sealing, so it is not in v2's AAD.
  - `init = {eph, pkid, at}` rides every frame until the session confirms.
- **v3:** the same header, with `nonce` present and empty and `flags` always 0.
  - The AAD is the header string followed by the header binding, and the nonce derives from the message key and
    that AAD.
  - The plaintext is `MessageContentV2`.
- **Header bounds** (`RatchetEngine.kt:346-349`): a frame outside these is `BAD_HEADER`.
  - `se` is in `[1, 2^24]`, `n` in `[0, 199]` and `pe` in `[0, 2^24]`;
  - `ek` is 32 bytes;
  - and `pe ≥ 1` or an init rides.
- **Receive gates** (`InboundPipeline.kt:975-983`, `:1008-1028`):
  - a missing `r`, or a v2/v3 DM addressed to a group, is `BAD_HEADER`;
  - so is a v3 `nonce` that is not empty, or a v2 one that is not 12 bytes;
  - `v > 3` is dropped, counted, and still relayed.
- **Low-order keys.** Tink throws on a low-order public value (`RatchetCrypto.kt:56-60`).
  - A bad `ek` is `BAD_HEADER`.
  - A bad `init.eph` falls to the pipeline's catch-all, which never triggers a reset.
  - CryptoKit returns zeros instead, so this port must refuse an all-zero DH result itself and map it the same way.
    Read as `AEAD_FAIL`, it would trigger a reset Tink never would.

### Plaintexts

- **v2** uses the named `MessageContent`. `body` is required, and a ctl sends `""`.
- **v3** uses `MessageContentV2`, with integer labels. An id or hash is raw bytes, and unknown labels are skipped.

  | Label | Field | Label | Field |
  | --- | --- | --- | --- |
  | 0 | `v`, omitted while 1 | 8 | `ack`, a 16-byte frame id |
  | 1 | `body` | 9 | `acks` |
  | 2 | `mentions` | 10 | `rp` |
  | 3 | `attachmentHash`, 32 bytes | 11 | `pr` |
  | 4 | `attachmentMime` | 12 | reserved (`pad`) |
  | 5 | `attachmentKey` | 13 | reserved (`gk`) |
  | 6 | `replyTo` | 14 | `attachmentName` |
  | 7 | `ctl` | 15 | `attachmentSize` |

  A content the compact codec cannot carry canonically seals as v2 instead: a non-canonical id, hash or key, any
  `gk` or `xf`, or `v ≠ 1` (`MessageContentV2.kt:53-60`, `:102-108`). The nine `messageContentV2*` fixtures are in
  `wire-v1.json` already.

### Sessions

- **Per peer:**
  - `root`, `confirmed`, `weAreInitiator`, `establishedAt` (our clock exactly when we initiated, else the peer's
    `init.at`);
  - the pending init (`initEphPub`, `initPkid`) and the peer's init anchor (`peerInitEphPub`);
  - `prevRoot` with its role and expiry;
  - the DH base (`peerBasePub`, `peerBaseEpoch`);
  - the send chain (`sendEpoch`, its key pair, `sendChainKey`, `sendCount`, when it started, its base);
  - `highestPeAcked` and `lastResetSentAt`.
- **Four tables:**
  - `ratchet_sessions`;
  - `ratchet_local_epochs` (peer, epoch);
  - `ratchet_recv_epochs` (peer, epoch, root tag);
  - `ratchet_skipped_keys` (peer, epoch, index, root tag).

  Skipped keys are inserted with IGNORE. A local epoch whose number is minted again replaces the dead era's key
  (knit-next ADR 027). This port's schema v17 keeps them as Android's database v21 does, less the session's
  `sendEpochExport` (the spool's) and `updatedAt` (never read).
- **Retention,** swept at start and then at most hourly (`RatchetRepository.kt:121-157`, `:213-224`):
  - skipped keys are dropped once 48 h old, and the oldest go first past 2,000 in all;
  - receive rows go after 48 h unused;
  - local epochs are ordered by mint time and the newest three always stay. The rest go past 16, at 30 days, or
    once acked and 48 h old.
  - Sessions are never swept.

  The rules are pure code both stores apply (`RatchetRetention`). Android orders the cap's eviction by `createdAt`
  alone and leaves a tie to SQLite; here a tie goes by peer, epoch, index and root tag, so the memory and SQL stores
  evict the same keys. The order is local, and the pair never compares it.

  At rest, a deleted row is zeroed in the next write of its page (`secure_delete`), which reaches the database file
  only at a checkpoint, while the write-ahead log keeps the frames that wrote the key until it is reset. Each sweep's
  truncating checkpoint does both once it commits, so after a sweep that finds no reader on the log neither file holds
  a key deleted or replaced before it; between sweeps either can. Nothing calls the sweep before P5 (ADR
  2026-09.nyya, amended 2026-10-15).
- **Bounds and floors** (`RatchetEngine.kt:863-885`, `RatchetSessions.kt:602-631`, `IntroSync.kt:349-358`):

  | Bound | Value |
  | --- | --- |
  | messages per epoch | 200 |
  | epoch number | 2^24 |
  | epoch jump adopted, once anchored | 1,024 |
  | epoch age | 24 h |
  | `prevRoot` drain | 48 h |
  | reset evidence | 3 distinct frame ids, from an LRU of 8 |
  | our heuristic resets | one per 6 h |
  | a stranded tail | 48 h |
  | adopting a replacement | once an hour, or once a minute when `FLAG_RESET` is set |
  | re-sending an intro | 20 h |
  | answering one init again | 60 min |

### Lifecycle

- **First contact.** The first seal with no session runs X3DH against the pinned SPK. The session starts
  unconfirmed, with epoch 1 based on the SPK (`pe = 0`).
- **The responder** establishes a confirmed session from the init, and anchors on its `eph`.
- **An initiator confirms** on an open that moves the era, when `pe ≥ 1` names an epoch whose private key we hold.
- **Races.** When both sides initiate, the init from the smaller node id wins, compared as ASCII and never by clock
  (`RatchetEngine.kt:653-705`).
  - The loser adopts the winner's root.
  - The winner stays unconfirmed, keeps sealing against the loser's SPK, and reads the loser's root read-only.
  - The loser's late opening DM gets a read-only candidate and is never anchored (#83).
- **Opening, in three passes, per candidate root:**
  1. the skipped key;
  2. the live chain;
  3. a fresh derivation, with one DH shared across candidates.

  Each candidate stops at the first pass where it holds something of its own.
  - **The verdict** when nothing opens: `DUPLICATE`, then `AEAD_FAIL`, then `BAD_HEADER`, then `EPOCH_GONE`.
    `DUPLICATE` never stops the ladder early.
  - **A resolution that purges** reads nothing stored.
- **Era effects** apply only on a fresh derivation under the active root (knit-next ADR 2026-09.pz9g): adopting the
  peer's epoch as our base, raising `highestPeAcked`, and confirming an initiator.
- **Receive rows and skipped keys** carry the tag of the root that derived them, and a candidate reads only its own
  (knit-next ADR 2026-10.gcrd).
- **The exists-gate** acknowledges a signed frame whose id is a stored message and never opens it. That is what
  makes deleting spent keys safe under custody's re-serves. A ctl frame has no row, so its re-serves reach the
  ratchet.
- **The reset heuristic** (`InboundPipeline.kt:1816-1900`, `RatchetSessions.kt:295-311`):
  - It counts authenticated `NO_SESSION`, `EPOCH_GONE` and `AEAD_FAIL` only, never `DUPLICATE` or `BAD_HEADER`.
  - It needs three distinct ids from the era it would abandon, and 6 h since our last reset.
  - Each counted frame gets one copy past the router's dedup (`reopen`).
- **Reset plans** (knit-next ADR 2026-09.qerd; `RatchetSessions.kt:393-469`):
  - **Re-root:** a fresh init flagged `FLAG_RESET`, numbering again from 1.
  - **Mark:** flag our own init that is still unanswered.
  - **Decline:** inside the peer's 60 s floor.

  A reset is always v2, with the plaintext `{"body": "", "ctl": 1}`.
- **After a reset we receive,** we re-seal our unacked DMs of the last 24 h under their original id and `sentAt`,
  keeping an attachment's name and size, and force a group seed flush (`MeshManager.kt:3361-3407`). That re-seal is
  the one exception to "signed once" (ADR 2026-09.2ved, amended).
- **Init answers** (IntroSync's answer half, `IntroSync.kt:185-240`):
  - each new init from a peer gets one sealed answer, then none again for 60 min, and a reset-marked init gets one
    more;
  - an init that opened before the peer's prekey and `CAP_RATCHET` pinned is owed an answer once they pin (knit-next
    `937cf785`).

### Control codes

| ctl | Name | Carries | Here |
| --- | --- | --- | --- |
| 1 | session reset | nothing; `flags` bit 0 on the header | handle and send |
| 2 | group key | `gk`: `{groupId, keys: [{epoch, seed, mintedAt}], ackEpoch?, gr?, group?}` | handle and send |
| 3 | group key request | `gk{groupId}` | answer, and send when a group frame will not open |
| 4 | group key ack | `gk{groupId, ackEpoch}` | send and handle |
| 5 | receipt | `ack` and/or `acks`, at most 128 ids, the forged-ack guard | handle and send |
| 6 | reaction | `rp{messageId, emoji?}`; no emoji retracts; last writer wins on `sentAt` | handle and send, in DM and group form |
| 7 | reserved | never reused | — |
| 8 | profile | `pr{name, status, avatarHash?, version, openToChat, loraNode?, loraKey?}`, no prekey | handle and send, presentation only |
| 9 | transfer | `xf`, only toward `CAP_DIRECT_TRANSFER` | unknown here |

- **A ctl is machinery:** never stored as a message, notified or acknowledged.
- **An unknown code** still commits the chain advance and does nothing else (`InboundPipeline.kt:1191-1196`).
- **A ctl is never v1-wrapped.** Toward a peer without the ratchet, a receipt or reaction falls back to the
  cleartext frame, and a seed has no fallback: the group goes v1.
- **In the group form,** only ctl 6 is applied (`InboundPipeline.kt:1636-1646`).
- **A sealed receipt purges nothing,** anywhere, and a sealed tick is sealed once and re-sent verbatim with backoff
  (ADR 2026-09.p6nb, amended).
- **Inline acks** (`CAP_INLINE_ACK`): up to four `acks` ride a plain sealed DM to an author whose profile has
  `0x40`, and are applied in the same commit as the message (`InboundPipeline.kt:1088-1116`).

### Which scheme a send takes

- **A DM** is sealed with the ratchet when the peer's pinned profile carries `CAP_RATCHET` and a bundle is pinned
  (`MeshManager.kt:1287-1308`). It is v3 when the profile also has `CAP_CRYPTO_V3` and the content encodes
  compactly, and v2 otherwise.
  - `sealDm` returns nothing when there is no session and no prekey, or when a new epoch is due with no base. The DM
    then goes v1, counted.
  - A DM waits only for a bundle (`pendingKey`), so a peer pinned without a prekey gets v1 at once, and that DM is
    never upgraded.
  - In this port the switch comes first: off, nothing takes the ratchet.
- **A group message** takes the group form only when every other member has a bundle, `CAP_RATCHET` and a prekey,
  and the epoch's seed seals to all of them (`MeshManager.kt:1319-1353`). Any shortfall sends that message as v1.
- **Resets, seeds and the group form** are always v2.

### The group form

- **Seeds.** Each member mints a random 32-byte seed per group epoch, with no DH (`GroupRatchetCrypto.kt:30-76`):

  ```text
  epoch      okm = HKDF(ikm = seed, salt = zero,
                        info = "knit/group/v1/epoch" ‖ "{groupId}|{senderId}|" ‖ u32be(e), 64)
             chainKey0 = okm[0..<32]; export = okm[32..<64]
  chain      mk = HKDF(ck, zero, "knit/group/v1/mk", 32);  next ck = HKDF(ck, zero, "knit/group/v1/ck", 32)
  ```

- **The frame** is `{v: 2, nonce, ct, keys: [], g: {se, n}}`, with the AAD `"{id}|{senderId}|{sentAt}|{groupId}"`.
- **Seeds travel only as v2 `CTL_GROUP_KEY` DMs**, through an outbox that is the truth, not custody.
  - They are acked with ctl 4, and re-sent no more than every 15 min per group, member and pairwise root.
  - A reset forces the flush.
  - A request (ctl 3) is answered (`MeshManager.kt:1444-1484`).
- **Adoption** goes by `(epoch, mintedAt)`, at most four a day per group and sender
  (`GroupRatchetEngine.kt:204-229`, `GroupRatchetSessions.kt:274`).
  - A seed for a group we don't know pins the roster from `gk.group`, or parks before the commit. The park holds
    1 h, 64 frames, 16 per group.
  - Custody is replayed after an adoption, at a group's first sight, and hourly (`InboundPipeline.kt:1151-1156`,
    `MeshManager.kt:1739-1800`).
- **A send epoch advances** at 200 messages, at 24 h, and on a leave or a rejoin.
- **A retired chain never reuses its epoch number** (knit-next `0f519d71`, knit-next ADR 2026-10.xgwj).

### Threading and the store

- **Android** opens in two phases: a peek with no lock feeds moderation, then a commit under the one ratchet mutex,
  inside a database transaction, writes the session and the message row together (`RatchetSessions.kt:166-236`,
  `SessionTransactor.kt`). The transaction is outside and the mutex inside, on every path.
- **This port's engine** is one synchronous actor, and moderation runs after the row is stored, so one phase is
  enough.
  - The store unit is outermost. The ratchet's change commits together with the row, the inline acks, a seed's
    adoption and the rest, or nothing does.
  - On a failure nothing is delivered and nothing is sent. A send persists its advanced chain before the frame
    leaves.
  - In Swift the unit is `StoreTransactor.atomically` on `MeshStores.transactor`: the `KnitDatabase` itself, or a
    `MemoryTransactor` over the memory stores (ADR 2026-10.5sk9's P4a amendment).
  - Any store error fails the unit, a read's as well as a write's, except a blob's file error, which is reported and
    fails nothing. A `nil` or `false` from a blob's bytes inside a unit may only mean doing nothing (as
    `notePlainHash` does), never a decision.
  - Only the outermost unit's `.committed` lets the work after the commit run. A nested unit answers `.joined`, and
    its caller hands that work up through the outer body.
- **The session facade, `RatchetSessions`** (KnitMesh), decides and writes inside one unit per call, and reads the
  store inside it too, so a store that cannot answer fails the unit rather than deciding on its fallback.
  - An open's changes commit with whatever its caller writes in `alongside` (the message row, P5's), or none do.
  - Each call answers `settled` (its unit committed as the outermost, or changed nothing), `joined` (it ran inside a
    caller's unit: what it made stands, may be sent or delivered, and moves the floors through `settle` only once the
    caller's outermost unit commits) or `failed` (nothing persisted, nothing used, and an inbound frame is replayed
    from our own custody, P5's).
  - Its floors live in memory: the replacements adopted, our init's answer, our resets for a peer with no session row,
    and the heuristic's ids, which compare by their bytes. They die with the process, and each moves only after a
    commit, save that a frame the heuristic counts joins its ids at once, as on Android; only their clearing waits for
    a commit. `sealResetDm`'s decline reads the persisted `lastResetSentAt`.
  - `noteUndecryptable` runs the era gate itself (`InboundPipeline.kt:1835-1856`): a unit that only reads the session
    row, then `isLiveEvidence` on the frame's signed `sentAt`, as it arrived and never clamped, then the ids and the
    6 h floor, from the later of the stamp the unit read and the one held in memory. A unit that fails counts nothing,
    so a store that cannot answer neither lets a frame of an era left behind into the ids nor buys a reset (knit-next
    `d7487392`, `cf447a9b`). Nor does a call inside a caller's unit, whose joined open or reset clears the ids only
    once that unit commits.
  - The init's prekey is looked up by the id the init names, and one under another id counts as none
    (`RatchetSessions.kt:140`).
  - A key X25519 refuses, from a peer's signed prekey or an init's ephemeral, commits nothing and counts toward no
    reset: a seal answers `refusedKey`, and an open `rejected`.

### The promise behind the bits

- **`CAP_RATCHET` (0x10):**
  - the open path above, races and replacement included;
  - ctl 1, 2, 5, 6 and 8 handled, and 4 sent;
  - the reset heuristic and plans;
  - init answers;
  - the group form received in full;
  - our prekey published, signed, rotated and kept.
- **`CAP_INLINE_ACK` (0x40):** inline `acks` applied in the message's commit.
- **`CAP_CRYPTO_V3` (0x100):**
  - v3 opened;
  - the unsigned live-link tick admitted. It must be a `relay = false` DM-form chat to us from a pinned peer. It is
    checked ahead of the exists-gate, must open as a v3 `CTL_RECEIPT` before anything commits, and is never
    custodied and never counted toward a reset (`InboundPipeline.kt:592-598`, `:1739-1768`).
- **Android reads these bits from the pinned profile alone** (`CryptoScheme.kt:11-13`). That is why the dark phases
  can carry them on a Debug build's profile while the HELLO and the advert stay `0xF`.

### What this port leaves out

- **The spool's exports and its root gossip.** `gr` is decoded and kept raw, and never sent. Its cost is bounded
  (ADR 2026-10.5sk9).
- **Sending contact-card intros.**
- **`CTL_TRANSFER`.**
- **Unsigned tick sends:** a signed tick costs 64 bytes and verifies the normal way.
- **The LoRa and spool tick paths.**

### Where the docs lag the Kotlin

This port follows the Kotlin in each case, and each one is a doc fix owed to knit-next.

- **Numbering:** a reset restarts our own epoch numbering at 1, not only a wipe.
- **Replacement floors:** 60 min unflagged and 60 s with `FLAG_RESET`, both held in memory, not one an hour.
- **`DUPLICATE`** never triggers a reset (knit-next ADR 024 over ADR 023).
- **The era gate** is knit-next ADR 026's.
- **The sweep** runs at most hourly.
- **Timing of the 48 h rules:** a local epoch's 48 h counts from its mint, and skipped keys age from creation.
- **Prekey pins:** an invalid prekey also clears the pin, and the watermark is the profile `version`, not `sentAt`.
- **`flags`** is read whether or not an init rides.
- **Race candidates:** a race rebuilds the candidate list rather than adding to it.
- **The 6 h reset floor** applies to the heuristic alone.

One rule to port as it is and report rather than fix: a session left unconfirmed past 24 h or 200 frames bases its
next epoch on a rotated prekey while its init still names the old `pkid`. Its frames then fail until a reset
(`RatchetEngine.kt:260`, `:277`).

### Vectors

`wire-v1.json` pins only the ratchet's shapes. The keyed answers come from companion change A9:
knit-next's `vectors/ratchet-v1.json`, synced into `Tests/Vectors/` from a branch ahead of the pin
(`.agents/context/knit-next.md`, "Mirrored ahead of the pin"). Each section serves one phase:

- `kats`, the known answers for each derivation above, which `RatchetVectorTests` checks. Its `export` entry is marked
  non-normative and skipped, since the exports are left out;
- `profiles`, signed ratchet profiles and the prekey pins Android's own pipeline made of them, which
  `RatchetProfileVectorTests` delivers to one engine in the file's order;
- `dm` and `negative`, scripted DM transcripts with a state digest after each step, and the refusals, for the DM
  engine and its wiring. The file's `transcriptFormat` describes every step. `RatchetTranscriptTests` replays at the
  engine every transcript the engine alone can, and names the rest. Its store follows knit-next's `MemoryRatchetStore`
  and its digest `TranscriptJson.state` (`RatchetTranscript.kt:136-232`, `TranscriptJson.kt:40-130` on the A9 branch).
  `RatchetTranscriptSessionTests` replays the six that need the session layer through `RatchetSessions` (the races,
  the late loser, the re-root, the era gate and the reset plans), checking each step's floors held in memory and the
  rule that decided a plan. The control plane and the re-seals wait for P5's pipeline, and so do its own refusals;
- `group`, the group form's transcripts, for P6;
- `carol`, Carol, the iPhone, in races and first contacts with Alice and with Bob. Every opener is v3, and
  `RatchetTranscriptTests` replays them at the engine, Carol's seals byte for byte.

A10 then adds this port's own ratchet frames to `ios-emitted-v1.json`, for knit-next's `IosEmittedVectorTest` to
open (`.agents/memory/roadmap.md`).
