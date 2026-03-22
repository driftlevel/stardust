const std = @import("std");
const yaml = @import("yaml");
const dns_mod = @import("./dns.zig");

pub const Error = error{
    ConfigNotFound,
    InvalidConfig,
    IoError,
    OutOfMemory,
};

pub const SyncConfig = struct {
    enable: bool,
    group_name: []const u8,
    key_file: []const u8,
    port: u16,           // default 647
    full_sync_interval: u32, // seconds, default 300
    multicast: ?[]const u8,  // null if using peers mode
    peers: [][]const u8,     // empty if using multicast mode
};

pub const Reservation = struct {
    mac: []const u8,
    ip: []const u8,
    hostname: ?[]const u8,
    client_id: ?[]const u8,
};

pub const StaticRoute = struct {
    destination: [4]u8, // masked network address
    prefix_len: u8,     // 0–32
    router: [4]u8,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    listen_address: []const u8,
    subnet: []const u8,
    subnet_mask: u32,
    router: []const u8,
    dns_servers: [][]const u8,
    domain_name: []const u8,
    domain_search: [][]const u8,
    time_offset: ?i32,           // option 2: seconds east of UTC; null = not sent
    time_servers: [][]const u8,  // option 4: RFC 868 time servers
    log_servers: [][]const u8,   // option 7: log servers
    ntp_servers: [][]const u8,   // option 42: NTP servers
    tftp_server_name: []const u8, // option 66: TFTP server hostname or IP
    boot_filename: []const u8,   // option 67: PXE boot filename
    lease_time: u32,
    state_dir: []const u8,
    pool_start: []const u8, // "" = use subnet start
    pool_end: []const u8, // "" = use subnet end
    dns_update: dns_mod.Config,
    dhcp_options: std.StringHashMap([]const u8),
    log_level: std.log.Level,
    reservations: []Reservation,
    static_routes: []StaticRoute,
    pool_allocation_random: bool, // false = sequential (existing behavior), true = random start offset
    sync: ?SyncConfig,            // null if sync.enable = false or section absent

    /// Free all allocator-owned memory. Must be called when the Config is no
    /// longer needed.
    pub fn deinit(self: *Config) void {
        self.allocator.free(self.listen_address);
        self.allocator.free(self.subnet);
        self.allocator.free(self.router);
        self.allocator.free(self.pool_start);
        self.allocator.free(self.pool_end);
        for (self.dns_servers) |s| self.allocator.free(s);
        self.allocator.free(self.dns_servers);
        self.allocator.free(self.domain_name);
        for (self.domain_search) |s| self.allocator.free(s);
        self.allocator.free(self.domain_search);
        for (self.time_servers) |s| self.allocator.free(s);
        self.allocator.free(self.time_servers);
        for (self.log_servers) |s| self.allocator.free(s);
        self.allocator.free(self.log_servers);
        for (self.ntp_servers) |s| self.allocator.free(s);
        self.allocator.free(self.ntp_servers);
        self.allocator.free(self.tftp_server_name);
        self.allocator.free(self.boot_filename);
        self.allocator.free(self.state_dir);
        self.allocator.free(self.dns_update.server);
        self.allocator.free(self.dns_update.zone);
        self.allocator.free(self.dns_update.key_name);
        self.allocator.free(self.dns_update.key_file);
        var it = self.dhcp_options.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.dhcp_options.deinit();
        for (self.reservations) |r| {
            self.allocator.free(r.mac);
            self.allocator.free(r.ip);
            if (r.hostname) |h| self.allocator.free(h);
            if (r.client_id) |c| self.allocator.free(c);
        }
        self.allocator.free(self.reservations);
        self.allocator.free(self.static_routes);
        if (self.sync) |*s| {
            self.allocator.free(s.group_name);
            self.allocator.free(s.key_file);
            if (s.multicast) |m| self.allocator.free(m);
            for (s.peers) |p| self.allocator.free(p);
            self.allocator.free(s.peers);
        }
    }
};

// Mirror of Config used for yaml.Yaml.parse(). All fields are optional so
// that missing keys in the YAML file fall back to the defaults we apply below.
// Strings are slices into the yaml arena and must be duped before use.
const RawConfig = struct {
    listen_address: ?[]const u8 = null,
    subnet: ?[]const u8 = null,
    subnet_mask: ?[]const u8 = null, // dotted-decimal string in the YAML
    router: ?[]const u8 = null,
    dns_servers: ?[][]const u8 = null,
    domain_name: ?[]const u8 = null,
    domain_search: ?[][]const u8 = null,
    time_offset: ?i32 = null,
    time_servers: ?[][]const u8 = null,
    log_servers: ?[][]const u8 = null,
    ntp_servers: ?[][]const u8 = null,
    tftp_server_name: ?[]const u8 = null,
    boot_filename: ?[]const u8 = null,
    lease_time: ?u32 = null,
    state_dir: ?[]const u8 = null,
    pool_start: ?[]const u8 = null,
    pool_end: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    dns_update: ?struct {
        enable: ?bool = null,
        server: ?[]const u8 = null,
        zone: ?[]const u8 = null,
        key_name: ?[]const u8 = null,
        key_file: ?[]const u8 = null,
    } = null,
};

