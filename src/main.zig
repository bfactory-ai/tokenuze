const std = @import("std");
const builtin = @import("builtin");
const tokenuze = @import("tokenuze");
const build_options = @import("build_options");

const CliError = error{
    InvalidUsage,
    OutOfMemory,
};

const CliOptions = struct {
    filters: tokenuze.DateFilters = .{},
    machine_id: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    providers: tokenuze.ProviderSelection = tokenuze.ProviderSelection.initAll(),
    upload: bool = false,
};

const OptionId = enum {
    since,
    until,
    tz,
    pretty,
    agent,
    upload,
    machine_id,
    version,
    help,
};

const OptionArgKind = enum {
    flag,
    value,
};

const OptionSpec = struct {
    id: OptionId,
    long_name: []const u8,
    short_name: ?u8 = null,
    value_name: ?[]const u8 = null,
    desc: []const u8,
    kind: OptionArgKind = .flag,
};

const option_specs = [_]OptionSpec{
    .{ .id = .since, .long_name = "since", .value_name = "YYYYMMDD", .desc = "Only include events on/after the date", .kind = .value },
    .{ .id = .until, .long_name = "until", .value_name = "YYYYMMDD", .desc = "Only include events on/before the date", .kind = .value },
    .{ .id = .tz, .long_name = "tz", .value_name = "<offset>", .desc = "Bucket dates in the provided timezone (default: {s})", .kind = .value },
    .{ .id = .pretty, .long_name = "pretty", .desc = "Expand JSON output for readability" },
    .{ .id = .agent, .long_name = "agent", .value_name = "<name>", .desc = "Restrict collection to selected providers (available: {s})", .kind = .value },
    .{ .id = .upload, .long_name = "upload", .desc = "Upload Tokenuze JSON via DASHBOARD_API_* envs" },
    .{ .id = .machine_id, .long_name = "machine-id", .desc = "Print the stable machine id and exit" },
    .{ .id = .version, .long_name = "version", .desc = "Print the Tokenuze version and exit" },
    .{ .id = .help, .long_name = "help", .short_name = 'h', .desc = "Show this message and exit" },
};

var debug_allocator = std.heap.DebugAllocator(.{}){};

pub fn main() !void {
    const native_os = builtin.target.os.tag;
    const choice = blk: {
        if (native_os == .wasi) break :blk .{ .allocator = std.heap.wasm_allocator, .is_debug = false };
        break :blk switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ .allocator = debug_allocator.allocator(), .is_debug = true },
            .ReleaseFast, .ReleaseSmall => .{ .allocator = std.heap.smp_allocator, .is_debug = false },
        };
    };
    defer if (choice.is_debug) {
        _ = debug_allocator.deinit();
    };

    const allocator = choice.allocator;

    const options = parseOptions(allocator) catch |err| switch (err) {
        CliError.InvalidUsage => {
            std.process.exit(1);
        },
        else => return err,
    };
    if (options.show_help) {
        try printHelp();
        return;
    }
    if (options.show_version) {
        try printVersion();
        return;
    }
    if (options.machine_id) {
        try printMachineId(allocator);
        return;
    }
    if (options.upload) {
        var uploads = std.ArrayList(tokenuze.uploader.ProviderUpload).empty;
        defer uploads.deinit(allocator);

        for (tokenuze.providers, 0..) |provider, idx| {
            if (!options.providers.includesIndex(idx)) continue;
            var single = tokenuze.ProviderSelection.initEmpty();
            single.includeIndex(idx);
            var report = try tokenuze.collectUploadReport(allocator, options.filters, single);
            const entry = tokenuze.uploader.ProviderUpload{
                .name = provider.name,
                .daily_summary = report.daily_json,
                .sessions_summary = report.sessions_json,
                .weekly_summary = report.weekly_json,
            };
            uploads.append(allocator, entry) catch |err| {
                report.deinit(allocator);
                return err;
            };
        }

        if (uploads.items.len == 0) {
            std.log.err("No providers selected for upload; use --agent to pick at least one provider.", .{});
            return;
        }

        defer for (uploads.items) |entry| {
            allocator.free(entry.daily_summary);
            allocator.free(entry.sessions_summary);
            allocator.free(entry.weekly_summary);
        };
        try tokenuze.uploader.run(
            allocator,
            uploads.items,
            options.filters.timezone_offset_minutes,
        );
        return;
    }
    try tokenuze.run(allocator, options.filters, options.providers);
}

