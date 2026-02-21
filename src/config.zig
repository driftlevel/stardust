const std = @import("std");
const yaml = @import("yaml");

pub const Error = error{
    ConfigNotFound,
    InvalidConfig,
    IoError,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    listen_address: []const u8,
    subnet: []const u8,
    subnet_mask: u32,
    router: []const u8,
    dns_servers: [][]const u8,
    domain_name: []const u8,
    lease_time: u32,
    state_dir: []const u8,
    dns_update: struct {
        enable: bool,
        server: []const u8,
        zone: []const u8,
        key_name: []const u8,
        key_file: []const u8,
    },
    dhcp_options: std.StringHashMap([]const u8),

    /// Free all allocator-owned memory. Must be called when the Config is no
    /// longer needed.
    pub fn deinit(self: *Config) void {
        self.allocator.free(self.listen_address);
        self.allocator.free(self.subnet);
        self.allocator.free(self.router);
        for (self.dns_servers) |s| self.allocator.free(s);
        self.allocator.free(self.dns_servers);
        self.allocator.free(self.domain_name);
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
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    const buf = try allocator.alloc(u8, file_size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    const yaml_doc = try yaml.parseFromSlice(allocator, buf, .{});
    defer yaml_doc.deinit();

    // Build config with owned copies of all strings. On any error after
    // partial initialisation, the caller's errdefer should call cfg.deinit()
    // — but since fields start as empty slices we must be careful to only
    // free what was actually allocated. We use arena-style: allocate
    // everything, then hand off ownership in the returned struct.
    var cfg = Config{
        .allocator = allocator,
        .listen_address = try allocator.dupe(u8, "0.0.0.0"),
        .subnet = try allocator.dupe(u8, "192.168.1.0"),
        .subnet_mask = 0xFFFFFF00, // 255.255.255.0
        .router = try allocator.dupe(u8, "192.168.1.1"),
        .dns_servers = try allocator.alloc([]const u8, 0),
        .domain_name = try allocator.dupe(u8, ""),
        .lease_time = 3600,
        .state_dir = try allocator.dupe(u8, "/var/lib/stardust"),
        .dns_update = .{
            .enable = false,
            .server = try allocator.dupe(u8, ""),
            .zone = try allocator.dupe(u8, ""),
            .key_name = try allocator.dupe(u8, ""),
            .key_file = try allocator.dupe(u8, ""),
        },
        .dhcp_options = std.StringHashMap([]const u8).init(allocator),
    };

    if (yaml_doc.root.map.get("listen_address")) |node| {
        allocator.free(cfg.listen_address);
        cfg.listen_address = try allocator.dupe(u8, node.value.str);
    }

    if (yaml_doc.root.map.get("subnet")) |node| {
        allocator.free(cfg.subnet);
        cfg.subnet = try allocator.dupe(u8, node.value.str);
    }

    if (yaml_doc.root.map.get("subnet_mask")) |node| {
        // config.yaml stores subnet_mask as a dotted-decimal string
        cfg.subnet_mask = try parseMask(node.value.str);
    }

    if (yaml_doc.root.map.get("router")) |node| {
        allocator.free(cfg.router);
        cfg.router = try allocator.dupe(u8, node.value.str);
    }

    if (yaml_doc.root.map.get("lease_time")) |node| {
        cfg.lease_time = @intCast(node.value.int);
    }

    if (yaml_doc.root.map.get("state_dir")) |node| {
        allocator.free(cfg.state_dir);
        cfg.state_dir = try allocator.dupe(u8, node.value.str);
    }

    if (yaml_doc.root.map.get("dns_servers")) |node| {
        const items = node.value.list;
        allocator.free(cfg.dns_servers);
        cfg.dns_servers = try allocator.alloc([]const u8, items.len);
        // Zero out so deinit is safe if we error partway through
        for (cfg.dns_servers) |*s| s.* = "";
        for (items, 0..) |item, i| {
            cfg.dns_servers[i] = try allocator.dupe(u8, item.value.str);
        }
    }

    if (yaml_doc.root.map.get("domain_name")) |node| {
        allocator.free(cfg.domain_name);
        cfg.domain_name = try allocator.dupe(u8, node.value.str);
    }

    if (yaml_doc.root.map.get("dns_update")) |dns_node| {
        const m = dns_node.value.map;

        if (m.get("enable")) |node| {
            cfg.dns_update.enable = node.value.bool;
        }
        if (m.get("server")) |node| {
            allocator.free(cfg.dns_update.server);
            cfg.dns_update.server = try allocator.dupe(u8, node.value.str);
        }
        if (m.get("zone")) |node| {
            allocator.free(cfg.dns_update.zone);
            cfg.dns_update.zone = try allocator.dupe(u8, node.value.str);
        }
        if (m.get("key_name")) |node| {
            allocator.free(cfg.dns_update.key_name);
            cfg.dns_update.key_name = try allocator.dupe(u8, node.value.str);
        }
        if (m.get("key_file")) |node| {
            allocator.free(cfg.dns_update.key_file);
            cfg.dns_update.key_file = try allocator.dupe(u8, node.value.str);
        }
    }

    return cfg;
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
