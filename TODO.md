# Stardust TODO

## Pending

- (none currently)

## Done

- ~~When config_writable is enabled in yaml, check that the config file is actually writable on startup, and crash with an error if it isn't.~~ — Added startup writability check in main.zig

- ~~forceRenewPool subnet mask logic differs from metrics.zig:isIpInPool~~ — Unified to mask both sides in all 5 locations (dhcp.zig, metrics.zig, config_write.zig, admin_ssh.zig x2)
