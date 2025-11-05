const std = @import("std");

const DEFAULT_API_URL = "http://localhost:8000";

pub fn run(allocator: std.mem.Allocator, payload: []const u8) !void {
    var env = try EnvConfig.load(allocator);
    defer env.deinit(allocator);

    if (env.api_key.len == 0) reportMissingApiKey();

    const endpoint = try buildEndpoint(allocator, env.api_url);
    defer allocator.free(endpoint);

    std.log.info("Uploading summary to {s}...", .{endpoint});
    var response = sendPayload(allocator, endpoint, env.api_key, @constCast(payload)) catch |err| {
        std.debug.print("Connection failed. Is the server running at {s}?\n", .{env.api_url});
        return err;
    };
    defer response.deinit(allocator);

    handleResponse(response);
}

const EnvConfig = struct {
    api_url: []const u8,
    api_key: []const u8,

    fn load(allocator: std.mem.Allocator) !EnvConfig {
        const raw_url = std.process.getEnvVarOwned(allocator, "DASHBOARD_API_URL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, DEFAULT_API_URL),
            else => return err,
        };
        const trimmed_url = std.mem.trim(u8, raw_url, " \n\r\t");
        const api_url = try allocator.dupe(u8, trimmed_url);
        allocator.free(raw_url);

        const raw_key = std.process.getEnvVarOwned(allocator, "DASHBOARD_API_KEY") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        const trimmed_key = std.mem.trim(u8, raw_key, " \n\r\t");
        const api_key = try allocator.dupe(u8, trimmed_key);
        allocator.free(raw_key);

        return .{ .api_url = api_url, .api_key = api_key };
    }

    fn deinit(self: *EnvConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.api_url);
        allocator.free(self.api_key);
        self.* = undefined;
    }
};

fn reportMissingApiKey() noreturn {
    std.debug.print("Error: DASHBOARD_API_KEY not set\n", .{});
    std.debug.print("   Please add to ~/.zshrc or ~/.bashrc:\n", .{});
    std.debug.print("   export DASHBOARD_API_KEY=\"sk_team_your_api_key_here\"\n", .{});
    std.debug.print("   (optionally set DASHBOARD_API_URL for non-default endpoints)\n", .{});
    std.process.exit(1);
}

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

fn sendPayload(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    payload: []u8,
) !HttpResponse {
    var io_single = std.Io.Threaded.init_single_threaded;
    defer io_single.deinit();

    var client = std.http.Client{
        .allocator = allocator,
        .io = io_single.io(),
    };
    defer client.deinit();

    var extra_headers = [_]std.http.Header{
        .{ .name = "X-API-Key", .value = api_key },
    };

    const uri = try std.Uri.parse(endpoint);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = try uri.getHost(&host_buffer);

    return sendWithFallback(
        allocator,
        &client,
        uri,
        protocol,
        host_name,
        &extra_headers,
        payload,
    );
}

fn sendWithFallback(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    uri: std.Uri,
    protocol: std.http.Client.Protocol,
    host_name: std.Io.net.HostName,
    extra_headers: []const std.http.Header,
    payload: []u8,
) !HttpResponse {
    return sendOnce(client, uri, extra_headers, payload, null) catch |err| switch (err) {
        error.InvalidDnsCnameRecord => {
            const connection = try connectWithLibcResolver(allocator, client, uri, protocol, host_name) orelse return err;
            return sendOnce(client, uri, extra_headers, payload, connection);
        },
        else => return err,
    };
}

fn sendOnce(
    client: *std.http.Client,
    uri: std.Uri,
    extra_headers: []const std.http.Header,
    payload: []u8,
    connection: ?*std.http.Client.Connection,
) !HttpResponse {
    var request = try client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra_headers,
        .connection = connection,
        .keep_alive = false,
    });
    defer request.deinit();

    try request.sendBodyComplete(payload);
    var response = try request.receiveHead(&.{});

    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = try reader.allocRemaining(client.allocator, std.Io.Limit.limited(1024 * 1024));

    return .{
        .status = response.head.status,
        .body = body,
    };
}

fn connectWithLibcResolver(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    uri: std.Uri,
    protocol: std.http.Client.Protocol,
    host_name: std.Io.net.HostName,
) !?*std.http.Client.Connection {
    const port = uri.port orelse defaultPort(protocol);
    const ipv4 = try resolveIpv4Address(allocator, host_name.bytes, port) orelse return null;

    var literal_buffer: [16]u8 = undefined;
    const literal = try std.fmt.bufPrint(&literal_buffer, "{d}.{d}.{d}.{d}", .{
        ipv4[0],
        ipv4[1],
        ipv4[2],
        ipv4[3],
    });

    const ip_host = std.Io.net.HostName.init(literal) catch return null;
    return client.connectTcpOptions(.{
        .host = ip_host,
        .port = port,
        .protocol = protocol,
        .proxied_host = host_name,
    }) catch |err| switch (err) {
        error.InvalidDnsCnameRecord => return null,
        else => return err,
    };
}

fn resolveIpv4Address(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
) !?[4]u8 {
    const host_c = try std.mem.concatWithSentinel(allocator, u8, &.{host}, 0);
    defer allocator.free(host_c);

    var port_buffer: [8:0]u8 = undefined;
    const port_c = std.fmt.bufPrintZ(&port_buffer, "{d}", .{port}) catch unreachable;

    var hints: std.posix.addrinfo = .{
        .flags = .{},
        .family = std.posix.AF.INET,
        .socktype = std.posix.SOCK.STREAM,
        .protocol = std.posix.IPPROTO.TCP,
        .addrlen = 0,
        .addr = null,
        .canonname = null,
        .next = null,
    };

    var results: ?*std.posix.addrinfo = null;
    const rc = std.posix.system.getaddrinfo(host_c.ptr, port_c.ptr, &hints, &results);
    defer if (results) |ptr| std.posix.system.freeaddrinfo(ptr);

    if (@intFromEnum(rc) != 0) return null;

    var cursor = results;
    while (cursor) |entry| : (cursor = entry.next) {
        const sockaddr = entry.addr orelse continue;
        var storage: std.posix.sockaddr.in = undefined;
        const src_bytes = @as([*]const u8, @ptrCast(sockaddr))[0..@sizeOf(std.posix.sockaddr.in)];
        @memcpy(std.mem.asBytes(&storage), src_bytes);
        return @bitCast(storage.addr);
    }

    return null;
}

fn buildEndpoint(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
    const trimmed = trimTrailingSlash(base);
    return std.fmt.allocPrint(allocator, "{s}/api/usage/report", .{trimmed});
}

fn defaultPort(protocol: std.http.Client.Protocol) u16 {
    return switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

fn handleResponse(response: HttpResponse) void {
    switch (response.status) {
        .ok => {
            std.debug.print("Usage reported successfully\n", .{});
        },
        .unauthorized => {
            std.debug.print("Authentication failed: Invalid or inactive API key\n", .{});
        },
        .unprocessable_entity => {
            std.debug.print("Data validation error. See server logs for details.\n", .{});
        },
        .internal_server_error => {
            std.debug.print("Server error. Please try again later.\n", .{});
        },
        else => {
            std.debug.print(
                "Failed to report usage (HTTP {d})\n",
                .{@intFromEnum(response.status)},
            );
            std.debug.print("Check server logs for diagnostics.\n", .{});
        },
    }
}
