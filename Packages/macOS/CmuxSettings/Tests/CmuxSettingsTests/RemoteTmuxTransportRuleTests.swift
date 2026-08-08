import Foundation
import Testing
@testable import CmuxSettings

@Suite("RemoteTmuxTransportRule")
struct RemoteTmuxTransportRuleTests {
    private func decode(_ json: String) -> RemoteTmuxTransportRule? {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return RemoteTmuxTransportRule.decodeFromJSON(object)
    }

    // MARK: - Accepted shapes

    @Test func decodesAFullRule() throws {
        let rule = try #require(decode("""
        {"hostPattern":"*.corp.example","transport":"et",
         "command":["/usr/local/bin/wrap","-et","{host}","-p","{port}"],
         "port":8080,"enabled":true}
        """))
        #expect(rule.hostPattern == "*.corp.example")
        #expect(rule.transport == "et")
        #expect(rule.command == ["/usr/local/bin/wrap", "-et", "{host}", "-p", "{port}"])
        #expect(rule.port == 8080)
        #expect(rule.enabled)
    }

    @Test func omittedHostPatternIsACatchAll() throws {
        let rule = try #require(decode(#"{"transport":"et"}"#))
        #expect(rule.hostPattern == nil)
    }

    @Test func explicitNullHostPatternIsACatchAll() throws {
        let rule = try #require(decode(#"{"hostPattern":null,"transport":"et"}"#))
        #expect(rule.hostPattern == nil)
    }

    @Test func enabledDefaultsToTrue() throws {
        let rule = try #require(decode(#"{"transport":"ssh"}"#))
        #expect(rule.enabled)
    }

    @Test func aRuleMayOnlySetThePort() throws {
        // Keeping the built-in command and only moving the port is the smallest
        // useful rule; it must not require naming a transport or a command.
        let rule = try #require(decode(#"{"hostPattern":"*.example","port":8080}"#))
        #expect(rule.transport == nil)
        #expect(rule.command.isEmpty)
        #expect(rule.port == 8080)
    }

    @Test func transportNameIsCaseInsensitiveAndTrimmed() throws {
        let rule = try #require(decode(#"{"transport":"  ET "}"#))
        #expect(rule.transport == "et")
    }

    // MARK: - Rejected shapes (fail closed)

    @Test func rejectsUnknownKey() {
        // A typo must not leave a rule that silently does something else.
        #expect(decode(#"{"hostpattern":"*.example","transport":"et"}"#) == nil)
    }

    @Test func rejectsBlankHostPattern() {
        // Present-but-blank is a mistake, not a catch-all.
        #expect(decode(#"{"hostPattern":"   ","transport":"et"}"#) == nil)
    }

    @Test func rejectsUnknownTransport() {
        #expect(decode(#"{"transport":"mosh"}"#) == nil)
    }

    @Test func rejectsEmptyCommandArray() {
        #expect(decode(#"{"command":[]}"#) == nil)
    }

    @Test func rejectsBlankProgram() {
        #expect(decode(#"{"command":["  ","-et"]}"#) == nil)
    }

    @Test func rejectsOutOfRangePort() {
        #expect(decode(#"{"port":0}"#) == nil)
        #expect(decode(#"{"port":65536}"#) == nil)
    }

    @Test func rejectsANonObjectRule() {
        // A scalar element would otherwise reach JSONSerialization and throw an
        // uncatchable exception rather than being ignored.
        #expect(RemoteTmuxTransportRule.decodeFromJSON("et") == nil)
        #expect(RemoteTmuxTransportRule.decodeFromJSON(42) == nil)
        #expect(RemoteTmuxTransportRule.decodeFromJSON(nil) == nil)
    }

    // MARK: - Round trip

    @Test func roundTripsThroughJSON() throws {
        let original = RemoteTmuxTransportRule(
            hostPattern: "*.corp.example",
            transport: "et",
            command: ["/usr/local/bin/wrap", "{host}"],
            port: 8080,
            enabled: false
        )
        let decoded = try #require(RemoteTmuxTransportRule.decodeFromJSON(original.encodeForJSON()))
        #expect(decoded == original)
    }

    // MARK: - Catalog wiring

    @Test func catalogExposesTheKeyAndDefaultsToEmpty() {
        let key = SettingCatalog().remoteTmux.transports
        #expect(key.id == "remoteTmux.transports")
        #expect(key.defaultValue.isEmpty)
    }
}
