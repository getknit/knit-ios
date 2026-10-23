import Testing

@testable import KnitAppCore

/// The structural redaction a report's free text passes through, one rule at a time (knit-next `CrashRedactorTest`).
@Suite struct CrashRedactorTests {
    @Test(arguments: [
        ("file:///private/var/mobile/Containers/Data/Application/x/a.db", "file://[uri]"),
        ("dial https://relay.example.org:8443/s?k=secret failed", "dial https://relay.example.org:8443/[path] failed"),
        ("wss://relay.example.org", "wss://relay.example.org"),
        ("at /private/var/containers/Bundle/Application/5F2C/Knit.app/Knit", "at [path]"),
        ("/var/mobile/Library/x and /Users/jeff/Library/y", "[path] and [path]"),
        ("/System/Library/Frameworks/UIKit.framework", "/System/Library/Frameworks/UIKit.framework"),
        ("number 12345 67890 12345 67890 12345", "number [safety-number]"),
        ("group g-0123456789abcdef01234567 left", "group [group] left"),
        ("peer abcdefghijklmnopqrstuvwxyz dropped", "peer [node] dropped"),
        ("peer abcdefghijklmnopqrstuvwxyza27 dropped", "peer abcdefghijklmnopqrstuvwxyza27 dropped"),
        ("blob 0123456789abcdef0123 gone", "blob [hex] gone"),
        ("key Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4 bad", "key [b64] bad"),
        (
            "-[UICollectionView dequeueReusableCellWithReuseIdentifier:forIndexPath:]",
            "-[UICollectionView dequeueReusableCellWithReuseIdentifier:forIndexPath:]"
        ),
        ("from Zoë to 山田", "from [text] to [text]"),
        ("Namespace SIGNAL, Code 5 Trace/BPT trap: 5", "Namespace SIGNAL, Code 5 Trace/BPT trap: 5"),
    ])
    func eachRuleTakesOutItsKind(_ text: String, _ expected: String) {
        #expect(CrashRedactor.redact(text) == expected)
    }

    @Test func redactingTwiceChangesNothing() throws {
        let text = """
            file:///a https://h/p /var/x 12345 12345 12345 12345 g-0123456789abcdef01234567 abcdefghijklmnopqrstuvwxyz \
            0123456789abcdef Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4 Zoë
            """
        let once = try #require(CrashRedactor.redact(text))
        #expect(CrashRedactor.redact(once) == once)
        #expect(once == "file://[uri] https://h/[path] [path] [safety-number] [group] [node] [hex] [b64] [text]")
    }

    @Test func aLongFieldIsCutAndSaysByHowMuch() throws {
        let redacted = try #require(CrashRedactor.redact(String(repeating: "ab ", count: 200)))
        #expect(redacted == String(repeating: "ab ", count: 100) + "...(+300)")
    }
}
