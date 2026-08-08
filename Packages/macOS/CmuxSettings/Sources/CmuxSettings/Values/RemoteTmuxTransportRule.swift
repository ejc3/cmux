import Darwin
import Foundation
import os

nonisolated private let remoteTmuxTransportRuleLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "RemoteTmuxTransport"
)

/// A single host-scoped transport rule stored under `remoteTmux.transports` in
/// `cmux.json`. It answers "how does this machine reach that host's tmux?" for
/// hosts where the answer is not the default.
///
/// ssh already has somewhere to put this: `~/.ssh/config` carries `ProxyCommand`,
/// `ProxyJump` and friends, and cmux honors it by doing nothing at all. A transport
/// that opens a socket of its own has no such file — everything it needs must be on
/// its argv — so a host reachable for ssh (through a jump host, bastion, corporate
/// proxy, container, VM) can be unreachable for that transport with nothing to
/// configure. This is that missing file.
///
/// Semantics mirror `~/.ssh/config` `Host` blocks, and deliberately match
/// ``TerminalUploadCommandRule``: a glob pattern (`*`, `?` via `fnmatch`), **first
/// match wins**, no match → cmux's built-in defaults.
///
/// ```json
/// "remoteTmux": {
///   "transports": [
///     { "hostPattern": "*.corp.example",
///       "transport": "et",
///       "command": ["/usr/local/bin/et-wrapper", "{host}", "-p", "{port}"],
///       "port": 8080 }
///   ]
/// }
/// ```
///
/// `command` is an argv, not a shell string: cmux spawns it directly, so nothing is
/// word-split or subject to a shell's quoting rules. Two placeholders are expanded,
/// and they exist because wrappers disagree about where the destination goes —
/// `et` takes it last, after `--`, while a wrapper may take it first and reject
/// anything before it.
///
/// - `{host}` → the ssh destination. When the argv omits it, cmux appends the
///   destination in the transport's own position, so a rule that only replaces the
///   binary needs no placeholder at all.
/// - `{port}` → the resolved transport port (``RemoteTmuxTransportRule/port``, else
///   the transport's default).
///
/// A literal brace is written `{{`.
public struct RemoteTmuxTransportRule: Codable, Sendable, Equatable, Hashable {
    /// Glob matched against the ssh destination's host component. `nil` (or an
    /// omitted key) matches every host.
    public var hostPattern: String?

    /// Which transport carries the control stream: `"ssh"` or `"et"`. Omitted
    /// leaves cmux's default (or whatever the caller asked for) in place.
    public var transport: String?

    /// The program and arguments that carry the control stream. Empty/omitted keeps
    /// the transport's built-in command.
    public var command: [String]

    /// The transport's port on the host — etserver's for `et`, not sshd's. Omitted
    /// keeps the transport's default.
    public var port: Int?

