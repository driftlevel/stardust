# Stardust TODO

## Medium priority — robustness

~~**Configurable IP pool range**~~
~~The pool currently spans the entire host range of the subnet. Add `pool_start`~~
~~and `pool_end` fields to `config.yaml` / `Config` so operators can reserve~~
~~addresses for static assignment (e.g. pool 192.168.1.100–200 within a /24).~~
✅ Done: `pool_start`/`pool_end` added to `Config` and `RawConfig`; `allocateIp`
and `isIpValid` respect the configured bounds.

~~**DHCPDECLINE handling**~~
~~RFC 2131 requires that when a client detects an address conflict it sends~~
~~DHCPDECLINE. Currently this falls into `else => null` (silently ignored). The~~
~~server should mark the declined IP as unusable (a "conflict" lease) so it isn't~~
~~re-offered.~~
✅ Done: `handleDecline` removes the MAC's lease and quarantines the declined IP
with a `conflict:<ip>` sentinel MAC for one lease period.

~~**Graceful shutdown**~~
~~The `running: std.atomic.Value(bool)` flag exists but is never cleared. Add a~~
~~SIGINT/SIGTERM handler that sets `running` to false so the server exits cleanly~~
~~and flushes lease state rather than being killed mid-write.~~
✅ Done: `SIGINT`/`SIGTERM` handler installed in `run()` via `std.posix.sigaction`;
clears `running` flag through file-level `g_running` pointer.

~~**Server IP when listening on 0.0.0.0**~~
~~When `listen_address` is `0.0.0.0` the server identifier in OFFER/ACK option 54~~
~~is also `0.0.0.0`, which is invalid. Need to detect the outgoing interface IP~~
~~(e.g. via `getsockname` after bind, or by enumerating interfaces) and use that~~
~~as the server identifier.~~
✅ Done: `probeServerIp()` uses the UDP connect trick (`connect` + `getsockname`)
to detect the outbound interface IP; stored in `DHCPServer.server_ip` and used
in all OFFER/ACK/NAK option 54 fields.

## Lower priority — features

**DNS update integration**
`dns.zig` `run()` is a stub. Implement RFC 2136 dynamic DNS updates using TSIG
key authentication: send A/PTR record updates to the configured DNS server when
a lease is granted or released. The config already has `server`, `zone`,
`key_name`, and `key_file` fields.

**`dhcp_options` passthrough**
`Config.dhcp_options` is a `StringHashMap([]const u8)` that is never populated
from `config.yaml` and never serialized into OFFER/ACK packets. Wire it up so
operators can inject arbitrary DHCP options (e.g. NTP server, TFTP server for
PXE boot) via config without code changes.

**Logging improvements**
All output currently goes to stderr via `std.debug.print` with no timestamps or
severity levels. Add a thin logging layer with at minimum timestamps and
configurable verbosity (info / warn / debug), so the tokenizer noise from
zig-yaml can be suppressed in production.