// ---------------------------------------------------------------------------
// Minimal YAML-subset parser
//
// Handles the flat key: value and nested key:\n  subkey: value structure
// present in config.yaml. Sequences are parsed for dns_servers.
// This avoids an external yaml dependency while remaining compatible with
// the existing config.yaml format.
// ---------------------------------------------------------------------------

const ParseState = struct {
    allocator: std.mem.Allocator,
    lines: [][]const u8,
    pos: usize,
    cfg: *Config,
    // Accumulate dns servers before writing to cfg
    dns_list: std.ArrayList([]const u8),
};

/// Load and parse a YAML config file from `path`.
/// Caller must call `cfg.deinit()` when done.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return Error.ConfigNotFound;
        return Error.IoError;
    };
    defer file.close();

    const file_size = (try file.stat()).size;
    const source = try allocator.alloc(u8, file_size);
    defer allocator.free(source);
    _ = try file.readAll(source);

    // yaml.Yaml owns its own arena internally; we deinit it after we've
    // duped all the strings we need into our own allocator.
    var doc = yaml.Yaml{ .source = source };
    try doc.load(allocator);
    defer doc.deinit(allocator);

    // Use an arena just for the parse call — Yaml.parse allocates into it
    // and we throw it away once we've duped everything into `allocator`.
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const raw = try doc.parse(parse_arena.allocator(), RawConfig);

    const lease_time_val = raw.lease_time orelse 3600;

    // Build Config with owned copies of every string.
    var cfg = Config{
        .allocator = allocator,
        .listen_address = try allocator.dupe(u8, raw.listen_address orelse "0.0.0.0"),
        .subnet = try allocator.dupe(u8, raw.subnet orelse "192.168.1.0"),
        .subnet_mask = try parseMask(raw.subnet_mask orelse "255.255.255.0"),
        .router = try allocator.dupe(u8, raw.router orelse "192.168.1.1"),
        .dns_servers = try allocator.alloc([]const u8, 0),
        .domain_name = try allocator.dupe(u8, raw.domain_name orelse ""),
        .domain_search = try allocator.alloc([]const u8, 0),
        .time_offset = null,
        .time_servers = try allocator.alloc([]const u8, 0),
        .log_servers = try allocator.alloc([]const u8, 0),
        .ntp_servers = try allocator.alloc([]const u8, 0),
        .tftp_server_name = try allocator.dupe(u8, ""),
        .boot_filename = try allocator.dupe(u8, ""),
        .lease_time = lease_time_val,
        .state_dir = try allocator.dupe(u8, raw.state_dir orelse "/var/lib/stardust"),
        .pool_start = try allocator.dupe(u8, raw.pool_start orelse ""),
        .pool_end = try allocator.dupe(u8, raw.pool_end orelse ""),
        .log_level = parseLogLevel(raw.log_level orelse "info"),
        .dns_update = .{
            .enable = false,
            .server = try allocator.dupe(u8, ""),
            .zone = try allocator.dupe(u8, ""),
            .key_name = try allocator.dupe(u8, ""),
            .key_file = try allocator.dupe(u8, ""),
            .lease_time = lease_time_val,
        },
        .dhcp_options = std.StringHashMap([]const u8).init(allocator),
        .reservations = try allocator.alloc(Reservation, 0),
        .static_routes = try allocator.alloc(StaticRoute, 0),
        .pool_allocation_random = false,
        .sync = null,
    };

    if (raw.dns_servers) |servers| {
        allocator.free(cfg.dns_servers);
        cfg.dns_servers = try allocator.alloc([]const u8, servers.len);
        for (cfg.dns_servers) |*s| s.* = ""; // safe deinit if we error partway
        for (servers, 0..) |s, i| {
            cfg.dns_servers[i] = try allocator.dupe(u8, s);
        }
    }

    if (raw.domain_search) |domains| {
        allocator.free(cfg.domain_search);
        cfg.domain_search = try allocator.alloc([]const u8, domains.len);
        for (cfg.domain_search) |*s| s.* = ""; // safe deinit if we error partway
        for (domains, 0..) |s, i| {
            cfg.domain_search[i] = try allocator.dupe(u8, s);
        }
    }

    if (raw.time_offset) |v| cfg.time_offset = v;

    if (raw.time_servers) |servers| {
        allocator.free(cfg.time_servers);
        cfg.time_servers = try allocator.alloc([]const u8, servers.len);
        for (cfg.time_servers) |*s| s.* = "";
        for (servers, 0..) |s, i| {
            cfg.time_servers[i] = try allocator.dupe(u8, s);
        }
    }

    if (raw.log_servers) |servers| {
        allocator.free(cfg.log_servers);
        cfg.log_servers = try allocator.alloc([]const u8, servers.len);
        for (cfg.log_servers) |*s| s.* = "";
        for (servers, 0..) |s, i| {
            cfg.log_servers[i] = try allocator.dupe(u8, s);
        }
    }

    if (raw.ntp_servers) |servers| {
        allocator.free(cfg.ntp_servers);
        cfg.ntp_servers = try allocator.alloc([]const u8, servers.len);
        for (cfg.ntp_servers) |*s| s.* = "";
        for (servers, 0..) |s, i| {
            cfg.ntp_servers[i] = try allocator.dupe(u8, s);
        }
    }

    if (raw.tftp_server_name) |v| {
        allocator.free(cfg.tftp_server_name);
        cfg.tftp_server_name = try allocator.dupe(u8, v);
    }

    if (raw.boot_filename) |v| {
        allocator.free(cfg.boot_filename);
        cfg.boot_filename = try allocator.dupe(u8, v);
    }

    if (raw.dns_update) |du| {
        if (du.enable) |v| cfg.dns_update.enable = v;
        if (du.server) |v| {
            allocator.free(cfg.dns_update.server);
            cfg.dns_update.server = try allocator.dupe(u8, v);
        }
        if (du.zone) |v| {
            allocator.free(cfg.dns_update.zone);
            cfg.dns_update.zone = try allocator.dupe(u8, v);
        }
        if (du.key_name) |v| {
            allocator.free(cfg.dns_update.key_name);
            cfg.dns_update.key_name = try allocator.dupe(u8, v);
        }
        if (du.key_file) |v| {
            allocator.free(cfg.dns_update.key_file);
            cfg.dns_update.key_file = try allocator.dupe(u8, v);
        }
    }

    // Populate dhcp_options and reservations from the untyped YAML map.
    if (doc.docs.items.len > 0) {
        if (doc.docs.items[0].asMap()) |root_map| {
            if (root_map.get("dhcp_options")) |opts_val| {
                if (opts_val.asMap()) |opts_map| {
                    var it = opts_map.iterator();
                    while (it.next()) |entry| {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key);
                        const val_str = entry.value_ptr.asScalar() orelse "";
                        const val = try allocator.dupe(u8, val_str);
                        errdefer allocator.free(val);
                        try cfg.dhcp_options.put(key, val);
                    }
                }
            }

            if (root_map.get("reservations")) |res_val| {
                if (res_val.asList()) |res_list| {
                    try parseReservations(allocator, &cfg, res_list);
                }
            }

            if (root_map.get("static_routes")) |sr_val| {
                if (sr_val.asList()) |sr_list| {
                    try parseStaticRoutes(allocator, &cfg, sr_list);
                }
            }

            if (root_map.get("pool_allocation_random")) |par_val| {
                if (par_val.asScalar()) |s| {
                    if (std.mem.eql(u8, s, "true")) cfg.pool_allocation_random = true;
                }
            }

            if (root_map.get("sync")) |sync_val| {
                if (sync_val.asMap()) |sync_map| {
                    cfg.sync = try parseSyncConfig(allocator, sync_map);
                }
            }
        }
    }

    validatePoolRange(&cfg);

    return cfg;
}

