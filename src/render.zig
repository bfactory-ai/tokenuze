const std = @import("std");
const Model = @import("model.zig");

pub const Renderer = struct {
    const INDENT = "  ";

    pub fn writeSummary(writer: anytype, summaries: []const Model.DailySummary, totals: *const Model.SummaryTotals) !void {
        try writer.writeAll("{");
        try writeKeyPrefix(writer, 1, "days");
        try writer.writeAll("[");
        if (summaries.len != 0) {
            for (summaries, 0..) |summary, index| {
                try writeIndent(writer, 2);
                try writeDailySummary(writer, summary, 2);
                if (index + 1 != summaries.len) try writer.writeAll(",");
            }
            try writeIndent(writer, 1);
        }
        try writer.writeAll("],");
        try writeKeyPrefix(writer, 1, "total");
        try writeTotals(writer, totals, 1);
        try writeIndent(writer, 0);
        try writer.writeAll("}\n");
    }

    fn writeDailySummary(writer: anytype, summary: Model.DailySummary, indent: usize) !void {
        try writer.writeAll("{");
        try writeKeyPrefix(writer, indent + 1, "date");
        try writeJsonString(writer, summary.display_date);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "iso_date");
        try writeJsonString(writer, summary.iso_date);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "input_tokens");
        try writeUint(writer, summary.usage.input_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "cached_input_tokens");
        try writeUint(writer, summary.usage.cached_input_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "output_tokens");
        try writeUint(writer, summary.usage.output_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "reasoning_output_tokens");
        try writeUint(writer, summary.usage.reasoning_output_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "total_tokens");
        try writeUint(writer, summary.usage.total_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "cost_usd");
        try writeFloat(writer, summary.cost_usd);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "models");
        try writer.writeAll("[");
        if (summary.models.items.len != 0) {
            for (summary.models.items, 0..) |model, idx| {
                try writeIndent(writer, indent + 2);
                try writeModel(writer, model, indent + 2);
                if (idx + 1 != summary.models.items.len) try writer.writeAll(",");
            }
            try writeIndent(writer, indent + 1);
        }
        try writer.writeAll("],");
        try writeKeyPrefix(writer, indent + 1, "missing_pricing");
        try writer.writeAll("[");
        if (summary.missing_pricing.items.len != 0) {
            for (summary.missing_pricing.items, 0..) |name, idx| {
                try writeIndent(writer, indent + 2);
                try writeJsonString(writer, name);
                if (idx + 1 != summary.missing_pricing.items.len) try writer.writeAll(",");
            }
            try writeIndent(writer, indent + 1);
        }
        try writer.writeAll("]");
        try writeIndent(writer, indent);
        try writer.writeAll("}");
    }

    fn writeModel(writer: anytype, model: Model.ModelSummary, indent: usize) !void {
        try writer.writeAll("{");
        try writeKeyPrefix(writer, indent + 1, "name");
        try writeJsonString(writer, model.name);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "display_name");
        if (model.is_fallback) {
            var buffer: [128]u8 = undefined;
            const display = std.fmt.bufPrint(&buffer, "{s} (fallback)", .{model.name}) catch model.name;
            try writeJsonString(writer, display);
        } else {
            try writeJsonString(writer, model.name);
        }
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "is_fallback");
        try writer.writeAll(if (model.is_fallback) "true" else "false");
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "input_tokens");
        try writeUint(writer, model.usage.input_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "cached_input_tokens");
        try writeUint(writer, model.usage.cached_input_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "output_tokens");
        try writeUint(writer, model.usage.output_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "reasoning_output_tokens");
        try writeUint(writer, model.usage.reasoning_output_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "total_tokens");
        try writeUint(writer, model.usage.total_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "cost_usd");
        try writeFloat(writer, model.cost_usd);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "pricing_available");
        try writer.writeAll(if (model.pricing_available) "true" else "false");
        try writeIndent(writer, indent);
        try writer.writeAll("}");
    }

    fn writeTotals(writer: anytype, totals: *const Model.SummaryTotals, indent: usize) !void {
        try writer.writeAll("{");
        try writeKeyPrefix(writer, indent + 1, "input_tokens");
        try writeUint(writer, totals.usage.input_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "cached_input_tokens");
        try writeUint(writer, totals.usage.cached_input_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "output_tokens");
        try writeUint(writer, totals.usage.output_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "reasoning_output_tokens");
        try writeUint(writer, totals.usage.reasoning_output_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "total_tokens");
        try writeUint(writer, totals.usage.total_tokens);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "cost_usd");
        try writeFloat(writer, totals.cost_usd);
        try writer.writeAll(",");
        try writeKeyPrefix(writer, indent + 1, "missing_pricing");
        try writer.writeAll("[");
        if (totals.missing_pricing.items.len != 0) {
            for (totals.missing_pricing.items, 0..) |name, idx| {
                try writeIndent(writer, indent + 2);
                try writeJsonString(writer, name);
                if (idx + 1 != totals.missing_pricing.items.len) try writer.writeAll(",");
            }
            try writeIndent(writer, indent + 1);
        }
        try writer.writeAll("]");
        try writeIndent(writer, indent);
        try writer.writeAll("}");
    }

    fn writeFloat(writer: anytype, value: f64) !void {
        if (value == 0) {
            try writer.writeAll("0.0");
            return;
        }
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d:.2}", .{value});
        try writer.writeAll(text);
    }

    fn writeUint(writer: anytype, value: u64) !void {
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        try writer.writeAll(text);
    }

    fn writeJsonString(writer: anytype, value: []const u8) !void {
        try writer.writeAll("\"");
        for (value) |ch| {
            switch (ch) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (ch < 0x20) {
                        var buf: [6]u8 = undefined;
                        const formatted = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{ch}) catch unreachable;
                        try writer.writeAll(formatted);
                    } else {
                        try writer.writeAll(&[_]u8{ch});
                    }
                },
            }
        }
        try writer.writeAll("\"");
    }

    fn writeIndent(writer: anytype, level: usize) !void {
        try writer.writeAll("\n");
        var i: usize = 0;
        while (i < level) : (i += 1) {
            try writer.writeAll(INDENT);
        }
    }

    fn writeKeyPrefix(writer: anytype, indent: usize, key: []const u8) !void {
        try writeIndent(writer, indent);
        try writer.writeAll("\"");
        try writer.writeAll(key);
        try writer.writeAll("\": ");
    }
};
