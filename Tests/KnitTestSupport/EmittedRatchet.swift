/// A ratchet seal's facts, for a reader to check the frame by (`ios-emitted-v1.json`, phase P7b): its `EncEnvelope`
/// version, its form, its header, and the plaintext it opens to, as bytes and as fields.
public struct VectorSealed: Codable, Sendable, Equatable {
    /// The `EncEnvelope`'s `v`: 3 for the compact DM form, 2 for the named DM form and the group form.
    public let version: Int
    /// `dm` for a pairwise frame (`r` rides), `group` for the group form (`g` rides).
    public let form: String
    /// The sender's epoch.
    public let se: Int
    /// The message's index in its chain.
    public let n: Int
    /// A DM's peer epoch: 0 while the session's first epoch is based on the recipient's prekey.
    public let pe: Int?
    /// A DM whose init still rides: the recipient's prekey the init names, by its name in ``EmittedRatchet/prekeys``.
    public let initPrekey: String?
    /// `MessageContentV2` for v3, `MessageContent` for v2 and the group form.
    public let plaintextSchema: String
    /// The plaintext the recipient opens, as hex.
    public let plaintext: String
    /// The fields that plaintext carries.
    public let content: VectorContent

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case form = "form"
        case se = "se"
        case n = "n"
        case pe = "pe"
        case initPrekey = "initPrekey"
        case plaintextSchema = "plaintextSchema"
        case plaintext = "plaintext"
        case content = "content"
    }

    /// Makes a seal's facts.
    public init(
        version: Int,
        form: String,
        se: Int,
        n: Int,
        pe: Int?,
        initPrekey: String?,
        plaintextSchema: String,
        plaintext: String,
        content: VectorContent
    ) {
        self.version = version
        self.form = form
        self.se = se
        self.n = n
        self.pe = pe
        self.initPrekey = initPrekey
        self.plaintextSchema = plaintextSchema
        self.plaintext = plaintext
        self.content = content
    }
}

/// The fields of a sealed `MessageContent` a reader checks: the body, the control code, a receipt's ids, a reaction, a
/// sealed profile and a group seed. Parties appear by their names in the vector files.
public struct VectorContent: Codable, Sendable, Equatable {
    /// A reaction (`rp`): the message, and the emoji, absent for a retraction.
    public struct Reaction: Codable, Sendable, Equatable {
        /// The message reacted to.
        public let messageId: String
        /// The emoji; absent when the reaction is taken back.
        public let emoji: String?

        /// Makes a reaction's fields.
        public init(messageId: String, emoji: String?) {
            self.messageId = messageId
            self.emoji = emoji
        }
    }

    /// A sealed profile (`pr`).
    public struct Profile: Codable, Sendable, Equatable {
        /// The display name.
        public let name: String
        /// The status line.
        public let status: String
        /// The profile's version.
        public let version: Int64
        /// Whether the person is open to chat.
        public let openToChat: Bool

        /// Makes a sealed profile's fields.
        public init(name: String, status: String, version: Int64, openToChat: Bool) {
            self.name = name
            self.status = status
            self.version = version
            self.openToChat = openToChat
        }
    }

    /// One group epoch's seed.
    public struct Seed: Codable, Sendable, Equatable {
        /// The sender's group epoch.
        public let epoch: Int
        /// The 32-byte seed, as hex.
        public let seed: String
        /// When the sender minted it, on its clock.
        public let mintedAt: Int64

        /// Makes a seed's fields.
        public init(epoch: Int, seed: String, mintedAt: Int64) {
            self.epoch = epoch
            self.seed = seed
            self.mintedAt = mintedAt
        }
    }

    /// A group's founding roster as a seed carries it, its members by name.
    public struct Roster: Codable, Sendable, Equatable {
        /// The group id.
        public let id: String
        /// The members, by name, in roster order.
        public let members: [String]
        /// Who made the group, by name.
        public let createdBy: String

        /// Makes a roster's fields.
        public init(id: String, members: [String], createdBy: String) {
            self.id = id
            self.members = members
            self.createdBy = createdBy
        }
    }

    /// A group seed's payload (`gk`).
    public struct GroupKey: Codable, Sendable, Equatable {
        /// The group the seeds are for.
        public let groupId: String
        /// The seeds.
        public let keys: [Seed]
        /// The founding roster.
        public let group: Roster?

        /// Makes a group seed payload's fields.
        public init(groupId: String, keys: [Seed], group: Roster?) {
            self.groupId = groupId
            self.keys = keys
            self.group = group
        }
    }

    /// The body: empty for a control frame.
    public let body: String
    /// The control code, absent for a message.
    public let ctl: Int?
    /// The one id a receipt acknowledges.
    public let ack: String?
    /// The further ids a receipt, or a message's inline acks, acknowledge.
    public let acks: [String]?
    /// A reaction.
    public let rp: Reaction?
    /// A sealed profile.
    public let pr: Profile?
    /// A group seed.
    public let gk: GroupKey?