/// Parse the reservations list from the untyped YAML walk and append valid entries to cfg.
fn parseReservations(allocator: std.mem.Allocator, cfg: *Config, list: anytype) !void {

    // Count valid entries first to allocate the right amount.
    var valid_count: usize = 0;
    for (list) |item| {
        const m = item.asMap() orelse continue;
        if (m.get("mac") == null or m.get("ip") == null) continue;
        valid_count += 1;
    }

    if (valid_count == 0) return;

    const old_len = cfg.reservations.len;
    const new_slice = try allocator.realloc(cfg.reservations, old_len + valid_count);
    cfg.reservations = new_slice;

    var idx: usize = old_len;
    for (list) |item| {
        const m = item.asMap() orelse {
            std.log.warn("config: reservation entry is not a map, skipping", .{});
            continue;
        };

        const mac_val = m.get("mac") orelse {
            std.log.warn("config: reservation missing 'mac', skipping", .{});
            continue;
        };
        const ip_val = m.get("ip") orelse {
            std.log.warn("config: reservation missing 'ip', skipping", .{});
            continue;
        };

        const mac_str = mac_val.asScalar() orelse {
            std.log.warn("config: reservation 'mac' is not a scalar, skipping", .{});
            continue;
        };
        const ip_str = ip_val.asScalar() orelse {
            std.log.warn("config: reservation 'ip' is not a scalar, skipping", .{});
            continue;
        };

        // Validate that the reservation IP is in the subnet.
        const ip_bytes = parseIpv4(ip_str) catch {
            std.log.warn("config: reservation ip '{s}' is invalid, skipping", .{ip_str});
            continue;
        };
        const ip_int = std.mem.readInt(u32, &ip_bytes, .big);
        const subnet_bytes = parseIpv4(cfg.subnet) catch [4]u8{ 0, 0, 0, 0 };
        const subnet_int = std.mem.readInt(u32, &subnet_bytes, .big);
        const broadcast_int = subnet_int | ~cfg.subnet_mask;
        if ((ip_int & cfg.subnet_mask) != subnet_int or ip_int == subnet_int or ip_int == broadcast_int) {
            std.log.warn("config: reservation ip '{s}' is outside subnet {s}, skipping", .{ ip_str, cfg.subnet });
            continue;
        }

        const hostname_str: ?[]const u8 = if (m.get("hostname")) |hv| hv.asScalar() else null;
        const client_id_str: ?[]const u8 = if (m.get("client_id")) |cv| cv.asScalar() else null;

        const mac_owned = try allocator.dupe(u8, mac_str);
        errdefer allocator.free(mac_owned);
        const ip_owned = try allocator.dupe(u8, ip_str);
        errdefer allocator.free(ip_owned);
        const hostname_owned: ?[]const u8 = if (hostname_str) |h| try allocator.dupe(u8, h) else null;
        errdefer if (hostname_owned) |h| allocator.free(h);
        const client_id_owned: ?[]const u8 = if (client_id_str) |c| try allocator.dupe(u8, c) else null;
        errdefer if (client_id_owned) |c| allocator.free(c);

        cfg.reservations[idx] = .{
            .mac = mac_owned,
            .ip = ip_owned,
            .hostname = hostname_owned,
            .client_id = client_id_owned,
        };
        idx += 1;
    }

    // Trim to actual count (in case some entries were skipped).
    cfg.reservations = allocator.realloc(cfg.reservations, idx) catch cfg.reservations;
}

