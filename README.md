# Stardust

A lightweight DHCP server (RFC 2131/2132) written in Zig. Designed for
small-to-medium networks where you want a fast, single-binary daemon with
no runtime dependencies, optional RFC 2136 dynamic DNS integration, and
active-active redundancy via encrypted lease synchronisation.

## Quick start

```bash
# 1. Copy and edit the example config
cp config.yaml /etc/stardust/config.yaml
$EDITOR /etc/stardust/config.yaml   # set subnet, router, dns_servers at minimum

# 2. Run (needs CAP_NET_BIND_SERVICE or root for UDP port 67)
sudo stardust -c /etc/stardust/config.yaml
```

Minimal config:

```yaml
subnet:      "192.168.1.0"
subnet_mask: 255.255.255.0
router:      "192.168.1.1"
dns_servers:
  - "1.1.1.1"
lease_time:  3600
state_dir:   "/var/lib/stardust"
```

Stardust listens on `0.0.0.0:67` by default. `state_dir` must be writable;
leases are persisted there as `leases.json` and survive restarts.

Reload config without restarting:

```bash
kill -HUP $(pidof stardust)
```

## Features

### Core DHCP

- Full DISCOVER → OFFER → REQUEST → ACK/NAK flow (RFC 2131)
- DHCPRELEASE, DHCPDECLINE, and DHCPINFORM handling
- Relay agent support — routes responses via `giaddr` (RFC 2131 §4.1)
- Configurable lease pool (`pool_start` / `pool_end`); defaults to the full
  usable subnet range
- Lease state persisted to JSON and restored at startup (expired leases skipped)
- SIGHUP config reload — updates all settings without dropping the socket

### DHCP options

| Option | Description |
|--------|-------------|
| 1 | Subnet mask |
| 3 | Router (default gateway) |
| 6 | DNS servers |
| 12 | Hostname (from reservation config or client request) |
| 15 | Domain name |
| 2 | Time offset (seconds east of UTC) |
| 4 | RFC 868 time servers |
| 7 | Log servers |
| 42 | NTP servers |
| 51 | Lease time |
| 53 | Message type |
| 54 | Server identifier |
| 55 | Parameter Request List filtering — only requested options are sent |
| 61 | Client identifier — used for lease tracking across MAC changes |
| 66 | TFTP server name (PXE boot) |
| 67 | Boot filename (PXE boot) |
| 82 | Relay agent information — parsed and logged at DEBUG level |
| 119 | Domain search list (RFC 3397) |
| 33 | Static routes |
| 121 | Classless static routes (RFC 3442) |

Arbitrary additional options can be injected via `dhcp_options` in config
(numeric keys, IPv4 or raw string values).

### Static reservations

Pin a MAC address (or DHCP client identifier, option 61) to a fixed IP and
optional hostname. Reservations survive lease expiry and DHCPRELEASE.

```yaml
reservations:
  - mac: "aa:bb:cc:dd:ee:ff"
    ip:  "192.168.1.50"
    hostname: "printer"
  - client_id: "01aabbccddeeff"   # option 61 hex string
    ip: "192.168.1.51"
```

### Pre-offer conflict detection

Before offering an address, Stardust probes for existing occupants:

- **ARP probe** (RFC 5227 style, SPA=0.0.0.0) for clients on the local segment
- **ICMP echo** for clients behind a relay agent

Addresses that respond are quarantined for `max(lease_time / 10, 300)` seconds,
the same cooldown used for DHCPDECLINE.

### DHCPDECLINE protection

- Per-MAC cooldown after 3 declines within 60 seconds
- Global rate limit: 20 declines per 5-minute window (blocks MAC-rotation attacks)

### Dynamic DNS updates (RFC 2136)

Stardust can update a BIND-compatible DNS server with A and PTR records when
leases are granted or released. Authentication uses TSIG (HMAC-SHA256 or
HMAC-MD5) with a standard BIND key file.

```yaml
dns_update:
  enable:   true
  server:   "127.0.0.1"
  zone:     "home.lan"
  key_name: "dhcp-update"
  key_file: "/etc/bind/dhcp-update.key"
```

### Lease synchronisation (active-active redundancy)

Two or more Stardust instances serving the same subnet can share lease state
over UDP. Each datagram is encrypted with AES-256-GCM (key derived from a
shared TSIG secret via HKDF-SHA-256). Peers authenticate each other by
comparing a SHA-256 hash of the pool configuration — servers with different
subnet/pool/reservation settings are rejected.

Conflict resolution is last-write-wins on the `last_modified` timestamp.
Anti-entropy: peers exchange a lease-set hash periodically and only transmit
the full lease list when hashes differ.

```yaml
sync:
  enable:     true
  group_name: "dhcp-ha"
  key_file:   "/etc/stardust/sync.key"   # BIND TSIG key file

  # Option A — link-local multicast (same L2 segment)
  multicast: "239.255.0.67"

  # Option B — unicast (peers across routers)
  # peers:
  #   - "10.0.0.2"
  #   - "10.0.0.3"
```

Enable `pool_allocation_random: true` on all group members to reduce the
chance of two servers assigning the same address during a network partition.

### Logging

Structured log lines on stderr, journald-compatible when `JOURNAL_STREAM` is set:

```
<6>2025-04-01T12:00:00Z [INFO] DHCPACK to aa:bb:cc:dd:ee:ff -> 192.168.1.42 (printer)
```

Log level configurable: `debug`, `info` (default), `warn`, `error`.

## Compilation

Requires **Zig 0.15.2**. No other build dependencies.

```bash
git clone https://github.com/ryannoblett/stardust
cd stardust
zig build                        # debug build → zig-out/bin/stardust
zig build -Doptimize=ReleaseSafe # optimised, safety checks kept
zig build test                   # run all unit tests
```

Cross-compilation (fully static musl binaries):

```bash
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
```

Pre-built binaries for x86\_64, aarch64, and riscv64 are available on the
[Releases](../../releases) page. Each archive contains the binary and an
example `config.yaml`.

## systemd unit

```ini
[Unit]
Description=Stardust DHCP Server
After=network.target

[Service]
ExecStart=/usr/local/bin/stardust -c /etc/stardust/config.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
DynamicUser=yes
StateDirectory=stardust
RuntimeDirectory=stardust

[Install]
WantedBy=multi-user.target
```