    /// Lets a rule be kept in the file but turned off, matching the upload rules.
    public var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case hostPattern
        case transport
        case command
        case port
        case enabled
    }

    public init(
        hostPattern: String? = nil,
        transport: String? = nil,
        command: [String] = [],
        port: Int? = nil,
        enabled: Bool = true
    ) {
        self.hostPattern = hostPattern
        self.transport = transport
        self.command = command
        self.port = port
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        // Reject unknown keys so a typo ("hostpattern", "cmd") can't silently leave a
        // rule as an accidental catch-all — same fail-closed decode as the upload rules.
        let rawKeys = try decoder.container(keyedBy: AnyCodingKey.self)
        let knownKeys: Set<String> = ["hostPattern", "transport", "command", "port", "enabled"]
        if let unknown = rawKeys.allKeys.first(where: { !knownKeys.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknown,
                in: rawKeys,
                debugDescription: "unknown remote-tmux transport rule key '\(unknown.stringValue)'"
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Omitted or explicit `null` → catch-all. Present-but-blank is rejected rather
        // than silently becoming one.
        if container.contains(.hostPattern) {
            if let raw = try container.decodeIfPresent(String.self, forKey: .hostPattern) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .hostPattern,
                        in: container,
                        debugDescription: "hostPattern must not be blank; omit it for a catch-all"
                    )
                }
                hostPattern = trimmed
            } else {
                hostPattern = nil
            }
        } else {
            hostPattern = nil
        }

        if let raw = try container.decodeIfPresent(String.self, forKey: .transport) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.knownTransports.contains(trimmed) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .transport,
                    in: container,
                    debugDescription:
                        "transport must be one of \(Self.knownTransports.sorted().joined(separator: ", ")); got '\(raw)'"
                )
            }
            transport = trimmed
        } else {
            transport = nil
        }

        let rawCommand = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        // A rule whose command is present but empty, or contains a blank word, is a
        // configuration mistake: spawning it would fail with no useful message.
        if container.contains(.command) {
            guard !rawCommand.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .command,
                    in: container,
                    debugDescription: "command must not be empty; omit it to keep the built-in"
                )
            }
            guard !rawCommand[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .command,
                    in: container,
                    debugDescription: "command's first word (the program) must not be blank"
                )
            }
            // Reject an unknown placeholder here rather than at spawn: `{hosts}` would
            // otherwise pass through literally, and the failure would surface as a
            // transport that cannot reach anything, with the typo nowhere in sight.
            if let bad = Self.unknownPlaceholder(in: rawCommand) {
                throw DecodingError.dataCorruptedError(
                    forKey: .command,
                    in: container,
                    debugDescription:
                        "unknown placeholder '{\(bad)}'; known placeholders are "
                        + Self.knownPlaceholders.sorted().map { "{\($0)}" }.joined(separator: ", ")
                        + " (write '{{' for a literal brace)"
                )
            }
        }
        command = rawCommand

        if let rawPort = try container.decodeIfPresent(Int.self, forKey: .port) {
            guard (1...65535).contains(rawPort) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .port,
                    in: container,
                    debugDescription: "port must be 1-65535; got \(rawPort)"
                )
            }
            port = rawPort
        } else {
            port = nil
        }

        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Transport names a rule may name. Kept as strings here so the settings package
    /// does not depend on the app's transport enum; the app validates the mapping.
    public static let knownTransports: Set<String> = ["ssh", "et"]

    /// Placeholders ``expand(command:host:port:)`` substitutes.
    public static let knownPlaceholders: Set<String> = ["host", "port"]

    // MARK: - Matching

    /// Normalizes an ssh destination to the host component used for matching: strips a
    /// leading `user@`, unwraps IPv6 brackets, lowercases. Same normalization the
    /// upload rules use, so one mental model covers both.
    public static func hostForMatching(_ destination: String) -> String {
        var value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let atIndex = value.lastIndex(of: "@") {
            value = String(value[value.index(after: atIndex)...])
        }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<close])
        }
        return value.lowercased()
    }

    /// ssh_config-style glob match via POSIX `fnmatch`.
    public static func hostMatches(pattern: String, host: String) -> Bool {
        let lowered = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        return lowered.withCString { patternPtr in
            host.withCString { hostPtr in
                fnmatch(patternPtr, hostPtr, 0) == 0
            }
        }
    }

    /// The first enabled rule matching `destination`, or nil when none does (the caller
    /// then uses cmux's built-in defaults). First match wins, as in `~/.ssh/config`.
    public static func firstMatch(
        in rules: [RemoteTmuxTransportRule],
        destination: String
    ) -> RemoteTmuxTransportRule? {
        let host = hostForMatching(destination)
        for rule in rules where rule.enabled {
            guard let pattern = rule.hostPattern else { return rule }
            if hostMatches(pattern: pattern, host: host) { return rule }
        }
        return nil
    }

    // MARK: - Placeholder expansion

    /// The result of expanding a configured command.
    public struct ExpandedCommand: Sendable, Equatable {
        /// argv with placeholders substituted.
        public var argv: [String]
        /// Whether `{host}` appeared. When false the caller appends the destination in
        /// the transport's own position, so a rule that only swaps the binary works
        /// without naming a placeholder.
        public var containsHost: Bool
    }

    /// Substitutes `{host}` and `{port}`. Braces double to escape, as in a format
    /// string: `{{` is a literal `{` and `}}` a literal `}`, so `{{host}}` is the text
    /// `{host}` rather than a substitution.
    ///
    /// Total by construction: unknown placeholders are rejected at decode time, so
    /// there is no failure mode left to handle at spawn.
    public static func expand(command: [String], host: String, port: Int) -> ExpandedCommand {
        var sawHost = false
        let argv = command.map { word -> String in
            var out = ""
            var index = word.startIndex
            while index < word.endIndex {
                let character = word[index]
                let next = word.index(after: index)
                if character == "{", next < word.endIndex, word[next] == "{" {
                    out.append("{")
                    index = word.index(after: next)
                } else if character == "}", next < word.endIndex, word[next] == "}" {
                    out.append("}")
                    index = word.index(after: next)
                } else if character == "{", let close = word[next...].firstIndex(of: "}") {
                    switch String(word[next..<close]) {
                    case "host": out += host; sawHost = true
                    case "port": out += String(port)
                    case let other: out += "{\(other)}"  // unreachable: rejected at decode
                    }
                    index = word.index(after: close)
                } else {
                    // A lone or unclosed brace is not a placeholder; keep it literal.
                    out.append(character)
                    index = next
                }
            }
            return out
        }
        return ExpandedCommand(argv: argv, containsHost: sawHost)
    }

    /// The first unknown placeholder name in `command`, or nil when all are known.
    /// Used by decoding to fail closed on a typo.
    static func unknownPlaceholder(in command: [String]) -> String? {
        for word in command {
            var rest = Substring(word)
            while let open = rest.firstIndex(of: "{") {
                let afterOpen = rest.index(after: open)
                if afterOpen < rest.endIndex, rest[afterOpen] == "{" {
                    rest = rest[rest.index(after: afterOpen)...]
                    continue
                }
                guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
                let name = String(rest[afterOpen..<close])
                if !knownPlaceholders.contains(name) { return name }
                rest = rest[rest.index(after: close)...]
            }
        }
        return nil
    }
}