/// Parse a single static route from destination and router strings.
/// Returns null if the entry should be skipped (a log message is emitted).
fn parseOneStaticRoute(dest_str: []const u8, router_str: []const u8) ?StaticRoute {
    // Parse destination: split on '/' for CIDR; no slash = /32 host route.
    var prefix_len: u8 = 32;
    var ip_str: []const u8 = dest_str;
    if (std.mem.indexOfScalar(u8, dest_str, '/')) |slash| {
        ip_str = dest_str[0..slash];
        const pl = std.fmt.parseInt(u8, dest_str[slash + 1 ..], 10) catch {
            std.log.warn("config: static_route destination '{s}' has invalid prefix length, skipping", .{dest_str});
            return null;
        };
        if (pl > 32) {
            std.log.warn("config: static_route destination '{s}' prefix_len out of range, skipping", .{dest_str});
            return null;
        }
        prefix_len = @intCast(pl);
    }

    // Reject /0 (default route) — use the top-level 'router' option instead.
    if (prefix_len == 0) {
        std.log.err("config: static_route '{s}' is a default route (0.0.0.0/0); use the 'router' option instead, skipping", .{dest_str});
        return null;
    }

    const dest_bytes = parseIpv4(ip_str) catch {
        std.log.warn("config: static_route destination '{s}' is invalid, skipping", .{dest_str});
        return null;
    };
    const router_bytes = parseIpv4(router_str) catch {
        std.log.warn("config: static_route router '{s}' is invalid, skipping", .{router_str});
        return null;
    };

    // Apply CIDR mask to canonicalize destination (e.g. 10.0.0.5/24 → 10.0.0.0).
    const mask: u32 = @as(u32, 0xFFFFFFFF) << @intCast(32 - prefix_len);
    var dest_int = std.mem.readInt(u32, &dest_bytes, .big);
    dest_int &= mask;
    var masked_dest: [4]u8 = undefined;
    std.mem.writeInt(u32, &masked_dest, dest_int, .big);

    return StaticRoute{
        .destination = masked_dest,
        .prefix_len = prefix_len,
        .router = router_bytes,
    };
}

/// Parse the static_routes list from the untyped YAML walk and append valid entries to cfg.
fn parseStaticRoutes(allocator: std.mem.Allocator, cfg: *Config, list: anytype) !void {
    const old_len = cfg.static_routes.len;
    var count: usize = 0;

    for (list) |item| {
        const m = item.asMap() orelse {
            std.log.warn("config: static_route entry is not a map, skipping", .{});
            continue;
        };
        const dest_val = m.get("destination") orelse {
            std.log.warn("config: static_route missing 'destination', skipping", .{});
            continue;
        };
        const router_val = m.get("router") orelse {
            std.log.warn("config: static_route missing 'router', skipping", .{});
            continue;
        };
        const dest_str = dest_val.asScalar() orelse {
            std.log.warn("config: static_route 'destination' is not a scalar, skipping", .{});
            continue;
        };
        const router_str = router_val.asScalar() orelse {
            std.log.warn("config: static_route 'router' is not a scalar, skipping", .{});
            continue;
        };

        const route = parseOneStaticRoute(dest_str, router_str) orelse continue;

        const new_slice = try allocator.realloc(cfg.static_routes, old_len + count + 1);
        cfg.static_routes = new_slice;
        cfg.static_routes[old_len + count] = route;
        count += 1;
    }
}

