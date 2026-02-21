const std = @import("std");

pub const Error = error{
    InvalidConfig,
};

pub const DNSUpdater = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    state: *const state.StateStore,

    pub fn create(allocator: std.mem.Allocator, config: *const Config, state_store: *const state.StateStore) !*DNSUpdater {
        return DNSUpdater{
            .allocator = allocator,
            .config = config,
            .state = state_store,
        };
    }

    pub fn run(updater: *DNSUpdater) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();

        if (!updater.config.enable) {
            stdout.print("DNS updater disabled in config\n", .{}) catch return;
            return;
        }

        stdout.print("DNS updater running...\n", .{}) catch return;

        // This would be replaced with actual DNS update logic
        // For now, just verify we can access the state
        _ = try updater.state.listLeases();

        stdout.print("DNS updater completed initial sync\n", .{}) catch return;
    }

    pub fn cleanup(updater: *DNSUpdater) void {
        // Cleanup resources
        _ = updater;
    }
};

pub const Config = struct {
    enable: bool,
    server: []const u8,
    zone: []const u8,
    key_name: []const u8,
    key_file: []const u8,
};

const state = @import("./state.zig");

pub fn create_updater(allocator: std.mem.Allocator, config: *const Config, store: *const state.StateStore) !*DNSUpdater {
    return DNSUpdater.create(allocator, config, store);
}