fn parseOptions(allocator: std.mem.Allocator) CliError!CliOptions {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // program name

    var options = CliOptions{};
    var timezone_specified = false;
    var agents_specified = false;
    var machine_id_only = false;
    while (args.next()) |arg| {
        const maybe_spec = classifyArg(arg) catch |err| switch (err) {
            CliError.InvalidUsage => return err,
            else => return err,
        };

        if (maybe_spec) |spec| {
            switch (spec.id) {
                .help => {
                    options.show_help = true;
                    break;
                },
                .version => {
                    options.show_version = true;
                    break;
                },
                .machine_id => {
                    if (!options.machine_id) {
                        options.machine_id = true;
                        options.filters = .{};
                        options.providers = tokenuze.ProviderSelection.initAll();
                    }
                    machine_id_only = true;
                    continue;
                },
                else => {},
            }

            if (machine_id_only) {
                if (optionTakesValue(spec)) skipOptionValue(&args);
                continue;
            }

            try applyOption(spec, &args, &options, &timezone_specified, &agents_specified);
            continue;
        }

        if (machine_id_only) continue;

        return cliError("unexpected argument: {s}", .{arg});
    }

    if (options.filters.since) |since_value| {
        if (options.filters.until) |until_value| {
            if (std.mem.lessThan(u8, until_value[0..], since_value[0..])) {
                return cliError("--until must be on or after --since", .{});
            }
        }
    }

    if (!timezone_specified) {
        const fallback_offset = tokenuze.DEFAULT_TIMEZONE_OFFSET_MINUTES;
        const detected = tokenuze.detectLocalTimezoneOffsetMinutes() catch fallback_offset;
        const clamped = std.math.clamp(detected, -12 * 60, 14 * 60);
        options.filters.timezone_offset_minutes = @intCast(clamped);
    }

    return options;
}

fn optionSpecs() []const OptionSpec {
    return option_specs[0..];
}

fn classifyArg(arg: []const u8) CliError!?*const OptionSpec {
    if (!std.mem.startsWith(u8, arg, "-")) return null;
    if (arg.len < 2) return cliError("unknown option: {s}", .{arg});

    if (arg[1] == '-') {
        if (arg.len == 2) return cliError("unknown option: {s}", .{arg});
        const name = arg[2..];
        if (findLongOption(name)) |spec| return spec;
        return cliError("unknown option: {s}", .{arg});
    }

    if (arg.len != 2) return cliError("unknown option: {s}", .{arg});
    if (findShortOption(arg[1])) |spec| return spec;
    return cliError("unknown option: {s}", .{arg});
}

fn findLongOption(name: []const u8) ?*const OptionSpec {
    for (option_specs, 0..) |spec, idx| {
        if (std.mem.eql(u8, spec.long_name, name)) return &option_specs[idx];
    }
    return null;
}

fn findShortOption(short: u8) ?*const OptionSpec {
    for (option_specs, 0..) |spec, idx| {
        if (spec.short_name) |alias| {
            if (alias == short) return &option_specs[idx];
        }
    }
    return null;
}

fn optionTakesValue(spec: *const OptionSpec) bool {
    return spec.kind == .value;
}

fn skipOptionValue(args: *std.process.ArgIterator) void {
    _ = args.next();
}

fn applyOption(
    spec: *const OptionSpec,
    args: *std.process.ArgIterator,
    options: *CliOptions,
    timezone_specified: *bool,
    agents_specified: *bool,
) CliError!void {
    switch (spec.id) {
        .upload => options.upload = true,
        .pretty => options.filters.pretty_output = true,
        .since => {
            const value = args.next() orelse return missingValueError(spec.long_name);
            if (options.filters.since != null) return cliError("--since provided more than once", .{});
            const iso = tokenuze.parseFilterDate(value) catch |err| switch (err) {
                error.InvalidFormat => return cliError("--since expects date in YYYYMMDD", .{}),
                error.InvalidDate => return cliError("--since is not a valid calendar date", .{}),
            };
            options.filters.since = iso;
        },
        .until => {
            const value = args.next() orelse return missingValueError(spec.long_name);
            if (options.filters.until != null) return cliError("--until provided more than once", .{});
            const iso = tokenuze.parseFilterDate(value) catch |err| switch (err) {
                error.InvalidFormat => return cliError("--until expects date in YYYYMMDD", .{}),
                error.InvalidDate => return cliError("--until is not a valid calendar date", .{}),
            };
            options.filters.until = iso;
        },
        .tz => {
            const value = args.next() orelse return missingValueError(spec.long_name);
            const offset = tokenuze.parseTimezoneOffsetMinutes(value) catch {
                return cliError("--tz expects an offset like '+09', '-05:30', or 'UTC'", .{});
            };
            options.filters.timezone_offset_minutes = @intCast(offset);
            timezone_specified.* = true;
        },
        .agent => {
            const value = args.next() orelse return missingValueError(spec.long_name);
            if (!agents_specified.*) {
                agents_specified.* = true;
                options.providers = tokenuze.ProviderSelection.initEmpty();
            }
            if (tokenuze.findProviderIndex(value)) |index| {
                options.providers.includeIndex(index);
            } else {
                return cliError("unknown agent '{s}' (expected one of: {s})", .{ value, providerListDescription() });
            }
        },
        else => unreachable,
    }
}

