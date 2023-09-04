const item = @import("item.zig");
const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

/// Possible merge errors
const MergeError = error{ MissingOperation, MissingParent };

/// Struct to hold delta between two docs. Generated through Doc.delta()
const DocDelta = struct {
    delta: ?*item.Item,
    tombstones: item.ItemIdSet,
    allocator: std.mem.Allocator,
    pub fn init(delta: ?*item.Item, tombstones: item.ItemIdSet, allocator: std.mem.Allocator) !*DocDelta {
        var doc_delta = try allocator.create(DocDelta);
        doc_delta.* = .{ .delta = delta, .tombstones = tombstones, .allocator = allocator };
        return doc_delta;
    }
    pub fn deinit(self: *DocDelta) void {
        self.tombstones.deinit();
        var it = DocIterator{ .curr_item = self.delta };
        while (it.next()) |curr_item| {
            curr_item.deinit();
        }
        self.allocator.destroy(self);
    }
};

/// Iterator through Doc
const DocIterator = struct {
    curr_item: ?*item.Item,
    pub fn next(self: *DocIterator) ?*item.Item {
        const ret = self.curr_item;
        if (ret) |ret_it| self.curr_item = ret_it.right;
        return ret;
    }
};

/// Main doc struct. Contains all logic for YATA CRDT and handles all item creation
pub const Doc = struct {
    head: *item.Item,
    allocator: std.mem.Allocator,
    len: usize,
    items: u32,
    fn createHeadItem(allocator: std.mem.Allocator) !*item.Item {
        return item.Item.init(
            item.HeadItemId,
            item.HeadItemId,
            null,
            null,
            null,
            "",
            false,
            allocator,
            item.spliceStringItem,
            false,
        );
    }
    /// Inits new doc with supplied allocator. Caller is responsible for calling Doc.deinit()
    pub fn init(allocator: std.mem.Allocator) !*Doc {
        var new_doc = try allocator.create(Doc);
        var head_it = try createHeadItem(allocator);
        new_doc.* = .{ .head = head_it, .allocator = allocator, .len = 0, .items = 1 };
        return new_doc;
    }

    /// Basic wrapper around creating a duplicate of a doc
    fn withHead(allocator: std.mem.Allocator, head: *item.Item) !*Doc {
        var new_doc = try allocator.create(Doc);
        var len: usize = 0;
        var items: u32 = 0;
        var it = DocIterator{ .curr_item = head };
        while (it.next()) |curr_item| {
            len += curr_item.content.len;
            items += 1;
        }
        new_doc.* = .{ .head = head, .allocator = allocator, .len = len, .items = items };
        return new_doc;
    }

    /// Doc destructor
    pub fn deinit(self: *Doc) void {
        var it = self.iter();
        while (it.next()) |curr_item| {
            curr_item.deinit();
        }
        self.allocator.destroy(self);
    }

    fn deinit_no_items(self: *Doc) void {
        self.allocator.destroy(self);
    }

    /// Creates DocIterator for doc
    pub fn iter(self: *Doc) DocIterator {
        return DocIterator{ .curr_item = self.head };
    }

    /// Clones self into a new doc. Allocates new doc with existing allocator, caller is responsible for calling Doc.deinit() on returned doc.
    pub fn clone(self: *Doc) !*Doc {
        var item_map = std.HashMap(*item.Item, *item.Item, item.ItemContext, 80).init(self.allocator);
        defer item_map.deinit();
        item_map.ensureTotalCapacity(self.items);
        var it = self.iter();
        var head: ?*item.Item = null;
        while (it.next()) |curr_item| {
            var new_item = try curr_item.clone();
            try item_map.put(curr_item, new_item);
            if (head == null) head = new_item;
        }
        var item_it = item_map.keyIterator();
        while (item_it.next()) |curr_item| {
            var new_item = item_map.get(curr_item.*);
            if (new_item.?.left) |left| {
                new_item.?.left = item_map.get(left);
            }
            if (new_item.?.right) |right| {
                new_item.?.right = item_map.get(right);
            }
        }
        return try Doc.withHead(self.allocator, head);
    }

    /// Returns ArrayList of u8 containing all content inside doc. Caller responsible for calling ArrayList.deinit()
    pub fn toString(self: *Doc) !std.ArrayList(u8) {
        var buf = std.ArrayList(u8).init(self.allocator);
        var it = self.iter();
        while (it.next()) |curr_item| {
            try buf.appendSlice(curr_item.content);
        }
        return buf;
    }

    /// Gets item given item id
    fn getItem(self: *Doc, id: item.ItemId) ?*item.Item {
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item.id.clientId == id.clientId and curr_item.id.seqId >= id.seqId and curr_item.id.seqId + curr_item.content.len <= id.seqId) {
                return curr_item;
            }
        }
        return null;
    }

    /// Finds position in doc, will split items to create position
    fn findPosition(self: *Doc, index: usize) !*item.Item {
        var remaining = index;
        var last: *item.Item = self.head;
        var it = self.iter();
        while (it.next()) |currItem| {
            if (remaining <= 0) {
                break;
            }
            if (!currItem.isDeleted and currItem.content.len != 0) {
                if (currItem.content.len > remaining) {
                    last = try currItem.splice(currItem, remaining);
                    remaining -= currItem.content.len;
                    self.items += 1;
                    continue;
                }
                remaining -= currItem.content.len;
            }
            last = currItem;
        }
        return last;
    }

    /// Gets next sequence id in doc for given clientId
    fn getNextSeqId(self: *Doc, clientId: usize) usize {
        var last_item: ?*item.Item = null;
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item.id.clientId == clientId) {
                if (last_item == null) {
                    last_item = curr_item;
                }
                if (curr_item.id.seqId > last_item.?.id.seqId) {
                    last_item = curr_item;
                }
            }
        }
        return if (last_item) |found_last_item| found_last_item.id.seqId + found_last_item.content.len else 1;
    }

    /// Gets last item in doc for given clientId
    fn getLastItem(self: *Doc, clientId: usize) ?*item.Item {
        var last_item: ?*item.Item = null;
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (last_item == null and curr_item.id.clientId == clientId) {
                last_item = curr_item;
            }
            if (curr_item.id.clientId == clientId and curr_item.id.seqId > last_item.?.id.seqId) {
                last_item = curr_item;
            }
        }
        return last_item;
    }

    /// Inserts new item at index with clientId, splitting existing items when needed
    pub fn insert(self: *Doc, clientId: usize, index: usize, value: []const u8) !void {
        const seqId = self.getNextSeqId(clientId);
        var pos = try self.findPosition(index);
        const origin_right = if (pos.right) |right| right.id else null;
        var new_item = try item.Item.init(item.ItemId{ .clientId = clientId, .seqId = seqId }, pos.id, origin_right, pos, pos.right, value, false, self.allocator, &item.spliceStringItem, false);
        if (new_item.right) |right_item| right_item.left = new_item;
        pos.right = new_item;
        self.items += 1;
        self.len += value.len;
    }

    /// Marks index for deletion
    pub fn delete(self: *Doc, index: usize, len: usize) !void {
        const pos = try self.findPosition(index);
        var remaining = len;
        var o = pos.right;
        while (remaining > 0 and o != null) {
            if (o.?.isDeleted) {
                continue;
            }
            if (o.?.content.len > remaining) {
                _ = try o.?.splice(o.?, remaining);
            }
            remaining -= o.?.content.len;
            o.?.content = "";
            o = o.?.right;
            self.items -= 1;
        }
        self.len -= len - remaining;
    }

    /// Main conflict resolution, finds insert position given originLeft and originRight pointers. preceedingItems should contain all ItemIds before originLeft in document
    fn findInsertPosition(self: *Doc, block: *item.Item, origin_left: *item.Item, origin_right: ?*item.Item, preceeding_items: *item.ItemIdSet) ?*item.Item {
        var scanning = false;
        const right_id = if (origin_right) |o_r| o_r.id else null;
        const left_id = origin_left.id;
        var o = if (!left_id.eql(item.HeadItemId)) origin_left.right else self.head;
        var dst = if (!left_id.eql(item.HeadItemId)) origin_left.right else self.head;
        const client_id = block.id.clientId;
        while (true) {
            dst = if (scanning) dst else o;
            if (o == null or o.?.id.eql(right_id)) break;
            const o_left = o.?.originLeft;
            const o_right = o.?.originRight;
            const o_client_id = o.?.id.clientId;
            if (preceeding_items.contains(o_left) or (left_id.eql(o_left) and ((o_right == null and right_id == null) or right_id.?.eql(o_right)) and client_id <= o_client_id)) {
                break;
            }
            scanning = if (left_id.eql(o_left)) client_id <= o_client_id else scanning;
            o = o.?.right;
        }
        return dst;
    }

    /// Integrates new item into doc
    fn integrate(self: *Doc, new_item: *item.Item) !void {
        const client_id = new_item.id.clientId;
        const seq_id = new_item.id.seqId;
        var last = self.getLastItem(client_id);
        const next = if (last) |found_last| found_last.id.seqId + found_last.content.len else 1;
        if (next != seq_id) {
            if (last != null and seq_id < last.?.id.seqId + last.?.content.len) {
                // Found split in content, splice now
                _ = try last.?.splice(last.?, seq_id - last.?.id.seqId);
                self.items += 1;
                new_item.deinit();
                return;
            } else {
                return error.MissingOperation;
            }
        }
        if (self.head.right == null) {
            // inserting at head
            self.head.right = new_item;
            new_item.left = self.head;
            self.len += new_item.content.len;
            self.items += 1;
            return;
        }
        var left: *item.Item = self.head;
        var right: ?*item.Item = null;
        var it = self.iter();
        // Finding the preceeding items and storing them in a hash map is what takes the most amount of time in this function
        // Unusre of how to optimize HashMap.put(), and unsure of another structure that would be significantt
        var preceedingItems = item.ItemIdSet.init(self.allocator);
        defer preceedingItems.deinit();
        try preceedingItems.ensureTotalCapacity(self.items + 100);
        while (it.next()) |curr_item| {
            if ((left != self.head or new_item.originLeft.eql(self.head.id)) and (right != null or new_item.originRight == null)) {
                break;
            }
            if (curr_item.id.eql(new_item.originLeft)) {
                left = curr_item;
            }
            if (left == self.head) {
                try preceedingItems.put(curr_item.id, {});
            }
            if (curr_item.id.eql(new_item.originRight)) {
                right = curr_item;
            }
        }
        const find_preceeding = std.time.milliTimestamp();
        _ = find_preceeding;
        if (left.right == null and right == null) {
            // appending to end of list
            left.right = new_item;
            new_item.left = left;
            new_item.right = null;
            self.len += new_item.content.len;
            self.items += 1;
            return;
        }
        var i = self.findInsertPosition(new_item, left, right, &preceedingItems);
        new_item.right = i;
        if (i) |i_it| {
            new_item.left = i_it.left;
            if (new_item.left) |left_it| left_it.right = new_item;
            i_it.left = new_item;
        }
        self.len += new_item.content.len;
        self.items += 1;
    }

    /// Merge other doc into this doc. Copies all items from other doc
    pub fn merge(self: *Doc, other: *Doc) !void {
        var seen = item.ItemIdSet.init(self.allocator);
        try seen.ensureTotalCapacity(self.items + other.items);
        defer seen.deinit();
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item != self.head and curr_item.content.len == 0) {
                curr_item.isDeleted = true;
            }
            if (!curr_item.isDeleted) {
                try seen.put(curr_item.id, {});
            }
        }
        var blocks = try std.ArrayList(*item.Item).initCapacity(self.allocator, other.items);
        defer blocks.deinit();
        var other_it = other.iter();
        while (other_it.next()) |curr_item| {
            if (!seen.contains(curr_item.id)) {
                try blocks.append(curr_item);
            }
        }
        var remaining = blocks.items.len;
        while (remaining > 0) {
            for (blocks.items) |block| {
                const canInsert = !seen.contains(block.id) and seen.contains(block.originLeft) and (block.originRight == null or seen.contains(block.originRight.?));
                if (canInsert) {
                    var new_item = try block.clone();
                    try self.integrate(new_item);
                    try seen.put(block.id, {});
                    remaining -= 1;
                }
            }
        }
    }

    /// Gets current version map (clientId => max(seqId)) for doc
    fn version(self: *Doc) !std.AutoHashMap(usize, usize) {
        var version_map = std.AutoHashMap(usize, usize).init(self.allocator);
        var it = self.iter();
        while (it.next()) |curr_item| {
            const max_seq = (try version_map.getOrPutValue(curr_item.id.clientId, curr_item.id.seqId)).value_ptr;
            if (curr_item.id.seqId > max_seq.*) {
                try version_map.put(curr_item.id.clientId, curr_item.id.seqId);
            }
        }
        return version_map;
    }

    /// Generates DocDelta between this doc and provided other doc. Caller responsible for calling DocDelta.deinit()
    pub fn delta(self: *Doc, doc: *Doc) !*DocDelta {
        var delta_head: ?*item.Item = null;
        var curr_delta: ?*item.Item = null;
        var tombstones = item.ItemIdSet.init(self.allocator);
        var curr_version = try self.version();
        defer curr_version.deinit();
        var it = doc.iter();
        while (it.next()) |curr_item| {
            if (!curr_version.contains(curr_item.id.clientId) or curr_item.id.seqId > curr_version.get(curr_item.id.clientId) orelse 0) {
                if (delta_head == null) {
                    delta_head = try curr_item.clone();
                    curr_delta = delta_head;
                    curr_delta.?.right = null;
                    curr_delta.?.left = null;
                } else {
                    curr_delta.?.right = try curr_item.clone();
                    var old_delta = curr_delta;
                    curr_delta = curr_delta.?.right;
                    curr_delta.?.left = old_delta;
                }
            }
            if (curr_item.isDeleted) {
                try tombstones.put(curr_item.id, {});
            }
        }
        return DocDelta.init(delta_head, tombstones, self.allocator);
    }

    /// Merges a DocDelta into this doc, copying all items
    pub fn mergeDelta(self: *Doc, doc_delta: *DocDelta) !void {
        var head = try Doc.createHeadItem(self.allocator);
        if (doc_delta.delta) |d| {
            const null_head = head;
            head = d;
            null_head.deinit();
        }
        var delta_doc = try Doc.withHead(self.allocator, head);
        defer delta_doc.deinit_no_items();
        try self.merge(delta_doc);
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (!curr_item.isDeleted and doc_delta.tombstones.contains(curr_item.id)) {
                curr_item.content = "";
            }
        }
    }
};