/// Dynamic key used only to enumerate the keys actually present in a rule object, so
/// unknown ones can be rejected in ``RemoteTmuxTransportRule/init(from:)``.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { nil }
}

// MARK: - SettingCodable

/// Stored as a nested JSON object. Decode is all-or-nothing per rule (a malformed rule
/// is rejected and logged), and `Array`'s conformance makes a malformed list reject as
/// a whole, so a typo never silently leaves some hosts on a different transport.
extension RemoteTmuxTransportRule: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> RemoteTmuxTransportRule? {
        decodeFromJSON(raw)
    }

    public func encodeForUserDefaults() -> Any {
        encodeForJSON()
    }

    public static func decodeFromJSON(_ raw: Any?) -> RemoteTmuxTransportRule? {
        // Only a JSON object is a valid rule. Guarding on the dictionary shape also
        // avoids `JSONSerialization`'s uncatchable exception on a non-collection value
        // (a scalar element like ["et"]), keeping bad config fail-closed, not
        // fail-crash.
        guard let object = raw as? [String: Any] else {
            if raw != nil, !(raw is NSNull) {
                remoteTmuxTransportRuleLogger.error("remoteTmux.transports: ignoring non-object rule")
            }
            return nil
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(RemoteTmuxTransportRule.self, from: data)
        } catch {
            remoteTmuxTransportRuleLogger.error(
                "remoteTmux.transports: ignoring invalid rule: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }
}
