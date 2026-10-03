import KnitControl
import KnitTestSupport
import KnitWire
import Testing

/// The control lines and the JSON they come back as.
@Suite struct ControlLineTests {
    // MARK: Control lines

    @Test func everyCommandParses() throws {
        let peer = fixtureNodeId(4)
        let cases: [(String, ControlCommand)] = [
            (#"{"cmd":"status"}"#, .status),
            (#"{"cmd":"peers"}"#, .peers),
            (#"{"cmd":"links"}"#, .links),
            (#"{"cmd":"digest"}"#, .digest),
            (#"{"cmd":"custody"}"#, .custody),
            (#"{"cmd":"stop"}"#, .stop),
            (#"{"cmd":"start"}"#, .start),
            (#"{"cmd":"quit"}"#, .quit),
            (#"{"cmd":"room","text":"hi"}"#, .room("hi")),
            (#"{"cmd":"dm","to":"\#(peer)","text":"psst"}"#, .directMessage(to: peer, text: "psst")),
            (#"{"cmd":"accept","conv":"\#(peer)"}"#, .accept(peer.string)),
            (#"{"cmd":"accept","peer":"\#(peer)"}"#, .accept(peer.string)),
            (#"{"cmd":"name","name":"B"}"#, .name("B", status: nil, openToChat: nil)),
            (#"{"cmd":"name","status":"s","openToChat":true}"#, .name(nil, status: "s", openToChat: true)),
            (#"{"cmd":"avatar","jpeg":"AQID"}"#, .avatar(.bytes([1, 2, 3]))),
            (#"{"cmd":"avatar","path":"/tmp/a.jpg"}"#, .avatar(.file("/tmp/a.jpg"))),
            (#"{"cmd":"avatar","clear":true,"jpeg":"AQID"}"#, .avatar(.clear)),
            (#"{"cmd":"deny-link","peer":"\#(peer)"}"#, .denyLink(peer)),
            (#"{"cmd":"allow-link","peer":"\#(peer)"}"#, .allowLink(peer)),
            (#"{"cmd":"messages","conv":"nearby"}"#, .messages("nearby", limit: 20)),
            (#"{"cmd":"messages","conv":"nearby","limit":0}"#, .messages("nearby", limit: 1)),
            (#"{"cmd":"group-create","members":["\#(peer)"]}"#, .group(.create([peer]))),
            (#"{"cmd":"group-send","conv":"g-1","text":"hi"}"#, .group(.send("g-1", text: "hi"))),
            (#"{"cmd":"group-rename","conv":"g-1","name":"Pair"}"#, .group(.rename("g-1", name: "Pair"))),
            (#"{"cmd":"group-leave","conv":"g-1"}"#, .group(.leave("g-1"))),
            (#"{"cmd":"groups"}"#, .group(.list)),
        ]
        for (line, command) in cases {
            #expect(try ControlRequest.parse(line).get() == ControlRequest(command: command, tag: nil), "\(line)")
        }
        #expect(try ControlRequest.parse(#"{"cmd":"status","tag":"t1"}"#).get().tag == "t1")
    }

    @Test func everyErrorSaysWhatWentWrong() {
        #expect(ControlError.invalid("jpeg").message == "not a valid jpeg")
        #expect(ControlError.missing("text").message == "missing text")
    }

    @Test func badLinesSayWhy() {
        let cases: [(String, ControlError)] = [
            ("not json", .notJSON),
            (#"{"text":"no cmd"}"#, .notJSON),
            (#"{"cmd":"fly"}"#, .unknownCommand("fly")),
            (#"{"cmd":"room"}"#, .missing("text")),
            (#"{"cmd":"dm","text":"x"}"#, .missing("to")),
            (#"{"cmd":"dm","to":"NOPE","text":"x"}"#, .invalidNodeId("NOPE")),
            (#"{"cmd":"accept"}"#, .missing("conv")),
            (#"{"cmd":"avatar"}"#, .missing("jpeg")),
            (#"{"cmd":"avatar","jpeg":"not base64!"}"#, .invalid("jpeg")),
            (#"{"cmd":"deny-link"}"#, .missing("peer")),
            (#"{"cmd":"messages"}"#, .missing("conv")),
            (#"{"cmd":"group-create"}"#, .missing("members")),
            (#"{"cmd":"group-create","members":["NOPE"]}"#, .invalidNodeId("NOPE")),
            (#"{"cmd":"group-send","conv":"g-1"}"#, .missing("text")),
            (#"{"cmd":"group-send","text":"hi"}"#, .missing("conv")),
            (#"{"cmd":"group-rename","conv":"g-1"}"#, .missing("name")),
            (#"{"cmd":"group-leave"}"#, .missing("conv")),
        ]
        for (line, error) in cases {
            #expect(throws: error) { try ControlRequest.parse(line).get() }
        }
        #expect(ControlError.refused("because").message == "because")
        #expect(ControlError.notJSON.message.contains("JSON"))
        #expect(ControlError.unknownCommand("fly").message == "unknown command fly")
        #expect(ControlError.missing("text").message == "missing text")
        #expect(ControlError.invalidNodeId("x").message == "not a node id: x")
    }

    @Test func everyCommandHasTheNameItWasSentAs() {
        let peer = fixtureNodeId(4)
        let names = [
            ControlCommand.status, .peers, .links, .room(""), .directMessage(to: peer, text: ""), .accept(""),
            .name(nil, status: nil, openToChat: nil),
            .denyLink(peer), .allowLink(peer), .digest, .custody, .messages("", limit: 1), .stop, .start, .quit,
            .group(.create([])), .group(.send("", text: "")), .group(.rename("", name: "")), .group(.leave("")), .group(.list),
        ]
        .map(\.name)
        #expect(
            names == [
                "status", "peers", "links", "room", "dm", "accept", "name", "deny-link", "allow-link", "digest", "custody",
                "messages", "stop", "start", "quit", "group-create", "group-send", "group-rename", "group-leave", "groups",
            ])
    }

    // MARK: JSON

    @Test func aLineIsCompactWithSortedKeys() {
        let value: JSONValue = ["b": 1, "a": ["x", true, .null], "c": ["n": -2], "path": "/org/bluez"]
        #expect(value.line == #"{"a":["x",true,null],"b":1,"c":{"n":-2},"path":"/org/bluez"}"#)
        #expect(JSONValue.text(nil) == .null)
        #expect(JSONValue.text("x") == .string("x"))
    }
}
