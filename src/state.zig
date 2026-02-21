const std = @import("std");

pub const Error = error{
    IoError,
};

pub const StateStore = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !*StateStore {
        const self = try allocator.create(StateStore);
        self.* = .{
            .allocator = allocator,
            .dir = dir,
        };
        return self;
    }

    pub fn deinit(store: *StateStore) void {
        store.allocator.destroy(store);
    }

    /// Add or update a lease record.
    pub fn addLease(store: *StateStore, lease: Lease) !void {
        _ = store;
        _ = lease;
    }

    /// Remove the lease associated with the given MAC address.
    pub fn removeLease(store: *StateStore, mac: []const u8) !void {
        _ = store;
        _ = mac;
    }

    /// Look up a lease by MAC address. Returns null if not found.
    pub fn getLeaseByMac(store: *StateStore, mac: []const u8) ?Lease {
        _ = store;
        _ = mac;
        return null;
    }

    /// Look up a lease by IP address. Returns null if not found.
    pub fn getLeaseByIp(store: *StateStore, ip: []const u8) ?Lease {
        _ = store;
        _ = ip;
        return null;
    }

    /// Return all current leases. Caller does not own the returned slice.
    pub fn listLeases(store: *StateStore) ![]Lease {
        _ = store;
        return &[_]Lease{};
    }
};

pub const Lease = struct {
    mac: []const u8,
    ip: []const u8,
    hostname: ?[]const u8,
    expires: i64,
    client_id: ?[]const u8,
};