/// Parse the sync section from the untyped YAML map into a SyncConfig.
fn parseSyncConfig(allocator: std.mem.Allocator, sync_map: anytype) !?SyncConfig {
    const enable_val = sync_map.get("enable") orelse return null;
    const enable_str = enable_val.asScalar() orelse return null;
    if (!std.mem.eql(u8, enable_str, "true")) return null;

    const group_name = if (sync_map.get("group_name")) |v|
        if (v.asScalar()) |s| try allocator.dupe(u8, s) else try allocator.dupe(u8, "default")
    else
        try allocator.dupe(u8, "default");
    errdefer allocator.free(group_name);

    const key_file = if (sync_map.get("key_file")) |v|
        if (v.asScalar()) |s| try allocator.dupe(u8, s) else try allocator.dupe(u8, "")
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(key_file);

    var port: u16 = 647;
    if (sync_map.get("port")) |v| {
        if (v.asScalar()) |s| {
            port = std.fmt.parseInt(u16, s, 10) catch 647;
        }
    }

    var full_sync_interval: u32 = 300;
    if (sync_map.get("full_sync_interval")) |v| {
        if (v.asScalar()) |s| {
            full_sync_interval = std.fmt.parseInt(u32, s, 10) catch 300;
        }
    }

    var multicast: ?[]const u8 = null;
    errdefer if (multicast) |m| allocator.free(m);
    if (sync_map.get("multicast")) |v| {
        if (v.asScalar()) |s| {
            multicast = try allocator.dupe(u8, s);
        }
    }

    var peers = try allocator.alloc([]const u8, 0);
    errdefer {
        for (peers) |p| allocator.free(p);
        allocator.free(peers);
    }
    if (sync_map.get("peers")) |v| {
        if (v.asList()) |list| {
            peers = try allocator.realloc(peers, list.len);
            var count: usize = 0;
            for (list) |item| {
                if (item.asScalar()) |s| {
                    peers[count] = try allocator.dupe(u8, s);
                    count += 1;
                }
            }
            peers = allocator.realloc(peers, count) catch peers;
        }
    }

    return SyncConfig{
        .enable = true,
        .group_name = group_name,
        .key_file = key_file,
        .port = port,
        .full_sync_interval = full_sync_interval,
        .multicast = multicast,
        .peers = peers,
    };
}

/// Compute a SHA-256 pool hash over the subnet, pool, lease_time, reservations,
/// and static routes. Used by SyncManager to verify peer config compatibility.
pub fn computePoolHash(cfg: *const Config) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});

    const subnet_bytes = parseIpv4(cfg.subnet) catch [4]u8{ 0, 0, 0, 0 };
    h.update(&subnet_bytes);

    var mask_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &mask_bytes, cfg.subnet_mask, .big);
    h.update(&mask_bytes);

    // Pool start and end as network-order u32
    const pool_start_bytes = if (cfg.pool_start.len > 0)
        parseIpv4(cfg.pool_start) catch [4]u8{ 0, 0, 0, 0 }
    else blk: {
        const subnet_int = std.mem.readInt(u32, &subnet_bytes, .big);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, subnet_int + 1, .big);
        break :blk b;
    };
    h.update(&pool_start_bytes);

    const pool_end_bytes = if (cfg.pool_end.len > 0)
        parseIpv4(cfg.pool_end) catch [4]u8{ 255, 255, 255, 255 }
    else blk: {
        const subnet_int = std.mem.readInt(u32, &subnet_bytes, .big);
        const broadcast_int = subnet_int | ~cfg.subnet_mask;
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, broadcast_int - 1, .big);
        break :blk b;
    };
    h.update(&pool_end_bytes);

    var lt_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &lt_bytes, cfg.lease_time, .big);
    h.update(&lt_bytes);

    // Reservations count + sorted by MAC
    var rc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &rc_bytes, @intCast(cfg.reservations.len), .big);
    h.update(&rc_bytes);

    // Sort reservation indices by MAC string for deterministic order.
    // Use a small stack buffer; if more than 256 reservations, heap would be needed.
    var res_indices: [256]usize = undefined;
    const res_count = @min(cfg.reservations.len, res_indices.len);
    for (0..res_count) |i| res_indices[i] = i;
    // Insertion sort — reservation counts are small in practice.
    for (1..res_count) |i| {
        const key = res_indices[i];
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, cfg.reservations[key].mac, cfg.reservations[res_indices[j - 1]].mac)) {
            res_indices[j] = res_indices[j - 1];
            j -= 1;
        }
        res_indices[j] = key;
    }
    for (res_indices[0..res_count]) |ri| {
        const r = &cfg.reservations[ri];
        // MAC is "xx:xx:xx:xx:xx:xx" — parse to 6 bytes for compactness
        var mac_bytes: [6]u8 = [_]u8{0} ** 6;
        var bi: usize = 0;
        var pos: usize = 0;
        while (bi < 6 and pos + 1 < r.mac.len) : (bi += 1) {
            const hi = std.fmt.charToDigit(r.mac[pos], 16) catch 0;
            const lo = std.fmt.charToDigit(r.mac[pos + 1], 16) catch 0;
            mac_bytes[bi] = (hi << 4) | lo;
            pos += 3; // skip "xx:"
        }
        h.update(&mac_bytes);
        const ip_bytes = parseIpv4(r.ip) catch [4]u8{ 0, 0, 0, 0 };
        h.update(&ip_bytes);
    }

    // Static routes count + sorted by destination
    var src_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &src_bytes, @intCast(cfg.static_routes.len), .big);
    h.update(&src_bytes);

    var sr_indices: [256]usize = undefined;
    const sr_count = @min(cfg.static_routes.len, sr_indices.len);
    for (0..sr_count) |i| sr_indices[i] = i;
    for (1..sr_count) |i| {
        const key = sr_indices[i];
        var j = i;
        while (j > 0) {
            const a = &cfg.static_routes[key];
            const b2 = &cfg.static_routes[sr_indices[j - 1]];
            const dest_a = std.mem.readInt(u32, &a.destination, .big);
            const dest_b = std.mem.readInt(u32, &b2.destination, .big);
            if (dest_a >= dest_b) break;
            sr_indices[j] = sr_indices[j - 1];
            j -= 1;
        }
        sr_indices[j] = key;
    }
    for (sr_indices[0..sr_count]) |sri| {
        const r = &cfg.static_routes[sri];
        h.update(&r.destination);
        h.update(&[1]u8{r.prefix_len});
        h.update(&r.router);
    }

    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}

