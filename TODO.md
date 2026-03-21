# Stardust TODO

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
