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

    @Test func rejectsUnknownPlaceholder() {
        // A typo'd placeholder would otherwise pass through literally and surface as a
        // transport that reaches nothing, with the typo nowhere in the error.
        #expect(decode(#"{"command":["wrap","{hosts}"]}"#) == nil)
        #expect(decode(#"{"command":["wrap","{Host}"]}"#) == nil)
    }

    @Test func acceptsKnownPlaceholdersAndEscapedBraces() throws {
        let rule = try #require(decode(#"{"command":["wrap","{host}","-p","{port}","{{literal}}"]}"#))
        #expect(rule.command.count == 5)
    }

    // MARK: - Matching

    @Test func firstMatchWins() {
        let rules = [
            RemoteTmuxTransportRule(hostPattern: "*.a.example", transport: "ssh"),
            RemoteTmuxTransportRule(hostPattern: "*.example", transport: "et"),
        ]
        #expect(RemoteTmuxTransportRule.firstMatch(in: rules, destination: "h.a.example")?.transport == "ssh")
        #expect(RemoteTmuxTransportRule.firstMatch(in: rules, destination: "h.b.example")?.transport == "et")
        #expect(RemoteTmuxTransportRule.firstMatch(in: rules, destination: "h.other") == nil)
    }

    @Test func disabledRulesAreSkippedNotMatched() {
        // A disabled first rule must not shadow a later one that does apply.
        let rules = [
            RemoteTmuxTransportRule(hostPattern: "*.example", transport: "ssh", enabled: false),
            RemoteTmuxTransportRule(hostPattern: "*.example", transport: "et"),
        ]
        #expect(RemoteTmuxTransportRule.firstMatch(in: rules, destination: "h.example")?.transport == "et")
    }

    @Test func matchingIgnoresUserAndCase() {
        let rules = [RemoteTmuxTransportRule(hostPattern: "*.EXAMPLE", transport: "et")]
        #expect(RemoteTmuxTransportRule.firstMatch(in: rules, destination: "me@Host.Example") != nil)
    }

    @Test func matchingUnwrapsIPv6Brackets() {
        let rules = [RemoteTmuxTransportRule(hostPattern: "::1", transport: "et")]
        #expect(RemoteTmuxTransportRule.firstMatch(in: rules, destination: "[::1]") != nil)
    }

    @Test func aPatternlessRuleIsACatchAll() {
        let rules = [RemoteTmuxTransportRule(transport: "et")]
        #expect(RemoteTmuxTransportRule.firstMatch(in: rules, destination: "anything") != nil)
    }

    // MARK: - Expansion

    @Test func expandsHostAndPort() {
        let out = RemoteTmuxTransportRule.expand(
            command: ["/bin/wrap", "-et", "{host}", "-p", "{port}"], host: "h.example", port: 8080)
        #expect(out.argv == ["/bin/wrap", "-et", "h.example", "-p", "8080"])
        #expect(out.containsHost)
    }

    @Test func reportsWhenHostIsAbsentSoTheCallerAppendsIt() {
        // A rule that only swaps the binary must work without naming a placeholder.
        let out = RemoteTmuxTransportRule.expand(command: ["/bin/my-et"], host: "h", port: 22)
        #expect(out.argv == ["/bin/my-et"])
        #expect(!out.containsHost)
    }

    @Test func expandsPlaceholdersInsideAWord() {
        let out = RemoteTmuxTransportRule.expand(
            command: ["--to={host}:{port}"], host: "h.example", port: 8080)
        #expect(out.argv == ["--to=h.example:8080"])
    }

    @Test func doubleBraceIsALiteralBrace() {
        let out = RemoteTmuxTransportRule.expand(command: ["{{host}}"], host: "h", port: 22)
        #expect(out.argv == ["{host}"])
        #expect(!out.containsHost)
    }

    @Test func repeatedPlaceholdersAllExpand() {
        let out = RemoteTmuxTransportRule.expand(command: ["{host}-{host}"], host: "h", port: 22)
        #expect(out.argv == ["h-h"])
    }

    @Test func unclosedBraceStaysLiteral() {
        let out = RemoteTmuxTransportRule.expand(command: ["{host", "ok"], host: "h", port: 22)
        #expect(out.argv == ["{host", "ok"])
        #expect(!out.containsHost)
    }

    // MARK: - Catalog wiring

    @Test func catalogExposesTheKeyAndDefaultsToEmpty() {
        let key = SettingCatalog().remoteTmux.transports
        #expect(key.id == "remoteTmux.transports")
        #expect(key.defaultValue.isEmpty)
    }
}