/// Log warnings when pool_start/pool_end are misconfigured. Does not fail load().
fn validatePoolRange(cfg: *const Config) void {
    const subnet_bytes = parseIpv4(cfg.subnet) catch return;
    const subnet_int = std.mem.readInt(u32, &subnet_bytes, .big);
    const broadcast_int = subnet_int | ~cfg.subnet_mask;
    const valid_start = subnet_int + 1;
    const valid_end = broadcast_int - 1;

    var start_int: u32 = valid_start;
    var end_int: u32 = valid_end;
    var has_start = false;
    var has_end = false;

    if (cfg.pool_start.len > 0) {
        const b = parseIpv4(cfg.pool_start) catch {
            std.log.warn("config: pool_start '{s}' is not a valid IP address", .{cfg.pool_start});
            return;
        };
        start_int = std.mem.readInt(u32, &b, .big);
        has_start = true;
        if (start_int < valid_start or start_int > valid_end) {
            std.log.warn("config: pool_start {s} is outside subnet {s}", .{ cfg.pool_start, cfg.subnet });
        }
    }

    if (cfg.pool_end.len > 0) {
        const b = parseIpv4(cfg.pool_end) catch {
            std.log.warn("config: pool_end '{s}' is not a valid IP address", .{cfg.pool_end});
            return;
        };
        end_int = std.mem.readInt(u32, &b, .big);
        has_end = true;
        if (end_int < valid_start or end_int > valid_end) {
            std.log.warn("config: pool_end {s} is outside subnet {s}", .{ cfg.pool_end, cfg.subnet });
        }
    }

    if (has_start and has_end and start_int > end_int) {
        std.log.warn("config: pool_start {s} > pool_end {s}: pool is empty", .{ cfg.pool_start, cfg.pool_end });
    }
}

fn parseLogLevel(s: []const u8) std.log.Level {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warn;
    if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "err")) return .err;
    return .info; // default
}

/// Parse a dotted-decimal subnet mask string (e.g. "255.255.255.0") into a
/// host-order u32.
fn parseMask(s: []const u8) !u32 {
    var result: u32 = 0;
    var octet: u32 = 0;
    var dots: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            if (dots >= 3) return error.InvalidConfig;
            result = (result << 8) | octet;
            octet = 0;
            dots += 1;
        } else if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
            if (octet > 255) return error.InvalidConfig;
        } else {
            return error.InvalidConfig;
        }
    }
    if (dots != 3) return error.InvalidConfig;
    result = (result << 8) | octet;
    // Validate contiguous CIDR prefix: no 0→1 bit transition reading MSB→LSB.
    // Equivalently, ~mask must be of the form 0x00...0FF...F (a power-of-two minus 1 or 0).
    const inverted = ~result;
    if (inverted != 0 and (inverted & (inverted +% 1)) != 0) return error.InvalidConfig;
    return result;
}

/// Parse a dotted-decimal IPv4 address string into a 4-byte array in network
/// byte order. Used by dhcp.zig to convert config strings to wire bytes.
pub fn parseIpv4(s: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var octet: u16 = 0;
    var idx: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            if (idx >= 3) return error.InvalidConfig;
            result[idx] = @intCast(octet);
            octet = 0;
            idx += 1;
        } else if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
            if (octet > 255) return error.InvalidConfig;
        } else {
            return error.InvalidConfig;
        }
    }
    if (idx != 3) return error.InvalidConfig;
    result[idx] = @intCast(octet);
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseMask 255.255.255.0" {
    const mask = try parseMask("255.255.255.0");
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), mask);
}

