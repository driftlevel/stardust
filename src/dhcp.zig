const std = @import("std");

pub const Error = error{
    SocketError,
    IoError,
    InvalidRequest,
};

// DHCP message types
pub const MessageType = enum(u8) {
    DHCPDISCOVER = 1,
    DHCPOFFER = 2,
    DHCPREQUEST = 3,
    DHCPDECLINE = 4,
    DHCPACK = 5,
    DHCPNAK = 6,
    DHCPRELEASE = 7,
    DHCPINFORM = 8,
};

// DHCP packet header
pub const DHCPHeader = extern struct {
    op: u8,
    htype: u8,
    hlen: u8,
    hops: u8,
    xid: u32,
    secs: u16,
    flags: u16,
    ciaddr: [4]u8,
    yiaddr: [4]u8,
    siaddr: [4]u8,
    giaddr: [4]u8,
    chaddr: [16]u8,
    sname: [64]u8,
    file: [128]u8,
    magic: [4]u8,
};

// DHCP option codes (partial list)
pub const OptionCode = enum(u8) {
    Pad = 0,
    SubnetMask = 1,
    TimeOffset = 2,
    Router = 3,
    TimeServer = 4,
    NameServer = 5,
    DomainNameServer = 6,
    LogServer = 7,
    CookieServer = 8,
    LPRServer = 9,
    ImpressServer = 10,
    ResourceLocationServer = 11,
    HostName = 12,
    BootFileSize = 13,
    MeritDumpFile = 14,
    DomainName = 15,
    SwapServer = 16,
    RootPath = 17,
    ExtensionsPath = 18,
    IPForwarding = 19,
    NonLocalSourceRouting = 20,
    PolicyFilter = 21,
    MaxDatagramReassembly = 22,
    DefaultIPTTL = 23,
    PathMTUAgingTimeout = 24,
    PathMTU_Plateau_Table = 25,
    InterfaceMTU = 26,
    AllSubnetsLocal = 27,
    broadcastAddress = 28,
    performMaskDiscovery = 29,
    maskSupplier = 30,
    PerformRouterDiscovery = 31,
    RouterSolicitationAddress = 32,
    StaticRoute = 33,
    TrailerEncapsulation = 34,
    ARPTimeout = 35,
    EthernetEncapsulation = 36,
    TCPDefaultTTL = 37,
    TCPKeepaliveInterval = 38,
    TCPKeepaliveGarbage = 39,
    ISNS = 40,
    RequestedIPAddress = 50,
    IPAddressLeaseTime = 51,
    Overload = 52,
    MessageType = 53,
    ServerIdentifier = 54,
    ParameterRequestList = 55,
    Message = 56,
    MaxMessageSize = 57,
    RenewalTimeValue = 58,
    RebindingTimeValue = 59,
    ClientID = 61,
    ClientFQDN = 81,
    VendorClass = 124,
    TFTPServerName = 128,
    BootfileName = 129,
    DHCPMessageType = 53,
    End = 255,
};

