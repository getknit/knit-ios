# Security policy

Knit for iOS is an end-to-end encrypted mesh messenger, and security reports are taken seriously. It ships
as-is, with no warranty and no guaranteed response time ([`CONTRIBUTING.md`](CONTRIBUTING.md)).

## Reporting a vulnerability

Please don't open a public issue or pull request for a vulnerability. Disclosure before a fix exists puts
people at risk. Report it privately instead, through GitHub's [private vulnerability reporting][report] (the
Report a vulnerability button on the repository's Security tab) or by email to **dev@getknit.app**.
Include:

- what the issue is, and what it lets an attacker do;
- the steps to reproduce it, or a proof of concept;
- the affected commit.

Please allow reasonable time for a fix before disclosing publicly. This is a hobby project with no
acknowledgement or remediation deadline, but every genuine report is read.

[report]: https://github.com/getknit/knit-ios/security/advisories/new

## Known limits

These are deliberate trade-offs, documented here so nobody has to discover them. They are out of scope for
reports:

- **The Nearby room is not encrypted.** It has no fixed set of recipients, so posts, and the delivery ticks
  and reactions that go with them, travel in the clear. A mention there carries the mentioned person's Knit
  identity, which anyone in range can read. Posts are signed, so they can't be forged.
- **Forward secrecy needs both phones up to date.** Direct and group messages between phones running Knit for
  iPhone or Knit for Android 2.3 and later use Knit's epoch ratchet: each conversation moves to fresh keys
  after a day of use or 200 messages, and deletes the old ones once nothing needs them. The delivery ticks and
  reactions that go with those messages are sealed too, except a reaction Knit can't seal yet, such as one
  sent before it holds the other phone's key, which goes in the clear. With a phone on an older version, and
  in a group that includes one, messages fall back to Knit's static-key scheme (v1): whoever later obtains
  your identity key can read every v1 message sent to it, and those messages' ticks and reactions travel in
  the clear. The same goes for direct messages you send someone you added by their link or code, until their
  phone's profile reaches yours: those use v1, and stay v1.
- **Forward secrecy covers what was recorded off the air, not the phone itself.** Someone holding your
  unlocked phone can read the messages stored on it, and each conversation keeps its newest few keys there,
  which open the messages sealed under them. A conversation's first messages, and those after a reset, are
  sealed to a signed prekey before your phone answers. Knit rotates that prekey weekly and keeps the last five,
  so for about five weeks whoever takes your phone's keys can open those messages too.
- **Typing indicators are not encrypted.** They go only to phones linked directly to yours, and no phone passes them
  on. In a direct message that means the other person's phone alone; in Nearby or a group, every phone linked to yours,
  and a group's indicator says which group it's for.
- **The Bluetooth link itself is not encrypted.** Trust comes from the signature Knit checks on every frame it
  acts on, and from end-to-end encryption on direct and group messages, not from the radio.
- **Direct messages flood the mesh.** Only the recipient can open one, but relaying phones can see who is
  writing to whom, and how often.
- **Group messages travel with their group's name and member list in the clear,** so relaying phones can see
  who is in a group, what it is called and how often each member writes.
- **Leaving a group takes effect as word of it spreads.** Each member's phone stops sealing messages to you
  once your signed leave reaches it. Phones carry the leave for up to a day, so a member who stays out of
  reach for longer keeps sealing their messages to you.
- **A group message reaches the members whose keys the sender holds.** A member whose profile a sender's phone
  has not seen yet is skipped for that message. Knit for iPhone then asks for their key, so a later message
  can reach them.
- **Keys are trusted on first sight.** Someone relaying a substituted key before your first contact with a
  person is detectable by comparing safety numbers or scanning each other's code, not prevented.

Anything beyond these is in scope and welcome: key handling and storage, the crypto envelope, signature
verification, the CBOR and link-record parsers, and memory safety in the radio code.
