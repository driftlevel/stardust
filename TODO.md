# Stardust TODO

## Pending

### Low — edge cases and nice-to-have

**Option 55 (Parameter Request List) ignored** (RFC 2132 §9.8)
Server sends the same set of options in every response regardless of what
the client requested. RFC says SHOULD filter to only those requested.

**Option 82 (Relay Agent Information) not parsed** (RFC 3046)
When a relay agent is detected the relay's circuit information in option 82
is ignored. Not required for basic operation but useful for per-circuit
policy and logging.

**Pool range not validated against subnet** — no check that `pool_start` ≤
`pool_end` or that both fall within the configured subnet. Silent defaults
applied on parse failure can lead to confusing behaviour.

**Subnet mask not validated as a proper CIDR mask** — `parseMask` accepts
any 32-bit value; a non-contiguous mask such as `255.0.255.0` is silently
used.

**State file not atomically written** — `state.zig` truncates the JSON file
in place. A crash mid-write can corrupt `leases.json`. Fix: write to a
temp file and rename into place.

**`CLAUDE.md` is outdated** — describes `state.zig` and `dns.zig` as
"currently stub" but both are fully implemented.

---

## Completed

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
