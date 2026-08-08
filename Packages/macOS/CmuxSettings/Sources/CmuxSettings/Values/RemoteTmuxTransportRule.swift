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
