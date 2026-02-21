/home/ryan-local/Documents/zig/stardust/src/config.zig line 244 has these fields:
  listen_address: []const u8,
  subnet: []const u8,
  subnet_mask: u32,
  router: []const u8,
  dns_servers: [][]const u8,
  domain_name: []const u8,
  lease_time: u32,
  dhcp_options: std.StringHashMap(u8),

But our config struct in config.zig has:
  listen_address: std.net.Address,
  listen_port: u16,
  subnet: std.net.Address.Unspecified,
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

So we need to:
1. Convert config.load to use the right types
2. Adapt the dhcp config to match the loaded config