test "parseMask 255.255.0.0" {
    const mask = try parseMask("255.255.0.0");
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), mask);
}

test "parseIpv4 basic" {
    const ip = try parseIpv4("192.168.1.1");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &ip);
}

test "parseIpv4 rejects bad input" {
    try std.testing.expectError(error.InvalidConfig, parseIpv4("192.168.1"));
    try std.testing.expectError(error.InvalidConfig, parseIpv4("256.0.0.1"));
    try std.testing.expectError(error.InvalidConfig, parseIpv4("not.an.ip.addr"));
}

test "parseLogLevel" {
    try std.testing.expectEqual(std.log.Level.debug, parseLogLevel("debug"));
    try std.testing.expectEqual(std.log.Level.warn, parseLogLevel("warn"));
    try std.testing.expectEqual(std.log.Level.warn, parseLogLevel("warning"));
    try std.testing.expectEqual(std.log.Level.err, parseLogLevel("error"));
    try std.testing.expectEqual(std.log.Level.info, parseLogLevel("info"));
    try std.testing.expectEqual(std.log.Level.info, parseLogLevel("unknown"));
}

test "parseMask rejects non-CIDR masks" {
    try std.testing.expectError(error.InvalidConfig, parseMask("255.0.255.0"));
    try std.testing.expectError(error.InvalidConfig, parseMask("255.128.255.0"));
    try std.testing.expectError(error.InvalidConfig, parseMask("255.255.255.1"));
}

test "parseMask accepts valid CIDR edge cases" {
    // /0 — all wildcard
    try std.testing.expectEqual(@as(u32, 0x00000000), try parseMask("0.0.0.0"));
    // /32 — host route
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try parseMask("255.255.255.255"));
}

test "parseStaticRoutes: CIDR destination parsed and masked" {
    // "10.10.10.5/24" → destination=10.10.10.0, prefix_len=24
    const r = parseOneStaticRoute("10.10.10.5/24", "192.168.1.1");
    try std.testing.expect(r != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 10, 10, 0 }, &r.?.destination);
    try std.testing.expectEqual(@as(u8, 24), r.?.prefix_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &r.?.router);
}

test "parseStaticRoutes: plain IP = /32 host route" {
    // No slash → prefix_len=32, destination unchanged
    const r = parseOneStaticRoute("10.10.10.1", "192.168.1.254");
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(u8, 32), r.?.prefix_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 10, 10, 1 }, &r.?.destination);
}

test "parseStaticRoutes: /0 default route is rejected" {
    const r = parseOneStaticRoute("0.0.0.0/0", "192.168.1.1");
    try std.testing.expect(r == null);
}

test "parseIpv4: empty string rejected" {
    try std.testing.expectError(error.InvalidConfig, parseIpv4(""));
}

test "parseIpv4: too many octets rejected" {
    try std.testing.expectError(error.InvalidConfig, parseIpv4("1.2.3.4.5"));
}

test "parseIpv4: trailing dot rejected" {
    try std.testing.expectError(error.InvalidConfig, parseIpv4("192.168.1."));
}

test "parseIpv4: leading dot rejected" {
    try std.testing.expectError(error.InvalidConfig, parseIpv4(".192.168.1.1"));
}

test "parseMask: empty string rejected" {
    try std.testing.expectError(error.InvalidConfig, parseMask(""));
}

test "parseMask: too few octets rejected" {
    try std.testing.expectError(error.InvalidConfig, parseMask("255.255.0"));
}

test "parseMask: non-numeric characters rejected" {
    try std.testing.expectError(error.InvalidConfig, parseMask("255.255.abc.0"));
}

test "parseMask: octet out of range rejected" {
    try std.testing.expectError(error.InvalidConfig, parseMask("255.256.0.0"));
}

test "parseStaticRoutes: invalid destination IP is skipped" {
    const r = parseOneStaticRoute("not.an.ip/24", "192.168.1.1");
    try std.testing.expect(r == null);
}

test "parseStaticRoutes: invalid router IP is skipped" {
    const r = parseOneStaticRoute("10.0.0.0/8", "not.a.router");
    try std.testing.expect(r == null);
}

test "parseStaticRoutes: prefix_len > 32 is rejected" {
    const r = parseOneStaticRoute("10.0.0.0/33", "192.168.1.1");
    try std.testing.expect(r == null);
}

// ---------------------------------------------------------------------------
// computePoolHash tests
// ---------------------------------------------------------------------------

