const std = @import("std");

pub const Error = error{
    IoError,
};

pub const StateStore = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !*StateStore {
        return StateStore{
            .allocator = allocator,
            .dir = dir,
        };
    }

    pub fn deinit(store: *StateStore) void {
        _ = store;
        // Cleanup
    }

    // Add lease
    pub fn addLease(store: *StateStore, lease: Lease) !void {
        _ = store;
        _ = lease;
    }

    // Remove lease
    pub fn removeLease(store: *StateStore, mac: []const u8) !void {
        _ = store;
        _ = mac;
    }

    // Get lease by MAC
    pub fn getLeaseByMac(store: *StateStore, mac: []const u8) ?Lease {
        _ = store;
        _ = mac;
        return null;
    }

    // Get lease by IP
    pub fn getLeaseByIp(store: *StateStore, ip: []const u8) ?Lease {
        _ = store;
        _ = ip;
        return null;
    }

    // List all leases
    pub fn listLeases(store: *StateStore) ![]Lease {
        _ = store;
        return null;
    }
};

pub const Lease = struct {
    mac: []const u8,
    ip: []const u8,
    hostname: ?[]const u8,
    expires: i64,
    client_id: ?[]const u8,
};
