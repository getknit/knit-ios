# Identity and end-to-end crypto

How knit-next derives identities and seals DMs at the pinned commit. The MVP implements the v1 scheme only
(ADR router: `.agents/memory/decisions.md`); v2 and v3 are summarized at the end for the milestone after
it.

## Keys

- **X25519 identity key** (`hpkePub`): v1 HPKE, and later the X3DH identity key.
- **Ed25519 signing key** (`sigPub`): every frame signature, and the signed prekey's signature.
- **Signed prekey:** v2 only; it rides `ProfileContent.prekey`. The MVP publishes none.

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
  set of bytes for the same id, and knit-next's custody treats a frame id as one set of bytes.

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

## Safety number

```text
digest = SHA-256( UTF-8( sorted(["<idA>|<bundleA>", "<idB>|<bundleB>"]).joined(separator: "\u{0}") ) )
number = digest as 8 big-endian UInt32 values, each mod 100000, zero-padded to 5 digits, space-separated
```

The separator is a raw NUL byte inside the Kotlin string literal at `SafetyNumber.kt:25`. It reads as
nothing in most editors, and `SafetyNumberTest` pins only the format, so the A2 golden is the only check
that catches a port that gets it wrong.

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

Limits count UTF-16 code units (`TextLimits.kt`): display name 32, status 100, message 2000, reaction 32. A
name is normalized by trimming and collapsing runs of Java `\s` (ASCII whitespace) to one space before it
is cut. Swift must count `utf16`, not `Character`s.

## The Swift port (`KnitCrypto`)

| knit-next | Swift |
| --- | --- |
| `PublicKeyBundle` | `PublicKeyBundle`: `init?(encoded:)`, `init?(signingKey:agreementKey:)`, `nodeId`, `isValidSignature(_:for:)` |
| `NodeId.derive` | `NodeId(deriving:)`, an extension on the `KnitWire` type |
| `IdentityKeyStore` | `IdentityKeys` plus a `SecretStore` (a file for the peer; the Keychain in P6) |
| `MessageCrypto` | `MessageCrypto.header`, `.seal`, `.open`; `IdentityKeys.signature(for:)` |
| `SafetyNumber`, `Alias`, `DeviceTag` | the same names |

- **Stored keys** are the CBOR map `{signingSeed, agreementScalar}`, two raw 32-byte private keys. The
  ratchet's prekeys will join it as a third key. `IdentityKeys.load(from:)` makes a new identity only when
  the store is empty or holds something unreadable. A store that cannot answer throws instead, so a
  Keychain read before the first unlock after a reboot never mints a new node id.
- **Low-order X25519 keys are refused on both seal and open.** RFC 9180 §7.1.4 requires it and Tink does
  it, but swift-crypto and CryptoKit skip the all-zero check on purpose (`X25519Keys_boring.swift`).
  `MessageCrypto` runs one throwaway exchange to find such a key. The bundle itself still parses, as it does
  on Android, so the profile frame is relayed and carried like any other.
- **Where parsing is stricter than knit-next,** the outcome is the same. A bundle whose keys are not 32
  bytes is refused at parse, where Android fails later at verify or seal. A bundle with trailing CBOR bytes
  is refused, where kotlinx ignores them. Base64 padding follows `java.util.Base64`: optional, but exact when
  present.
- **Where the goldens come from:** `KeyedVectorTests` checks knit-next's own identities, signatures, sealed
  DM and safety number (`keyed-v1.json`). The device tag golden and two further safety numbers were
  computed in Python from the Kotlin sources, because knit-next pins no value for them.

## After the MVP: v2 and v3

knit-next's forward secrecy (`docs/FORWARD_SECRECY_RATCHET.md`, ADR 016) is an epoch-rekey ratchet with an
X3DH bootstrap. It is not Signal's Double Ratchet: custody leaves permanent holes an in-order chain would
not survive.

- **Labels:** `knit/dm/v2/x3dh`, `/epoch`, `/mk`, `/ck`, `/spk`, `/export/root`, `/export/epoch`,
  `knit/dm/v3/nonce` and `knit/dm/v3/hdr`.
- **What it adds:** session races, resets and retention rules, plus 31 behavioural scenarios in
  `RatchetEngineTest`.
- **What a peer commits to** once it advertises `CAP_RATCHET`: handle ctl codes 1, 5, 6 and 8, commit a
  chain advance even for an unknown ctl, and keep the exists-gate.
- **v3** adds a derived nonce, an integer-keyed plaintext and an unsigned live-link tick (ADR 059).

None of it has keyed vectors in knit-next today. The milestone that ports it starts by adding them.
