const std = @import("std");

pub const Alignment = enum { left, right };

pub const Column = struct {
    header: []const u8,
    alignment: Alignment,
};

pub fn formatNumber(allocator: std.mem.Allocator, value: u64) ![]const u8 {
    var buf: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{d}", .{value});
    return allocator.dupe(u8, formatted);
}

pub fn formatCurrency(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    var buf: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "${d:.2}", .{value});
    return allocator.dupe(u8, formatted);
}

pub fn updateWidths(widths: []usize, cells: []const []const u8, column_usage: []const bool) void {
    for (cells, 0..) |cell, idx| {
        if (!column_usage[idx]) continue;
        if (cell.len > widths[idx]) widths[idx] = cell.len;
    }
}

pub fn writeRule(writer: anytype, widths: []const usize, column_usage: []const bool, ch: u8) !void {
    try writer.writeAll("+");
    for (widths, 0..) |width, idx| {
        if (!column_usage[idx]) continue;
        try writer.splatByteAll(ch, width + 2);
        try writer.writeAll("+");
    }
    try writer.writeAll("\n");
}

pub fn writeRow(
    writer: anytype,
    widths: []const usize,
    cells: []const []const u8,
    columns: []const Column,
    column_usage: []const bool,
) !void {
    try writer.writeAll("|");
    for (cells, 0..) |cell, idx| {
        if (!column_usage[idx]) continue;
        const width = widths[idx];
        const alignment = columns[idx].alignment;
        const padding = if (width > cell.len) width - cell.len else 0;
        try writer.writeAll(" ");
        switch (alignment) {
            .left => {
                try writer.writeAll(cell);
                try writer.splatByteAll(' ', padding);
            },
            .right => {
                try writer.splatByteAll(' ', padding);
                try writer.writeAll(cell);
            },
        }
        try writer.writeAll(" ");
        try writer.writeAll("|");
    }
    try writer.writeAll("\n");
}

test "formatNumber prints plain digits" {
    const allocator = std.testing.allocator;
    const out = try formatNumber(allocator, 1_234_567);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1234567", out);
}

test "formatCurrency prints dollars with two decimals" {
    const allocator = std.testing.allocator;
    const out = try formatCurrency(allocator, 12.3);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("$12.30", out);
}

test "writeRow respects alignment and widths" {
    const Alloc = std.testing.allocator;
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(Alloc);

    const TestWriter = struct {
        list: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.alloc, bytes);
        }

        pub fn splatByteAll(self: *@This(), byte: u8, count: usize) !void {
            try self.list.ensureTotalCapacity(self.alloc, self.list.items.len + count);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                self.list.appendAssumeCapacity(byte);
            }
        }
    };

    var writer = TestWriter{ .list = &list, .alloc = Alloc };

    const columns = [_]Column{
        .{ .header = "Left", .alignment = .left },
        .{ .header = "Right", .alignment = .right },
    };
    var widths = [_]usize{ 4, 5 };
    const cells = [_][]const u8{ "a", "b" };
    const usage = [_]bool{ true, true };

    try writeRow(&writer, &widths, &cells, &columns, &usage);
    const got = list.items;
    try std.testing.expectEqualStrings("| a    |     b |\n", got);
}