    /// Makes a content's fields.
    public init(
        body: String, ctl: Int? = nil, ack: String? = nil, acks: [String]? = nil, rp: Reaction? = nil, pr: Profile? = nil,
        gk: GroupKey? = nil
    ) {
        self.body = body
        self.ctl = ctl
        self.ack = ack
        self.acks = acks
        self.rp = rp
        self.pr = pr
        self.gk = gk
    }
}

/// How to open Carol's ratchet frames in `ios-emitted-v1.json` (phase P7b, companion change A10): the prekeys involved,
/// the draws Carol's engine took, Bob's one seal, and the order each reader opens in.
public struct EmittedRatchet: Codable, Sendable, Equatable {
    /// One signed prekey, its private half included: test keys and nothing else.
    public struct Prekey: Codable, Sendable, Equatable {
        /// Whose it is, by name.
        public let owner: String
        /// Its id.
        public let id: Int
        /// The `fixtureBytes(32, seed)` seed of its private key.
        public let seed: Int
        /// The X25519 private key, as hex.
        public let priv: String
        /// The X25519 public key, as hex.
        public let pub: String

        /// Makes a prekey entry.
        public init(owner: String, id: Int, seed: Int, priv: String, pub: String) {
            self.owner = owner
            self.id = id
            self.seed = seed
            self.priv = priv
            self.pub = pub
        }
    }

    /// One fixed draw: `keyPair` is an X25519 private key `fixtureBytes(32, seed)`, `iv` an AES-GCM IV
    /// `fixtureBytes(12, seed)`, `groupSeed` a group epoch seed `fixtureBytes(32, seed)`.
    public struct Draw: Codable, Sendable, Equatable {
        /// What was drawn.
        public let kind: String
        /// Its fixture seed.
        public let seed: Int

        /// Makes a draw entry.
        public init(kind: String, seed: Int) {
            self.kind = kind
            self.seed = seed
        }
    }

    /// The one frame a reader seals itself: Bob's reply, which gives him the epoch Carol's later frames are sealed to.
    public struct Seal: Codable, Sendable, Equatable {
        /// Who seals it, by name.
        public let sender: String
        /// To whom, by name.
        public let recipient: String
        /// Its frame id.
        public let id: String
        /// Its `sentAt`, and the clock it is sealed at.
        public let sentAt: Int64
        /// What it says.
        public let body: String
        /// The `EncEnvelope`'s `v`.
        public let version: Int
        /// The draws the seal takes, in order.
        public let draws: [Draw]
        /// Its plaintext, as hex.
        public let plaintext: String
        /// The frame as this port's stand-in for Bob sealed and signed it, as hex: its signed bytes are what a reader's own
        /// seal must make, short of the signature.
        public let wire: String

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case sender = "sender"
            case recipient = "recipient"
            case id = "id"
            case sentAt = "sentAt"
            case body = "body"
            case draws = "draws"
            case plaintext = "plaintext"
            case wire = "wire"
        }

        /// Makes a seal entry.
        public init(
            sender: String,
            recipient: String,
            id: String,
            sentAt: Int64,
            body: String,
            version: Int,
            draws: [Draw],
            plaintext: String,
            wire: String
        ) {
            self.sender = sender
            self.recipient = recipient
            self.id = id
            self.sentAt = sentAt
            self.body = body
            self.version = version
            self.draws = draws
            self.plaintext = plaintext
            self.wire = wire
        }
    }

    /// One reader's step: `open` a DM-form frame of ``EmittedVectors/frames`` (adopting the seeds a `CTL_GROUP_KEY`
    /// carries), `seal` the reader's own frame named in ``seals``, or `openGroup` a group-form frame.
    public struct Step: Codable, Sendable, Equatable {
        /// What the reader does.
        public let op: String
        /// The frame, by name.
        public let frame: String

        /// Makes a step.
        public init(op: String, frame: String) {
            self.op = op
            self.frame = frame
        }
    }

    /// How to read this section, for a reader who opens it cold.
    public let about: String
    /// The prekeys by name: the recipients' halves an init names, and the one Carol's ratchet profile publishes.
    public let prekeys: [String: Prekey]
    /// The draws Carol's engines took, in the order they took them.
    public let carolDraws: [Draw]
    /// The frames a reader seals itself, by name.
    public let seals: [String: Seal]
    /// Each reader's steps, in order, by the reader's name.
    public let replay: [String: [Step]]

    /// Makes the section.
    public init(about: String, prekeys: [String: Prekey], carolDraws: [Draw], seals: [String: Seal], replay: [String: [Step]]) {
        self.about = about
        self.prekeys = prekeys
        self.carolDraws = carolDraws
        self.seals = seals
        self.replay = replay
    }
}
