# Security policy

Knit for iOS is an end-to-end encrypted mesh messenger, and security reports are taken seriously. It ships
as-is, with no warranty and no guaranteed response time ([`CONTRIBUTING.md`](CONTRIBUTING.md)).

## Reporting a vulnerability

Please don't open a public issue or merge request for a vulnerability. Disclosure before a fix exists puts
people at risk. Email **dev@getknit.app** instead, with:

- what the issue is, and what it lets an attacker do;
- the steps to reproduce it, or a proof of concept;
- the affected commit.

Please allow reasonable time for a fix before disclosing publicly. This is a hobby project with no
acknowledgement or remediation deadline, but every genuine report is read.

## Known limits

These are deliberate trade-offs, documented here so nobody has to discover them. They are out of scope for
reports:

- **The Nearby room is not encrypted.** It has no fixed set of recipients, so posts, and the delivery ticks
  and reactions that go with them, travel in the clear. Posts are signed, so they can't be forged.
- **Direct messages have no forward secrecy yet.** The first release seals them with Knit's static-key
  scheme (v1): whoever later obtains your identity key can read every direct message sent to it. The epoch
  ratchet that Knit for Android already runs is the next milestone. Until then, delivery ticks and
  reactions on direct messages also travel in the clear.
- **The Bluetooth link itself is not encrypted.** Trust comes from the signature Knit checks on every frame it
  acts on, and from end-to-end encryption on direct and group messages, not from the radio.
- **Direct messages flood the mesh.** Only the recipient can open one, but relaying phones can see who is
  writing to whom, and how often.
- **Group messages have no forward secrecy either,** and travel with their group's name and member list in the
  clear, so relaying phones can see who is in a group, what it is called and how often each member writes.
  Group delivery ticks travel in the clear too.
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
