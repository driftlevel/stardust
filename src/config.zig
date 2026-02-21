const std = @import("std");
const yaml = @import("yaml");

pub const Error = error{
    ConfigNotFound,
    InvalidConfig,
    IoError,
};

pub const Config = struct {
    listen_address: std.net.Address,
    listen_port: u16,
    subnet: std.net.Address,
    subnet_mask: u32,
    router: std.net.Address,
    dns_servers: []const std.net.Address,
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
    dhcp_options: std.StringHashMap(u8),
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = (try file.stat()).size;
    var buf: [file_size]u8 = undefined;
    _ = try file.readToEnd(&buf);
    defer allocator.free(buf);

    const yaml_doc = try yaml.parseFromSlice(allocator, buf, .{});
    defer yaml_doc.deinit();

    var config = Config{
        .listen_address = undefined,
        .listen_port = 67,
        .subnet = .{ .in = .{ .sa = .{ .family = std.posix.AF.INET, .port = 0, .addr = 0x00000000, .zero = undefined } } }
        .subnet_mask = undefined,
        .router = undefined,
        .dns_servers = undefined,
        .domain_name = undefined,
        .lease_time = 3600,
        .state_dir = "/var/lib/stardust",
        .dns_update = .{
            .enable = false,
            .server = undefined,
            .zone = undefined,
            .key_name = undefined,
            .key_file = undefined,
        },
        .dhcp_options = std.StringHashMap(u8).init(allocator),
    };
    defer config.dhcp_options.deinit();

    // Parse YAML values
    if (yaml_doc.root.map.get("listen_address")) |addr_node| {
        config.listen_address = try parseAddress(addr_node.value.str);
    }

    if (yaml_doc.root.map.get("subnet")) |subnet_node| {
        config.subnet = try parseUnspecifiedAddress(subnet_node.value.str);
    }

    if (yaml_doc.root.map.get("router")) |router_node| {
        config.router = try parseAddress(router_node.value.str);
    }

    if (yaml_doc.root.map.get("lease_time")) |lease_node| {
        config.lease_time = lease_node.value.number.uint;
    }

    if (yaml_doc.root.map.get("state_dir")) |dir_node| {
        config.state_dir = try allocator.dupe(u8, dir_node.value.str);
    }

    if (yaml_doc.root.map.get("dns_servers")) |dns_node| {
        const servers = try allocator.alloc(std.net.Address, dns_node.value.sequence.len);
        defer allocator.free(servers);
        for (dns_node.value.sequence.items, 0..) |item, i| {
            servers[i] = try parseAddress(item.value.str);
        }
        config.dns_servers = servers;
    }

    if (yaml_doc.root.map.get("domain_name")) |domain_node| {
        config.domain_name = try allocator.dupe(u8, domain_node.value.str);
    }

    // Parse DNS update configuration
    if (yaml_doc.root.map.get("dns_update")) |dns_update_node| {
        const dns_update_map = dns_update_node.value.map;

        if (dns_update_map.get("enable")) |enable_node| {
            config.dns_update.enable = enable_node.value.boolean;
        }

        if (dns_update_map.get("server")) |server_node| {
            config.dns_update.server = try allocator.dupe(u8, server_node.value.str);
        }

        if (dns_update_map.get("zone")) |zone_node| {
            config.dns_update.zone = try allocator.dupe(u8, zone_node.value.str);
        }

        if (dns_update_map.get("key_name")) |key_name_node| {
            config.dns_update.key_name = try allocator.dupe(u8, key_name_node.value.str);
        }

        if (dns_update_map.get("key_file")) |key_file_node| {
            config.dns_update.key_file = try allocator.dupe(u8, key_file_node.value.str);
        }
    }

    return config;
}

fn parseAddress(s: []const u8) !std.net.Address {
    return std.net.Address.parseIp(s, 0) orelse error.InvalidConfig;
}

fn parseUnspecifiedAddress(s: []const u8) !std.net.Address.Unspecified {
    return std.net.Address.Unspecified.parse(s, 0) orelse error.InvalidConfig;
}
