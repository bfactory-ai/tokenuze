const std = @import("std");
const model = @import("../model.zig");
const provider = @import("provider.zig");

const RawUsage = model.RawTokenUsage;
const ModelState = provider.ModelState;

const fallback_pricing = [_]provider.FallbackPricingEntry{
    .{ .name = "gpt-5", .pricing = .{
        .input_cost_per_m = 1.25,
        .cache_creation_cost_per_m = 1.25,
        .cached_input_cost_per_m = 0.125,
        .output_cost_per_m = 10.0,
    } },
    .{ .name = "gpt-5-codex", .pricing = .{
        .input_cost_per_m = 1.25,
        .cache_creation_cost_per_m = 1.25,
        .cached_input_cost_per_m = 0.125,
        .output_cost_per_m = 10.0,
    } },
};

const ProviderExports = provider.makeProvider(.{
    .name = "codex",
    .sessions_dir_suffix = "/.codex/sessions",
    .legacy_fallback_model = "gpt-5",
    .fallback_pricing = fallback_pricing[0..],
    .cached_counts_overlap_input = true,
    .parse_session_fn = parseCodexSessionFile,
});

pub const collect = ProviderExports.collect;
pub const streamEvents = ProviderExports.streamEvents;
pub const loadPricingData = ProviderExports.loadPricingData;
pub const EventConsumer = ProviderExports.EventConsumer;

fn parseCodexSessionFile(
    allocator: std.mem.Allocator,
    ctx: *const provider.ParseContext,
    session_id: []const u8,
    file_path: []const u8,
    deduper: ?*provider.MessageDeduper,
    timezone_offset_minutes: i32,
    events: *std.ArrayList(model.TokenUsageEvent),
) !void {
    _ = deduper;
    var previous_totals: ?RawUsage = null;
    var model_state = ModelState{};

    var handler = CodexLineHandler{
        .ctx = ctx,
        .allocator = allocator,
        .file_path = file_path,
        .session_id = session_id,
        .events = events,
        .previous_totals = &previous_totals,
        .model_state = &model_state,
        .timezone_offset_minutes = timezone_offset_minutes,
    };

    try provider.streamJsonLines(
        allocator,
        ctx,
        file_path,
        .{
            .max_bytes = 128 * 1024 * 1024,
            .open_error_message = "unable to open session file",
            .read_error_message = "error while reading session stream",
            .advance_error_message = "error while advancing session stream",
        },
        &handler,
        CodexLineHandler.handle,
    );
}

const CodexLineHandler = struct {
    ctx: *const provider.ParseContext,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    session_id: []const u8,
    events: *std.ArrayList(model.TokenUsageEvent),
    previous_totals: *?RawUsage,
    model_state: *ModelState,
    timezone_offset_minutes: i32,

    fn handle(self: *CodexLineHandler, line: []const u8, line_index: usize) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;

        var parsed_line = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch |err| {
            std.log.warn(
                "{s}: failed to parse codex session file '{s}' line {d} ({s})",
                .{ self.ctx.provider_name, self.file_path, line_index, @errorName(err) },
            );
            return;
        };
        defer parsed_line.deinit();

        const record = switch (parsed_line.value) {
            .object => |obj| obj,
            else => return,
        };

        const type_slice = valueAsString(record.get("type")) orelse return;
        if (std.mem.eql(u8, type_slice, "turn_context")) {
            self.handleTurnContext(record);
            return;
        }
        if (std.mem.eql(u8, type_slice, "event_msg")) {
            self.handleEventMessage(record) catch |err| {
                std.log.warn(
                    "{s}: failed to process codex session file '{s}' line {d} ({s})",
                    .{ self.ctx.provider_name, self.file_path, line_index, @errorName(err) },
                );
            };
        }
    }

    fn handleTurnContext(self: *CodexLineHandler, record: std.json.ObjectMap) void {
        const payload_value = record.get("payload") orelse return;
        const payload_obj = switch (payload_value) {
            .object => |obj| obj,
            else => return,
        };

        var payload_model: ?[]const u8 = null;
        captureModelFromPayload(payload_obj, &payload_model);
        if (payload_model) |model_slice| {
            _ = self.ctx.captureModel(self.allocator, self.model_state, model_slice) catch |err| {
                self.ctx.logWarning(self.file_path, "failed to capture model", err);
            };
        }
    }

    fn handleEventMessage(self: *CodexLineHandler, record: std.json.ObjectMap) !void {
        const timestamp_info = try provider.timestampFromValue(self.allocator, self.timezone_offset_minutes, record.get("timestamp")) orelse return;

        const payload_value = record.get("payload") orelse return;
        const payload_obj = switch (payload_value) {
            .object => |obj| obj,
            else => return,
        };

        const payload_type = valueAsString(payload_obj.get("type")) orelse return;
        if (!std.mem.eql(u8, payload_type, "token_count")) return;

        const info_value = payload_obj.get("info") orelse return;
        const info_obj = switch (info_value) {
            .object => |obj| obj,
            else => return,
        };

        var payload_model: ?[]const u8 = null;
        captureModelFromPayload(payload_obj, &payload_model);

        var delta_usage: ?model.TokenUsage = null;
        if (parseCodexUsage(info_obj.get("last_token_usage"))) |last_raw| {
            delta_usage = model.TokenUsage.fromRaw(last_raw);
        } else if (parseCodexUsage(info_obj.get("total_token_usage"))) |total_raw| {
            delta_usage = model.TokenUsage.deltaFrom(total_raw, self.previous_totals.*);
            self.previous_totals.* = total_raw;
        } else {
            return;
        }

        var delta = delta_usage.?;
        self.ctx.normalizeUsageDelta(&delta);
        if (delta.input_tokens == 0 and delta.cached_input_tokens == 0 and delta.output_tokens == 0 and delta.reasoning_output_tokens == 0) {
            return;
        }

        const resolved_model = (try self.ctx.requireModel(self.allocator, self.model_state, payload_model)) orelse return;
        const event = model.TokenUsageEvent{
            .session_id = self.session_id,
            .timestamp = timestamp_info.text,
            .local_iso_date = timestamp_info.local_iso_date,
            .model = resolved_model.name,
            .usage = delta,
            .is_fallback = resolved_model.is_fallback,
            .display_input_tokens = self.ctx.computeDisplayInput(delta),
        };
        try self.events.append(self.allocator, event);
    }
};

