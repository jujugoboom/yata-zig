const std = @import("std");
const print = std.debug.print;
const Doc = @import("./src/structs/doc.zig").Doc;

fn range(len: usize) []const u0 {
    return @as([*]u0, undefined)[0..len];
}

fn generateString(n: usize, allocator: std.mem.Allocator) ![]const u8 {
    var prng = std.rand.DefaultPrng.init(0);
    const rng = prng.random();
    var res = try allocator.alloc(u8, n);
    for (res[0..]) |_, i| {
        res[i] = rng.intRangeAtMost(u8, 33, 126);
    }
    return res;
}

pub fn bench(str: []const u8, allocator: std.mem.Allocator) !std.meta.Tuple(&.{ i64, i64, i64 }) {
    var doc1 = Doc.init(allocator);
    defer doc1.deinit();
    var doc2 = Doc.init(allocator);
    defer doc2.deinit();
    var doc3 = Doc.init(allocator);
    const start = std.time.milliTimestamp();
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        try doc1.insert(1, i, str[i .. i + 1]);
        // print("{any}\n", .{doc1});
    }
    const insert_end = std.time.milliTimestamp();
    try doc2.merge(doc1);
    const merge_end = std.time.milliTimestamp();
    var delta = try doc3.delta(doc1);
    defer delta.deinit();
    try doc3.mergeDelta(&delta);
    const delta_merge_end = std.time.milliTimestamp();
    return .{ insert_end - start, merge_end - insert_end, delta_merge_end - merge_end };
}

pub fn main() !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena_allocator.allocator();
    const str = try generateString(6000, allocator);
    defer allocator.free(str);
    var avg_insert: i64 = 0;
    var avg_merge: i64 = 0;
    var avg_delta_merge: i64 = 0;
    var i: usize = 0;
    var progress = std.Progress{};
    var node = progress.start("Bench", 100);
    while (i < 100) : (i += 1) {
        const result = try bench(str, allocator);
        avg_insert += result[0];
        avg_insert = @divTrunc(avg_insert, @as(i64, 2));
        avg_merge += result[1];
        avg_merge = @divTrunc(avg_merge, @as(i64, 2));
        avg_delta_merge += result[2];
        avg_delta_merge = @divTrunc(avg_delta_merge, @as(i64, 2));
        node.completeOne();
    }
    node.end();
    print("Inserted 6000 items in {d}ms\n", .{avg_insert});
    print("Merged 6000 items in {d}ms\n", .{avg_merge});
    print("Merged 6000 deltas in {d}ms\n", .{avg_delta_merge});
    // print("Total: {d}ms\n", .{merge_end - start});
    // const doc_str = try doc1.toString();
    // defer doc_str.deinit();
    // const doc2_str = try doc2.toString();
    // defer doc2_str.deinit();
    // print("String matched: {any}\n", .{std.mem.eql(u8, doc_str.items, str)});
    // print("Merged documents match: {any}\n", .{std.mem.eql(u8, doc_str.items, doc2_str.items)});
}