/// Build a minimal Config suitable for pool-hash tests. All allocated strings
/// must be freed by calling cfg.deinit().
fn makeHashTestConfig(alloc: std.mem.Allocator) Config {
    return Config{
        .allocator = alloc,
        .listen_address = alloc.dupe(u8, "0.0.0.0") catch unreachable,
        .subnet = alloc.dupe(u8, "192.168.1.0") catch unreachable,
        .subnet_mask = 0xFFFFFF00,
        .router = alloc.dupe(u8, "192.168.1.1") catch unreachable,
        .dns_servers = alloc.alloc([]const u8, 0) catch unreachable,
        .domain_name = alloc.dupe(u8, "") catch unreachable,
        .domain_search = alloc.alloc([]const u8, 0) catch unreachable,
        .time_offset = null,
        .time_servers = alloc.alloc([]const u8, 0) catch unreachable,
        .log_servers = alloc.alloc([]const u8, 0) catch unreachable,
        .ntp_servers = alloc.alloc([]const u8, 0) catch unreachable,
        .tftp_server_name = alloc.dupe(u8, "") catch unreachable,
        .boot_filename = alloc.dupe(u8, "") catch unreachable,
        .lease_time = 3600,
        .state_dir = alloc.dupe(u8, "/tmp") catch unreachable,
        .pool_start = alloc.dupe(u8, "192.168.1.10") catch unreachable,
        .pool_end = alloc.dupe(u8, "192.168.1.200") catch unreachable,
        .log_level = .info,
        .dns_update = .{
            .enable = false,
            .server = alloc.dupe(u8, "") catch unreachable,
            .zone = alloc.dupe(u8, "") catch unreachable,
            .key_name = alloc.dupe(u8, "") catch unreachable,
            .key_file = alloc.dupe(u8, "") catch unreachable,
            .lease_time = 3600,
        },
        .dhcp_options = std.StringHashMap([]const u8).init(alloc),
        .reservations = alloc.alloc(Reservation, 0) catch unreachable,
        .static_routes = alloc.alloc(StaticRoute, 0) catch unreachable,
        .pool_allocation_random = false,
        .sync = null,
    };
}

test "computePoolHash: identical configs hash identically" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    try std.testing.expectEqualSlices(u8, &computePoolHash(&c1), &computePoolHash(&c2));
}

test "computePoolHash: different subnet produces different hash" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    alloc.free(c2.subnet);
    c2.subnet = try alloc.dupe(u8, "10.0.0.0");

    try std.testing.expect(!std.mem.eql(u8, &computePoolHash(&c1), &computePoolHash(&c2)));
}

test "computePoolHash: different subnet_mask produces different hash" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    c2.subnet_mask = 0xFFFF0000; // /16

    try std.testing.expect(!std.mem.eql(u8, &computePoolHash(&c1), &computePoolHash(&c2)));
}

test "computePoolHash: different pool_end produces different hash" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    alloc.free(c2.pool_end);
    c2.pool_end = try alloc.dupe(u8, "192.168.1.150");

    try std.testing.expect(!std.mem.eql(u8, &computePoolHash(&c1), &computePoolHash(&c2)));
}

test "computePoolHash: different lease_time produces different hash" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    c2.lease_time = 7200;

    try std.testing.expect(!std.mem.eql(u8, &computePoolHash(&c1), &computePoolHash(&c2)));
}

test "computePoolHash: adding a reservation changes the hash" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    alloc.free(c2.reservations);
    const res = try alloc.alloc(Reservation, 1);
    res[0] = .{
        .mac = "aa:bb:cc:dd:ee:ff",
        .ip = "192.168.1.50",
        .hostname = null,
        .client_id = null,
    };
    c2.reservations = res;

    try std.testing.expect(!std.mem.eql(u8, &computePoolHash(&c1), &computePoolHash(&c2)));
}

test "computePoolHash: reservation insertion order does not affect hash" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    alloc.free(c1.reservations);
    const res1 = try alloc.alloc(Reservation, 2);
    res1[0] = .{ .mac = "aa:bb:cc:dd:ee:01", .ip = "192.168.1.50", .hostname = null, .client_id = null };
    res1[1] = .{ .mac = "aa:bb:cc:dd:ee:02", .ip = "192.168.1.51", .hostname = null, .client_id = null };
    c1.reservations = res1;

    alloc.free(c2.reservations);
    const res2 = try alloc.alloc(Reservation, 2);
    res2[0] = .{ .mac = "aa:bb:cc:dd:ee:02", .ip = "192.168.1.51", .hostname = null, .client_id = null };
    res2[1] = .{ .mac = "aa:bb:cc:dd:ee:01", .ip = "192.168.1.50", .hostname = null, .client_id = null };
    c2.reservations = res2;

    try std.testing.expectEqualSlices(u8, &computePoolHash(&c1), &computePoolHash(&c2));
}

test "computePoolHash: adding a static route changes the hash" {
    const alloc = std.testing.allocator;
    var c1 = makeHashTestConfig(alloc);
    defer c1.deinit();
    var c2 = makeHashTestConfig(alloc);
    defer c2.deinit();

    alloc.free(c2.static_routes);
    const routes = try alloc.alloc(StaticRoute, 1);
    routes[0] = .{
        .destination = .{ 10, 0, 0, 0 },
        .prefix_len = 8,
        .router = .{ 192, 168, 1, 254 },
    };
    c2.static_routes = routes;

    try std.testing.expect(!std.mem.eql(u8, &computePoolHash(&c1), &computePoolHash(&c2)));
}