test "Create doc test" {
    var doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    try doc.insert(1, 0, "Hello");
    const result1 = try doc.toString();
    defer result1.deinit();
    try expect(std.mem.eql(u8, result1.items, "Hello"));
    try doc.insert(1, 3, "p");
    const result2 = try doc.toString();
    defer result2.deinit();
    try expect(std.mem.eql(u8, result2.items, "Helplo"));
}

test "Delete text test" {
    var doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    try doc.insert(1, 0, "Hello World");
    const result1 = try doc.toString();
    defer result1.deinit();
    try expect(std.mem.eql(u8, result1.items, "Hello World"));
    try doc.delete(1, 3);
    const result2 = try doc.toString();
    defer result2.deinit();
    try expect(std.mem.eql(u8, result2.items, "Ho World"));
}

test "Merge docs test" {
    var doc1 = try Doc.init(testing.allocator);
    defer doc1.deinit();
    try doc1.insert(1, 0, "Hello");

    var doc2 = try Doc.init(testing.allocator);
    defer doc2.deinit();
    try doc2.insert(1, 0, "Hello");
    try doc2.insert(2, 2, "p");
    try doc1.insert(1, 2, "r");

    try doc1.merge(doc2);
    try doc2.merge(doc1);
    const doc1_res = try doc1.toString();
    defer doc1_res.deinit();
    const doc2_res = try doc2.toString();
    defer doc2_res.deinit();

    try expect(std.mem.eql(u8, doc1_res.items, "Herpllo"));
    try expect(std.mem.eql(u8, doc1_res.items, doc2_res.items));
}

