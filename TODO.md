# Stardust TODO

## Pending

### Critical — breaks relay agent operation

**Relay response routing** (RFC 2131 §4.1 / RFC 1542)
When `giaddr != 0` the response must be sent as unicast to `giaddr:67` (the
relay agent's server port), not broadcast to `255.255.255.255:68`. Without
this fix the relay agent never receives OFFER/ACK/NAK packets.

Additionally, the broadcast flag (bit 15 of the `flags` field) must be
respected: if the client sets it the server MUST broadcast; if clear it
SHOULD unicast to `ciaddr` (renewal) or fall back to broadcast. We currently
always broadcast regardless of the flag.

---

### Moderate — RFC non-compliance or meaningful missing feature

**DHCPINFORM not handled** (RFC 2131 §3.4)
A client may send DHCPINFORM to obtain configuration options without
acquiring a lease. The server should reply with a DHCPACK that has `yiaddr`
zeroed but includes all requested options. Currently returns null (no
response), which breaks Windows hosts, printers, and other devices that use
this flow.

**Client ID (option 61) not used** (RFC 2131 §2)
`Lease.client_id` is always stored as `null`. RFC 2131 says the client
identifier (if present) MUST take precedence over `chaddr` for uniquely
identifying a client. VMs and some Windows hosts set this and will receive
duplicate leases or incorrect behaviour.

**`hops` field zeroed in responses** (RFC 1542 §2.1)
Both `createOffer` and `createAck` set `resp_header.hops = 0`. It should
echo `req_header.hops` so relay agents can enforce hop-count limits.

---

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