pub const DHCPServer = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    state: *const StateStore,
    socket: std.net.Socket,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, config: *const Config, state: *const StateStore) !*Self {
        const socket = try std.net.Socket.create(std.net.Socket.IPv4);
        errdefer socket.close();

        try socket.setReuseaddr(true);

        const listen_addr = std.net.Address.initIp(config.listen_address, 67);
        try socket.listen(listen_addr);

        return Self{
            .allocator = allocator,
            .config = config,
            .state = state,
            .socket = socket,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn run(server: *Self) !void {
        server.running.store(true, .monotonic);
        defer server.running.store(false, .monotonic);

        const stdout = std.fs.File.stdout().deprecatedWriter();
        stdout.print("DHCP server listening on {s}:67\n", .{server.config.listen_address}) catch return;

        var buffer: [1024]u8 = undefined;

        while (server.running.load(.monotonic)) {
            const packet_result = try server.socket.receiveToEnd(&buffer);
            const packet = packet_result[0];

            const response = server.processPacket(packet) catch |err| {
                stdout.print("Error processing packet: {s}\n", .{@errorName(err)}) catch return;
                continue;
            };

            if (response) |resp| {
                _ = try server.socket.sendTo(resp, packet_result[0].source_address);
            }
        }

        stdout.print("DHCP server stopped\n", .{}) catch return;
    }

    fn processPacket(server: *Self, packet: std.net.Socket.UdpPacket) ?[]const u8 {
        // Validate DHCP packet
        if (packet.data.len < 200) return null; // DHCP min size is 200 bytes

        // Parse header
        const header = @as(*const DHCPHeader, packet.data.ptr);

        // Check magic cookie
        var magic_cookie: [4]u8 = undefined;
        @memcpy(&magic_cookie, &header.magic);
        if (magic_cookie != [4]u8{ 99, 130, 83, 99 }) {
            return null;
        }

        // Check message type option
        const message_type = server.getMessageType(packet.data) orelse return null;

        switch (message_type) {
            .DHCPDISCOVER => {
                return server.createOffer(packet.data);
            },
            .DHCPREQUEST => {
                return server.allocateLease(packet.data);
            },
            .DHCPRELEASE => {
                return server.releaseLease(packet.data);
            },
            else => {
                return null;
            },
        }
    }

    fn getMessageType(server: *Self, packet: []const u8) ?MessageType {
        // Find DHCP message type option (option 53)
        _ = server; // unused server parameter
        const options_ptr = packet.ptr + 240; // Options start at offset 240

        var pos: usize = 0;
        while (options_ptr + pos + 1 < packet.len) : (pos + 1) {
            const code = options_ptr[pos];
            const len = options_ptr[pos + 1];

            if (code == 255) break; // End option

            if (code == 0) {
                pos += 1;
                continue;
            }

            if (code == 53 and len > 0) {
                if (len > options_ptr + pos + 2 - packet.len) break;
                const type_val = options_ptr[pos + 2];
                return @as(MessageType, @intFromEnum(@as(MessageType, .DHCPDISCOVER)) + type_val);
            }

            pos += 2 + len;
        }

        return null;
    }

    fn createOffer(server: *Self, request: []const u8) ?[]u8 {
        // Validate DHCP DISCOVER message
        if (request.len < 200) return null;

        // Create response buffer
        var response: [1024]u8 = undefined;
        var response_data = @as([*]u8, &response);

        // Copy request as base
        @memcpy(response_data[0..request.len].ptr, request.ptr);
        const header: *DHCPHeader = @as(*DHCPHeader, response_data);

        // Set response fields
        header.op = 2; // BOOTREPLY
        header.yiaddr = [4]u8{ 192, 168, 1, 100 }; // Example IP

        // Build options
        var pos: usize = 240;

        // Add DHCP server identifier (option 54)
        response_data[pos] = 54;
        response_data[pos + 1] = 4;
        @memcpy(response_data[pos + 2 .. pos + 6].ptr, server.config.router.ptr);
        pos += 6;

        // Add lease time (option 51)
        response_data[pos] = 51;
        response_data[pos + 1] = 4;
        @memcpy(response_data[pos + 2 .. pos + 6].ptr, &server.config.lease_time);
        pos += 6;

        // Add router (option 3)
        response_data[pos] = 3;
        response_data[pos + 1] = 4;
        @memcpy(response_data[pos + 2 .. pos + 6].ptr, server.config.router.ptr);
        pos += 6;

        // Add DNS servers (option 6)
        response_data[pos] = 6;
        response_data[pos + 1] = 4;
        for (server.config.dns_servers, 0..) |dns, i| {
            @memcpy(response_data[pos + 2 + i * 4 .. pos + 6 + i * 4].ptr, dns.ptr);
        }
        pos += 6;

        // Add domain name (option 15)
        response_data[pos] = 15;
        response_data[pos + 1] = server.config.domain_name.len;
        @memcpy(response_data[pos + 2 .. pos + 2 + server.config.domain_name.len].ptr, server.config.domain_name.ptr);
        pos += 2 + server.config.domain_name.len;

        // Add message type (option 53) - DHCPOFFER
        response_data[pos] = 53;
        response_data[pos + 1] = 1;
        response_data[pos + 2] = 2;
        pos += 3;

        // End option
        response_data[pos] = 255;
        pos += 1;

        // Return the response
        return response_data[0..pos];
    }

    fn allocateLease(server: *Self, request: []const u8) ?[]const u8 {
        // Implement DHCPACK creation
        _ = server;
        _ = request;
        return null;
    }

    fn releaseLease(server: *Self, request: []const u8) ?[]const u8 {
        // Implement lease release
        _ = server;
        _ = request;
        return null;
    }
};

pub const Config = struct {
    listen_address: []const u8,
    subnet: []const u8,
    subnet_mask: u32,
    router: []const u8,
    dns_servers: [][]const u8,
    domain_name: []const u8,
    lease_time: u32,
    dhcp_options: std.StringHashMap(u8),
};

pub fn create_server(allocator: std.mem.Allocator, config: *const Config, state: *const StateStore) !*DHCPServer {
    return DHCPServer.create(allocator, config, state);
}

pub const StateStore = opaque {
    // State store implementation
};

pub fn StateStore_init(allocator: std.mem.Allocator, dir: []const u8) !*StateStore {
    _ = allocator;
    _ = dir;
    return undefined;
}