fn missingValueError(name: []const u8) CliError {
    return cliError("missing value for --{s}", .{name});
}

fn printMachineId(allocator: std.mem.Allocator) !void {
    const id = try tokenuze.machine_id.getMachineId(allocator);
    var buffer: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout.interface;
    try writer.print("{s}\n", .{id[0..]});
    writer.flush() catch |err| switch (err) {
        error.WriteFailed => {},
        else => return err,
    };
}

fn printHelp() !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout.interface;
    try writer.print(
        \\Tokenuze aggregates model usage logs into daily summaries.
        \\Usage:
        \\  tokenuze [options]
        \\
        \\Options:
        \\
    , .{});

    const default_tz_offset = tokenuze.detectLocalTimezoneOffsetMinutes() catch tokenuze.DEFAULT_TIMEZONE_OFFSET_MINUTES;
    var tz_label_buf: [16]u8 = undefined;
    const tz_label = formatOffsetLabel(&tz_label_buf, default_tz_offset);

    var max_label: usize = 0;
    for (optionSpecs()) |spec| {
        const length = optionLabelLength(&spec);
        if (length > max_label) max_label = length;
    }

    for (optionSpecs()) |spec| {
        var desc_buf: [192]u8 = undefined;
        const desc = optionDescription(&spec, tz_label, desc_buf[0..]);
        try printOptionLine(writer, &spec, desc, max_label);
    }

    try writer.print(
        \\
        \\When no providers are specified, Tokenuze queries all known providers.
        \\
    , .{});
    try writer.flush();
}

fn optionDescription(spec: *const OptionSpec, tz_label: []const u8, buffer: []u8) []const u8 {
    return switch (spec.id) {
        .agent => std.fmt.bufPrint(
            buffer,
            "Restrict collection to selected providers (available: {s})",
            .{providerListDescription()},
        ) catch spec.desc,
        .tz => std.fmt.bufPrint(
            buffer,
            "Bucket dates in the provided timezone (default: {s})",
            .{tz_label},
        ) catch spec.desc,
        else => spec.desc,
    };
}

fn printOptionLine(writer: anytype, spec: *const OptionSpec, desc: []const u8, max_label: usize) !void {
    try writer.writeAll("  ");
    try writeOptionLabel(writer, spec);
    const label_len = optionLabelLength(spec);
    var padding = if (max_label > label_len) max_label - label_len else 0;
    while (padding > 0) : (padding -= 1) try writer.writeByte(' ');
    try writer.print("  {s}\n", .{desc});
}

fn writeOptionLabel(writer: anytype, spec: *const OptionSpec) !void {
    if (spec.short_name) |short| {
        try writer.print("-{c}", .{short});
        if (spec.long_name.len != 0) {
            try writer.writeAll(", ");
        }
    }
    if (spec.long_name.len != 0) {
        try writer.print("--{s}", .{spec.long_name});
    }
    if (spec.value_name) |value| {
        try writer.print(" {s}", .{value});
    }
}

fn optionLabelLength(spec: *const OptionSpec) usize {
    var length: usize = 0;
    if (spec.short_name != null) {
        length += 2; // "-x"
        if (spec.long_name.len != 0) {
            length += 2; // ", "
        }
    }
    if (spec.long_name.len != 0) {
        length += 2 + spec.long_name.len; // "--"
    }
    if (spec.value_name) |value| {
        length += 1 + value.len;
    }
    return length;
}

fn formatOffsetLabel(buffer: *[16]u8, offset_minutes: i32) []const u8 {
    return tokenuze.formatTimezoneLabel(buffer, offset_minutes);
}

fn printVersion() !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout.interface;
    try writer.print("{s}\n", .{build_options.version});
    writer.flush() catch |err| switch (err) {
        error.WriteFailed => {},
        else => return err,
    };
}

fn cliError(comptime fmt: []const u8, args: anytype) CliError {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return CliError.InvalidUsage;
}

fn providerListDescription() []const u8 {
    return tokenuze.provider_list_description;
}
