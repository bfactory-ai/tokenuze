const std = @import("std");
const Model = @import("model.zig");
const codex = @import("providers/codex.zig");
const render = @import("render.zig");

pub const std_options = .{
    .log_level = .info,
};

pub const DateFilters = Model.DateFilters;
pub const ParseDateError = Model.ParseDateError;
pub const ModelSummary = Model.ModelSummary;
pub const DailySummary = Model.DailySummary;
pub const SummaryTotals = Model.SummaryTotals;
pub const parseFilterDate = Model.parseFilterDate;

pub fn run(allocator: std.mem.Allocator, filters: DateFilters) !void {
    const progress_root = std.Progress.start(.{ .root_name = "Tokenuze" });
    errdefer std.Progress.setStatus(.failure);
    defer std.Progress.Node.end(progress_root);

    var total_timer = try std.time.Timer.start();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var events = std.ArrayListUnmanaged(Model.TokenUsageEvent){};
    defer events.deinit(allocator);

    var pricing_map = Model.PricingMap.init(allocator);
    defer pricing_map.deinit();

    var collect_timer = try std.time.Timer.start();
    {
        const collect_progress = std.Progress.Node.start(progress_root, "collect codex", 0);
        defer std.Progress.Node.end(collect_progress);
        try codex.collect(allocator, arena, &events, &pricing_map, collect_progress);
    }
    std.log.info(
        "phase.collect completed in {d:.2}ms (events={d}, pricing_models={d})",
        .{ nsToMs(collect_timer.read()), events.items.len, pricing_map.count() },
    );

    var out_writer = OutputWriter{ .file = std.fs.File.stdout() };

    if (events.items.len == 0) {
        std.log.info("no events to process; total runtime {d:.2}ms", .{nsToMs(total_timer.read())});
        {
            const write_progress = std.Progress.Node.start(progress_root, "write output", 0);
            defer std.Progress.Node.end(write_progress);
            try out_writer.writeAll("{\"days\":[],\"total\":{\"input_tokens\":0,\"cached_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":0,\"cost_usd\":0.0,\"missing_pricing\":[]}}\n");
        }
        std.Progress.setStatus(.success);
        return;
    }

    var sort_events_timer = try std.time.Timer.start();
    {
        const sort_progress = std.Progress.Node.start(progress_root, "sort events", 0);
        defer std.Progress.Node.end(sort_progress);
        std.sort.pdq(Model.TokenUsageEvent, events.items, {}, eventLessThan);
    }
    std.log.info(
        "phase.sort_events completed in {d:.2}ms (events={d})",
        .{ nsToMs(sort_events_timer.read()), events.items.len },
    );

    var summaries = std.ArrayListUnmanaged(DailySummary){};
    defer {
        for (summaries.items) |*summary| {
            summary.deinit(allocator);
        }
        summaries.deinit(allocator);
    }

    var date_index = std.StringHashMap(usize).init(allocator);
    defer date_index.deinit();

    var build_timer = try std.time.Timer.start();
    {
        const build_progress = std.Progress.Node.start(progress_root, "build summaries", 0);
        defer std.Progress.Node.end(build_progress);
        try Model.buildDailySummaries(allocator, arena, events.items, &summaries, &date_index, filters);
    }
    std.log.info(
        "phase.build_summaries completed in {d:.2}ms (days={d})",
        .{ nsToMs(build_timer.read()), summaries.items.len },
    );

    var missing_set = std.StringHashMap(u8).init(allocator);
    defer missing_set.deinit();

    var apply_pricing_timer = try std.time.Timer.start();
    {
        const pricing_progress = std.Progress.Node.start(progress_root, "apply pricing", summaries.items.len);
        defer std.Progress.Node.end(pricing_progress);
        for (summaries.items) |*summary| {
            Model.applyPricing(allocator, summary, &pricing_map, &missing_set);
            std.sort.pdq(ModelSummary, summary.models.items, {}, modelLessThan);
            std.Progress.Node.completeOne(pricing_progress);
        }
    }
    std.log.info(
        "phase.apply_pricing completed in {d:.2}ms (days={d})",
        .{ nsToMs(apply_pricing_timer.read()), summaries.items.len },
    );

    var sort_days_timer = try std.time.Timer.start();
    {
        const sort_days_progress = std.Progress.Node.start(progress_root, "sort days", 0);
        defer std.Progress.Node.end(sort_days_progress);
        std.sort.pdq(DailySummary, summaries.items, {}, summaryLessThan);
    }
    std.log.info(
        "phase.sort_days completed in {d:.2}ms (days={d})",
        .{ nsToMs(sort_days_timer.read()), summaries.items.len },
    );

    var totals = SummaryTotals.init();
    defer totals.deinit(allocator);
    var totals_timer = try std.time.Timer.start();
    {
        const totals_progress = std.Progress.Node.start(progress_root, "totals", 0);
        defer std.Progress.Node.end(totals_progress);
        Model.accumulateTotals(allocator, &summaries, &totals);
        try Model.collectMissingModels(allocator, &missing_set, &totals.missing_pricing);
    }
    std.log.info(
        "phase.totals completed in {d:.2}ms (missing_pricing={d})",
        .{ nsToMs(totals_timer.read()), totals.missing_pricing.items.len },
    );

    var output_timer = try std.time.Timer.start();
    {
        const write_progress = std.Progress.Node.start(progress_root, "write output", 0);
        defer std.Progress.Node.end(write_progress);
        try render.Renderer.writeSummary(&out_writer, summaries.items, &totals);
    }
    std.log.info(
        "phase.write_json completed in {d:.2}ms (days={d})",
        .{ nsToMs(output_timer.read()), summaries.items.len },
    );

    std.log.info("phase.total runtime {d:.2}ms", .{nsToMs(total_timer.read())});
    std.Progress.setStatus(.success);
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

const OutputWriter = struct {
    file: std.fs.File,

    pub fn writeAll(self: *OutputWriter, bytes: []const u8) !void {
        try self.file.writeAll(bytes);
    }
};

fn eventLessThan(_: void, lhs: Model.TokenUsageEvent, rhs: Model.TokenUsageEvent) bool {
    if (std.mem.eql(u8, lhs.timestamp, rhs.timestamp)) {
        if (!std.mem.eql(u8, lhs.session_id, rhs.session_id)) {
            return std.mem.lessThan(u8, lhs.session_id, rhs.session_id);
        }
        return std.mem.lessThan(u8, lhs.model, rhs.model);
    }
    return std.mem.lessThan(u8, lhs.timestamp, rhs.timestamp);
}

fn summaryLessThan(_: void, lhs: DailySummary, rhs: DailySummary) bool {
    return std.mem.lessThan(u8, lhs.iso_date, rhs.iso_date);
}

fn modelLessThan(_: void, lhs: ModelSummary, rhs: ModelSummary) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}
