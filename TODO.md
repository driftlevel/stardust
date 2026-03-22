# Stardust TODO

## Pending

---

## Completed

**Option 55 (Parameter Request List) filtering** ✓ (RFC 2132 §9.8)
`isRequestedCode(prl, code)` and `isRequested(prl, OptionCode)` helpers gate
every optional option in `createOffer`, `createAck`, and `handleInform`.
Options 53 (MessageType) and 54 (ServerIdentifier) are always included per RFC.

**Option 82 (Relay Agent Information) logged** ✓ (RFC 3046)
`logRelayAgentInfo()` parses sub-options 1 (circuit-id) and 2 (remote-id)
and logs them at DEBUG level. Called from `createOffer`, `createAck`, and `handleInform`.

**Pool range validated against subnet** ✓
`validatePoolRange()` in `config.zig` logs warnings when `pool_start`/`pool_end`
are outside the subnet, are invalid IPs, or when `pool_start > pool_end`. Called
at end of `load()`.

**Subnet mask validated as a proper CIDR mask** ✓
`parseMask()` now checks that `~mask & (~mask + 1) == 0` (contiguous prefix
property). Non-CIDR masks like `255.0.255.0` are rejected with `error.InvalidConfig`.

**State file atomically written** ✓
`save()` in `state.zig` writes to `<path>.tmp` then uses `std.fs.rename` to
atomically replace the file. Prevents corruption on mid-write crash.

**DHCPINFORM handled** ✓
`handleInform()` replies with DHCPACK, `yiaddr=0`, includes all config
options (subnet mask, router, DNS, domain name, dhcp_options). No lease is
created. `ciaddr` and `hops` are echoed from the request.

**Client ID (option 61) stored and used** ✓
`getClientId()` extracts option 61 raw bytes, stored as lowercase hex in
`Lease.client_id`. `allocateIp` checks by client_id before chaddr so a
client that changes MAC retains its lease. `isIpValid` accepts client_id
match for renewals. `createAck` stores the client_id on confirmed leases.

**`hops` echoed in responses** ✓
`createOffer`, `createAck`, `createNak`, and `handleInform` all copy
`req_header.hops` into the response so relay agents can enforce hop limits.

**Relay response routing and broadcast flag** ✓
`resolveDestination()` applies RFC 2131 §4.1 priority rules: relay agent
(`giaddr != 0`) → unicast to `giaddr:67`; renewal (`ciaddr != 0`) → unicast
to `ciaddr:68`; broadcast bit set → `255.255.255.255:68`; else → broadcast
fallback (ARP unicast to `yiaddr` not implemented).

**DHCPDECLINE pool-exhaustion defence** ✓
Per-MAC cooldown after threshold declines within a sliding window
(`decline_threshold=3` / `decline_window_secs=60` / `decline_cooldown_secs=300`).
Global rate limit of 20 declines per 5-minute window to block MAC-rotation
attacks. Quarantine period `max(lease_time/10, 300s)`.

**ARP/ICMP conflict probing before OFFER** ✓
`src/probe.zig` sends an RFC 5227-style ARP request (SPA=0.0.0.0) for
locally-attached pools and an ICMP echo for relayed pools before offering
an address. Conflicts are quarantined using the same sentinel-MAC mechanism
as DHCPDECLINE. Interface detection via `/sys/class/net` + ioctls.

**DNS update integration** ✓
Implemented RFC 2136 dynamic DNS updates in `src/dns.zig` with TSIG key
authentication (HMAC-SHA256 and HMAC-MD5). Sends A/PTR record updates to the
configured DNS server when a lease is granted or released. Key file format is
BIND-compatible (`key "name" { algorithm ...; secret "..."; };`).

**`dhcp_options` passthrough** ✓
`Config.dhcp_options` is now populated from `config.yaml` via an untyped YAML
walk (since `yaml.parse` doesn't support StringHashMap). Options are injected
into OFFER and ACK packets. Values can be comma-separated IPv4 addresses
(encoded as 4 bytes each) or raw strings. Keys are DHCP option codes as
decimal strings (e.g. `42: "192.168.1.1"` for NTP server).

**Logging improvements** ✓
All output now goes through `std.log` with a custom `logFn` in `main.zig`.
Each line is written to stderr in the format:
```
<N>YYYY-MM-DDTHH:MM:SSZ [LEVEL] message
```
where `<N>` is the sd-daemon priority prefix (journald-compatible). Log level
is configurable via `log_level: debug|info|warn|error` in `config.yaml`.
