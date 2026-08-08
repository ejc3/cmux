# Host-scoped transport rules

## The problem

`cmux ssh-tmux host` works against a host that ssh can reach through a jump host,
bastion or corporate proxy, because ssh has somewhere to record that: `~/.ssh/config`
carries `ProxyCommand`, `ProxyJump`, `HostName`, and cmux honors all of it by doing
nothing at all.

`--transport et` against the same host fails, and the reason is not et. et makes two
hops: an ssh bootstrap to reach `etserver`, then a TCP connection of its own to
etserver's port. The bootstrap goes through the ssh config like everything else. The
second hop dials the destination by name, directly, and on a network where that name
does not resolve there is nothing to dial and nowhere to say otherwise. et has no
config file; everything it needs must be on its argv.

The failure is silent in the worst way. The ssh hop succeeds — on a host with 2FA the
user even completes a touch — and then nothing happens for thirty seconds until
`awaitFirstWorkspaces` gives up and the error reads `could not mirror any tmux session
on <host>`, which names tmux and points nowhere near the cause.

So the gap is not a missing flag. It is that one transport has a standard place to
declare reachability and the other has none.

## The shape

`remoteTmux.transports` in `cmux.json`: a list of host-scoped rules, matched the way
`~/.ssh/config` `Host` blocks are matched.

```json
"remoteTmux": {
  "transports": [
    { "hostPattern": "*.corp.example",
      "transport": "et",
      "command": ["/usr/local/bin/et-wrapper", "-et", "{host}", "-p", "{port}"],
      "port": 8080 }
  ]
}
```

With that in place, `cmux ssh-tmux host.corp.example` works with no flags. That is the
point: the person using it never learns that their network needs a wrapper, in the
same way they never think about `ProxyCommand` when they type `ssh`.

A rule sets any of four things, all optional:

| field | meaning | omitted |
|---|---|---|
| `hostPattern` | fnmatch glob against the destination's host | matches every host |
| `transport` | `ssh` or `et` | the caller's choice stands |
| `command` | argv carrying the control stream | the transport's built-in |
| `port` | the transport's port **on the host** | the transport's default |

`enabled: false` keeps a rule in the file without applying it.

### Why an argv, not a shell string

`command` is `["prog", "arg"]`, not `"prog arg"`. cmux spawns it directly, so nothing
is word-split and no quoting rules apply. A path with a space is just a string.

### Why placeholders

Wrappers disagree about where the destination goes. `et` takes it last, after `--`. A
wrapper may take it first and reject anything before it — measured against one such
wrapper, passing et's own order produced `flag provided but not defined: -p`, because
its argument parser stops at the first non-flag word.

So `{host}` and `{port}` are expanded anywhere in the argv, and **a command with no
`{host}` gets the destination appended in the transport's own position**. A rule that
only swaps the binary needs no placeholder at all; a rule for a host-first wrapper
writes `{host}` where it belongs.

Braces double to escape, as in a format string: `{{` is `{`, `}}` is `}`. An unknown
placeholder is rejected when the rule is decoded, not at spawn — `{hosts}` would
otherwise pass through literally and surface as a transport that reaches nothing, with
the typo nowhere in the error.

### Decoding fails closed

Unknown keys, blank patterns, unknown transports, empty commands, blank programs and
out-of-range ports are all rejected, and the rejected rule is logged and skipped. A
typo must never leave a rule that quietly does something else — the same reasoning, and
the same code shape, as `terminal.uploadCommands`.

## Precedence

Most specific wins:

1. an explicit CLI flag (`--transport`, `--transport-command`, `--transport-port`)
2. the first enabled matching rule
3. the transport's built-in default

Per field, not per rule: a rule that sets only `port` leaves the transport alone, and a
`--transport-port` on the command line overrides only that rule's port.

## What the CLI keeps

```
cmux ssh-tmux <destination> [--transport ssh|et]
                            [--transport-port <n>]
                            [--transport-command "<prog> [args…]"]
```

The flags stay, as per-invocation overrides for debugging a rule before committing it
to the file. They are not the product surface; the file is.

Two validation changes go with this:

- `--transport-port` with `--transport ssh` becomes an error. It is silently ignored
  today — `profile(port:)` discards it for ssh — and a silent no-op is exactly the
  failure mode this whole document exists to remove.
- An unreachable transport endpoint should fail fast and name itself, rather than
  arriving as a thirty-second timeout attributed to tmux.

## The seam change

`RemoteTmuxTransportProfile.executablePath() -> String` becomes
`launchArgv() -> [String]`: program plus leading arguments. Both profiles implement it,
so there is one code path and no et-shaped branch. The ssh profile returns its ssh
executable and is otherwise untouched, which keeps `--transport ssh` bit-for-bit what
it is today.

`RemoteTmuxHost` gains the resolved command, and it joins `connectionHash` — two
different commands to one destination are two endpoints, exactly as transport and port
already are, or the registry hands an attach a connection whose command is wrong.

Everything downstream is unchanged. The spawn still goes through `/usr/bin/script` when
the profile requires a pty, one-shots still ride ssh during bootstrap, and the single
multiplexed control stream is still the only thing a transport carries.

## Status

Implemented and tested in `CmuxSettings` (289 tests in 43 suites): the rule type, its
fail-closed decoding, matching, and placeholder expansion.

Not yet written: `launchArgv()`, the host field and its `connectionHash` contribution,
rule resolution at the call site, the CLI flag and its help, the `transport_command`
RPC parameter, and the two validation changes above.

Not yet verified anywhere: the et path completing end to end against a host that needs
a rule. A wrapper has been shown by hand to carry a real `tmux -CC` stream — `%begin`,
`%end`, `%session-changed` — under a pty, with the destination first, so the shape is
known to work. cmux itself has never completed that path.