fn parseCodexUsage(value: ?std.json.Value) ?RawUsage {
    const usage_value = value orelse return null;
    const usage_obj = switch (usage_value) {
        .object => |obj| obj,
        else => return null,
    };

    var accumulator = model.UsageAccumulator{};
    var iterator = usage_obj.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = model.usageFieldForKey(key) orelse {
            continue;
        };
        const amount = provider.jsonValueToU64(entry.value_ptr.*);
        accumulator.applyField(field, amount);
    }
    return accumulator.finalize();
}

fn captureModelFromPayload(payload_obj: std.json.ObjectMap, storage: *?[]const u8) void {
    captureModelField(payload_obj.get("model"), storage);
    captureModelField(payload_obj.get("model_name"), storage);
    if (storage.* != null) return;

    if (payload_obj.get("metadata")) |metadata_value| {
        captureModelFromMetadata(metadata_value, storage);
    }
}

fn captureModelField(value: ?std.json.Value, storage: *?[]const u8) void {
    if (storage.* != null) return;
    const slice = valueAsString(value) orelse return;
    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (trimmed.len == 0) return;
    storage.* = trimmed;
}

fn captureModelFromMetadata(value: std.json.Value, storage: *?[]const u8) void {
    if (storage.* != null) return;
    switch (value) {
        .object => |obj| {
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                const child = entry.value_ptr.*;
                if (isModelKey(key)) {
                    captureModelField(child, storage);
                } else {
                    captureModelFromMetadata(child, storage);
                }
                if (storage.* != null) return;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                captureModelFromMetadata(item, storage);
                if (storage.* != null) return;
            }
        },
        else => {},
    }
}

fn valueAsString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return switch (actual) {
        .string => |slice| slice,
        else => null,
    };
}

fn isModelKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "model") or std.mem.eql(u8, key, "model_name");
}

test "codex parser emits usage events from token_count entries" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const worker_allocator = arena_state.allocator();

    var events = std.ArrayList(model.TokenUsageEvent){};
    defer events.deinit(worker_allocator);

    const ctx = provider.ParseContext{
        .provider_name = "codex-test",
        .legacy_fallback_model = "gpt-5",
        .cached_counts_overlap_input = true,
    };

    try parseCodexSessionFile(
        worker_allocator,
        &ctx,
        "codex-fixture",
        "fixtures/codex/basic.jsonl",
        null,
        0,
        &events,
    );

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    const event = events.items[0];
    try std.testing.expectEqualStrings("codex-fixture", event.session_id);
    try std.testing.expectEqualStrings("gpt-5-codex", event.model);
    try std.testing.expect(!event.is_fallback);
    try std.testing.expectEqual(@as(u64, 1000), event.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 200), event.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(u64, 50), event.usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 1200), event.display_input_tokens);
}
