const std = @import("std");

fn printErrorAndPanic(writer: anytype, message: []const u8, err: anyerror) noreturn {
    const err_name = @errorName(err);
    writer.print("{s}: {s}\n", .{ message, err_name }) catch @panic("Failed to write stdout");
    @panic(message);
}

fn printServerError(writer: anytype) noreturn {
    writer.print("Server error\n", .{}) catch @panic("Failed to write stdout");
    @panic("Server error");
}

const dhcp = @import("./src/dhcp.zig");
const config = @import("./src/config.zig");
const state = @import("./src/state.zig");
const dns = @import("./src/dns.zig");

pub fn main() noreturn {
    const allocator = std.heap.page_allocator;
    const arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const gpa = &arena; // use pointer to arena
    const stdout = std.fs.File.stdout().deprecatedWriter();

    stdout.print("Starting Stardust DHCP Server...\n", .{}) catch @panic("Failed to write stdout");

    // Load configuration
    const cfg = config.load(gpa, "config.yaml") catch |err| {
        printErrorAndPanic(
            stdout,
            "Failed to load config",
            err,
        );
    };
    defer cfg.deinit();

    stdout.print("Configuration loaded successfully\n", .{}) catch @panic("Failed to write stdout");

    // Initialize state store
    const store = state.init(gpa, cfg.state_dir) catch |err| {
        printErrorAndPanic(
            stdout,
            "Failed to initialize state store",
            err,
        );
    };
    defer store.deinit();

    stdout.print("State store initialized\n", .{}) catch @panic("Failed to write stdout");

    // Create DHCP server
    const dhcp_server = dhcp.create_server(gpa, cfg, store) catch |err| {
        printErrorAndPanic(
            stdout,
            "Failed to create DHCP server",
            err,
        );
    };
    defer dhcp_server.deinit();

    // Start DNS updater
    const dns_updater = dns.create_updater(gpa, &cfg.dns_update, store) catch |err| {
        printErrorAndPanic(
            stdout,
            "Failed to initialize DNS updater",
            err,
        );
    };
    defer dns_updater.cleanup();

    // Main server loop
    dhcp_server.run() catch printServerError(stdout);
}
