# AGENTS.md

Guide for agentic coding assistants working in this repository.

## Project

Stardust is a DHCP server (RFC 2131/2132) written in **Zig 0.15.x**. It
manages IP leases, integrates with RFC 2136 dynamic DNS updates, and supports
active-active redundancy via UDP lease synchronisation. Configuration is YAML.

## Commands

```bash
zig build                                   # build (release)
zig build -Doptimize=Debug                  # build (debug)
zig build test                              # run all tests
zig build test -Dtest_filter="test name"    # run one test by name substring
zig fmt .                                   # format all Zig files
zig build check                             # type-check without emitting binary
```

Always run `zig build test` after changes. All tests must pass before committing.

## Architecture

```
main.zig
  ├── src/config.zig   — YAML config loading (uses zig-yaml)
  ├── src/state.zig    — Lease store; persists to leases.json
  ├── src/dns.zig      — RFC 2136 DNS UPDATE with TSIG auth
  ├── src/dhcp.zig     — Core DHCP server (UDP port 67, poll-based loop)
  ├── src/sync.zig     — Lease sync protocol (UDP, AES-256-GCM, port 647)
  └── src/probe.zig    — Pre-offer conflict detection (ARP/ICMP)
```

- `config.zig` imports `dns.zig` for `dns_mod.Config`; **`dns.zig` must not
  import `config.zig`** — circular dependency.
- `std_options` / `logFn` must live in `main.zig` (root module only).
- `sync.zig` reuses `dns_mod.parseTsigKey`, `TsigKey`, and `Algorithm` (all
  declared `pub` in `dns.zig`).

## Zig 0.15.x API — common pitfalls

These APIs differ from older Zig versions and from what most LLM training data
reflects. Get these right.

**ArrayList is now unmanaged** — no `init(allocator)`:
```zig
// WRONG (old API):
var list = std.ArrayList(T).init(allocator);
list.append(item);
list.deinit();

// CORRECT (0.15.x):
var list = std.ArrayList(T){};
try list.append(allocator, item);
list.deinit(allocator);
```

**JSON stringify** — `stringifyAlloc` was removed:
```zig
// WRONG:  std.json.stringifyAlloc(allocator, value, .{})
// CORRECT:
const s = try std.json.Stringify.valueAlloc(allocator, value, .{});
```

**HKDF** — `extract` returns the PRK, does not write to a pointer:
```zig
// WRONG:  HkdfSha256.extract(&prk, salt, ikm);
// CORRECT:
const prk = HkdfSha256.extract(salt, ikm);
```

**AES-GCM** — the `tag` parameter is `*[tag_length]u8`, not `[]u8`. Getting a
pointer-to-fixed-array from a runtime offset requires the two-step slice:
```zig
// WRONG:  buf[start .. start + 16]          → type []u8
// CORRECT:
buf[start..][0..16]                          // → type *[16]u8
```

**`std.posix.timeval`** fields: `.sec` and `.usec` (not `.tv_sec`/`.tv_usec`).

**`nosuspend`** does not exist in 0.15.x — remove it if encountered.

**`build.zig`** must use the module API, not `root_source_file:`:
```zig
const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), ... });
mod.addImport("yaml", yaml_mod);
const exe = b.addExecutable(.{ .name = "stardust", .root_module = mod });
```

## Dependencies

Single external dep: `zig-yaml` v0.2.0. It is declared in `build.zig.zon` and
passed to the main module in `build.zig`. If you add a new module that needs
YAML, follow the same `addImport` pattern in `build.zig`.

**zig-yaml untyped walk pattern** (typed parse does not support StringHashMap):
```zig
const root = doc.docs.items[0].asMap() orelse return;
if (root.get("key")) |val| {
    if (val.asScalar()) |s| { ... }
    if (val.asList()) |list| { for (list) |item| { ... } }
    if (val.asMap()) |m| { ... }
}
```

## Naming conventions

| Kind | Style |
|---|---|
| Types (struct, enum, error set) | `PascalCase` |
| Functions, variables | `camelCase` |
| Constants | `snake_case` or `ALL_CAPS` |
| Test names | plain English, `"verb: subject detail"` |

## Key design patterns

**Config parsing** (`src/config.zig`): two-phase — untyped YAML walk into a
`Config` struct with allocated strings; callers call `cfg.deinit()` to free.

**State store** (`src/state.zig`): `addLease()` dupes all strings; the store
owns them. `removeLease()` on a reserved lease zeroes `expires` rather than
deleting. `forceRemoveLease()` deletes unconditionally (used by sync).

**Lease fields**: `reserved: bool = false`, `last_modified: i64 = 0`, and
`local: bool = false` all have JSON-compatible defaults. `local` is set to
`true` in `createAck` (this server issued the DHCPACK) and forced back to
`false` in `applyLeaseUpdate` (DNS ownership never transfers via sync).

**Sync crypto**: HKDF-SHA-256 derives a 32-byte AES-256-GCM key from the TSIG
secret. Every datagram has a 26-byte authenticated-data header (version, type,
timestamp, nonce, payload_len) followed by ciphertext and a 16-byte AEAD tag.
Anti-replay window: ±300 s on the timestamp field.

**Pool hash** (`config_mod.computePoolHash`): SHA-256 over subnet/mask/pool
bounds/lease_time/sorted reservations/sorted static routes. Two servers must
produce identical hashes to authenticate each other during sync handshake.

**DNS ownership in HA groups** (`shouldHandleDns` in `dhcp.zig`): DNS updates
(adds and deletes) are sent only when `lease.local == true` OR when this server
is the lowest-IP active node (`sync_mgr.isLowestActivePeer(server_ip)`). The
lowest-IP election ensures exactly one standby takes over DNS when the originator
goes offline, for groups of any size.

**Log level**: `config_mod.LogLevel` is `err | warn | info | verbose | debug`.
Verbose messages use `std.log.scoped(.verbose)` on top of `std.log.debug`;
`logFn` detects the `.verbose` scope at comptime and maps it to effective
priority 3 (between info=2 and debug=4). The `{f}` format specifier invokes
`EscapedStr.format(writer: anytype) !void` (2-arg signature — no `comptime fmt`
or `FormatOptions` params).
