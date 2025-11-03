const std = @import("std");
const tokenuze = @import("tokenuze");

const CliError = error{
    InvalidUsage,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const filters = parseFilters(allocator) catch {
        std.process.exit(1);
    };
    try tokenuze.run(allocator, filters);
}

fn parseFilters(allocator: std.mem.Allocator) CliError!tokenuze.DateFilters {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // program name

    var filters = tokenuze.DateFilters{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--since")) {
            const value = args.next() orelse return cliError("missing value for --since", .{});
            if (filters.since != null) return cliError("--since provided more than once", .{});
            const iso = tokenuze.parseFilterDate(value) catch |err| switch (err) {
                error.InvalidFormat => return cliError("--since expects date in YYYYMMDD", .{}),
                error.InvalidDate => return cliError("--since is not a valid calendar date", .{}),
            };
            filters.since = iso;
            continue;
        }

        if (std.mem.eql(u8, arg, "--until")) {
            const value = args.next() orelse return cliError("missing value for --until", .{});
            if (filters.until != null) return cliError("--until provided more than once", .{});
            const iso = tokenuze.parseFilterDate(value) catch |err| switch (err) {
                error.InvalidFormat => return cliError("--until expects date in YYYYMMDD", .{}),
                error.InvalidDate => return cliError("--until is not a valid calendar date", .{}),
            };
            filters.until = iso;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            return cliError("unknown option: {s}", .{arg});
        }

        return cliError("unexpected argument: {s}", .{arg});
    }

    if (filters.since) |since_value| {
        if (filters.until) |until_value| {
            if (std.mem.lessThan(u8, until_value[0..], since_value[0..])) {
                return cliError("--until must be on or after --since", .{});
            }
        }
    }

    return filters;
}

fn cliError(comptime fmt: []const u8, args: anytype) CliError {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return CliError.InvalidUsage;
}