test "delta merge docs test" {
    var doc1 = try Doc.init(testing.allocator);
    defer doc1.deinit();
    try doc1.insert(1, 0, "Hello");

    var doc2 = try Doc.init(testing.allocator);
    defer doc2.deinit();
    try doc2.insert(1, 0, "Hello");
    try doc2.insert(2, 1, "p");
    try doc1.insert(1, 1, "r");
    var doc1_delta = try doc1.delta(doc2);
    defer doc1_delta.deinit();
    var doc2_delta = try doc2.delta(doc1);
    defer doc2_delta.deinit();
    try expect(doc2_delta.delta.?.right == null);
    try expect(doc1_delta.delta.?.right == null);
    try doc1.mergeDelta(doc1_delta);
    try doc2.mergeDelta(doc2_delta);
    const doc1_res = try doc1.toString();
    defer doc1_res.deinit();
    const doc2_res = try doc2.toString();
    defer doc2_res.deinit();
    try expect(std.mem.eql(u8, doc1_res.items, "Hrpello"));
    try expect(std.mem.eql(u8, doc1_res.items, doc2_res.items));
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

fn bench(str: []const u8, allocator: std.mem.Allocator) !std.meta.Tuple(&.{ *Doc, *Doc, *Doc }) {
    var doc1 = try Doc.init(allocator);
    var doc2 = try Doc.init(allocator);
    var doc3 = try Doc.init(allocator);
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        try doc1.insert(1, i, str[i .. i + 1]);
    }
    try doc2.merge(doc1);
    var delta = try doc3.delta(doc1);
    defer delta.deinit();
    try doc3.mergeDelta(delta);
    return .{ doc1, doc2, doc3 };
}

test "large doc operation memory leak test" {
    const str = try generateString(2, testing.allocator);
    defer testing.allocator.free(str);
    const result = try bench(str, testing.allocator);
    defer result[0].deinit();
    defer result[1].deinit();
    defer result[2].deinit();
    const res1 = try result[0].toString();
    defer res1.deinit();
    try expect(std.mem.eql(u8, res1.items, str));
    const res2 = try result[1].toString();
    defer res2.deinit();
    try expect(std.mem.eql(u8, res1.items, res2.items));
    const res3 = try result[2].toString();
    defer res3.deinit();
    try expect(std.mem.eql(u8, res3.items, res1.items));
}
